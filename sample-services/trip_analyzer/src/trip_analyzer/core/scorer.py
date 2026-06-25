from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time
from typing import Iterable, TypeAlias
from trip_analyzer.config.logging import logger

Timestamp: TypeAlias = str | int | float | datetime | time
Sample: TypeAlias = tuple[Timestamp, float]


@dataclass(frozen=True, slots=True)
class DrivingScore:
    """Result of the trip scoring.

    Attributes:
        score: Final score in the range 0..100. Higher is better.
        suggestions: Human-readable hints about the trip.
    """

    score: int
    suggestions: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ScoringConfig:
    """Tuning knobs for the scoring model.

    The defaults are intentionally conservative: a calm driver keeps a high score,
    while sustained speeding or repeated harsh maneuvers visibly reduce it.
    """

    speed_soft_limit_kmh: float = 130.0
    speed_hard_limit_kmh: float = 180.0

    accel_soft_limit_ms2: float = 2.7
    accel_hard_limit_ms2: float = 4.5

    brake_soft_limit_ms2: float = 3.2
    brake_hard_limit_ms2: float = 6.0

    aggressive_change_threshold_ms2: float = 1.8
    aggressive_swings_per_min_hard: float = 6.0

    max_speed_penalty: float = 35.0
    max_accel_penalty: float = 20.0
    max_brake_penalty: float = 20.0
    max_aggressive_penalty: float = 25.0


def score_trip(samples: Iterable[Sample], config: ScoringConfig = ScoringConfig()) -> DrivingScore:
    """Score a trip for a Pay-How-You-Drive showcase.

    The input is an iterable of ``(timestamp, speed_kmh)`` pairs.
    Timestamps may be ``HH:MM:SS`` strings, ``datetime`` objects,
    ``datetime.time`` objects, or numeric seconds.

    The algorithm penalizes four behaviors:
    - high speed
    - high acceleration
    - harsh braking
    - aggressive back-and-forth driving

    The function returns a score between 0 and 100, where 100 is best.

    A calm trip stays at 100.

    >>> score_trip([
    ...     ("10:00:00", 30),
    ...     ("10:00:03", 32),
    ...     ("10:00:07", 31),
    ... ])
    DrivingScore(score=100, suggestions=())

    Variable sampling intervals are handled correctly.

    >>> score_trip([
    ...     ("10:00:00", 0),
    ...     ("10:00:02", 18),
    ...     ("10:00:07", 36),
    ... ]).score
    100

    Sustained high speed triggers a speed warning.

    >>> result = score_trip([
    ...     ("10:00:00", 145),
    ...     ("10:00:03", 152),
    ...     ("10:00:06", 148),
    ... ])
    >>> result.score
    95
    >>> result.suggestions
    ('too fast driving',)

    Strong launch and harsh braking are penalized separately.

    >>> result = score_trip([
    ...     ("10:00:00", 0),
    ...     ("10:00:03", 55),
    ...     ("10:00:06", 0),
    ... ])
    >>> result.score < 100
    True
    >>> result.suggestions
    ('too fast accelerations', 'too fast brakes')

    Repeated switching between throttle and brake is considered aggressive.

    >>> result = score_trip([
    ...     ("10:00:00", 0),
    ...     ("10:00:03", 40),
    ...     ("10:00:06", 5),
    ...     ("10:00:09", 45),
    ...     ("10:00:12", 5),
    ... ])
    >>> "too aggressive driving" in result.suggestions
    True

    Trips may cross midnight.

    >>> score_trip([
    ...     ("23:59:58", 20),
    ...     ("00:00:01", 22),
    ...     ("00:00:04", 21),
    ... ])
    DrivingScore(score=100, suggestions=())

    Invalid input is rejected early.

    >>> score_trip([("10:00:00", 10)])
    Traceback (most recent call last):
    ...
    ValueError: at least two samples are required
    >>> score_trip([("10:00:05", 10), ("10:00:05", 20)])
    Traceback (most recent call last):
    ...
    ValueError: timestamps must be strictly increasing
    """
    normalized = _normalize_samples(samples)
    intervals = list(_intervals(normalized))

    durations = [dt for dt, _, _ in intervals]
    total_time = sum(durations)

    average_speeds = [(v1 + v2) / 2.0 for dt, v1, v2 in intervals]
    accelerations = [((v2 - v1) / 3.6) / dt for dt, v1, v2 in intervals]
    positive_accelerations = [max(a, 0.0) for a in accelerations]
    braking_strengths = [max(-a, 0.0) for a in accelerations]

    speed_penalty = config.max_speed_penalty * _weighted_excess(
        values=average_speeds,
        weights=durations,
        soft_limit=config.speed_soft_limit_kmh,
        hard_limit=config.speed_hard_limit_kmh,
    )

    accel_penalty = config.max_accel_penalty * _weighted_excess(
        values=positive_accelerations,
        weights=durations,
        soft_limit=config.accel_soft_limit_ms2,
        hard_limit=config.accel_hard_limit_ms2,
    )

    brake_penalty = config.max_brake_penalty * _weighted_excess(
        values=braking_strengths,
        weights=durations,
        soft_limit=config.brake_soft_limit_ms2,
        hard_limit=config.brake_hard_limit_ms2,
    )

    aggressive_penalty = config.max_aggressive_penalty * _aggressiveness(
        accelerations=accelerations,
        total_time_s=total_time,
        threshold_ms2=config.aggressive_change_threshold_ms2,
        hard_swings_per_min=config.aggressive_swings_per_min_hard,
    )

    score = max(
        0,
        min(
            100,
            round(
                100
                - speed_penalty
                - accel_penalty
                - brake_penalty
                - aggressive_penalty
            ),
        ),
    )

    suggestions: list[str] = []
    if max(average_speeds, default=0.0) > config.speed_soft_limit_kmh:
        suggestions.append("speeding")
    if max(positive_accelerations, default=0.0) > config.accel_soft_limit_ms2:
        suggestions.append("accelerating too fast")
    if max(braking_strengths, default=0.0) > config.brake_soft_limit_ms2:
        suggestions.append("hard braking")
    if aggressive_penalty >= 5.0:
        suggestions.append("aggressive driving")

    return DrivingScore(score=score, suggestions=tuple(suggestions))


def _normalize_samples(samples: Iterable[Sample]) -> list[tuple[float, float]]:
    normalized: list[tuple[float, float]] = []
    day_offset = 0.0
    previous_raw: float | None = None

    for timestamp, speed_kmh in samples:
        if speed_kmh < 0:
            raise ValueError("speed must be non-negative")

        raw_seconds = _to_seconds(timestamp)

        if previous_raw is not None and raw_seconds < previous_raw:
            day_offset += 24 * 60 * 60  # support crossing midnight

        seconds = raw_seconds + day_offset
        normalized.append((seconds, float(speed_kmh)))
        previous_raw = raw_seconds

    if len(normalized) < 2:
        raise ValueError("at least two samples are required")

    for (t1, _), (t2, _) in zip(normalized, normalized[1:]):
        if t2 <= t1:
            raise ValueError("timestamps must be strictly increasing")

    return normalized


def _intervals(samples: list[tuple[float, float]]) -> Iterable[tuple[float, float, float]]:
    for (t1, v1), (t2, v2) in zip(samples, samples[1:]):
        yield t2 - t1, v1, v2


def _to_seconds(timestamp: Timestamp) -> float:
    if isinstance(timestamp, (int, float)):
        return float(timestamp)

    if isinstance(timestamp, datetime):
        return (
                timestamp.hour * 3600
                + timestamp.minute * 60
                + timestamp.second
                + timestamp.microsecond / 1_000_000
        )

    if isinstance(timestamp, time):
        return (
                timestamp.hour * 3600
                + timestamp.minute * 60
                + timestamp.second
                + timestamp.microsecond / 1_000_000
        )

    if isinstance(timestamp, str):
        parsed = datetime.strptime(timestamp, "%H:%M:%S")
        return parsed.hour * 3600 + parsed.minute * 60 + parsed.second

    raise TypeError(f"unsupported timestamp type: {type(timestamp)!r}")


def _weighted_excess(
        *,
        values: list[float],
        weights: list[float],
        soft_limit: float,
        hard_limit: float,
) -> float:
    if hard_limit <= soft_limit:
        raise ValueError("hard_limit must be greater than soft_limit")

    total_weight = sum(weights)
    if total_weight == 0:
        return 0.0

    severities = [_severity(value, soft_limit, hard_limit) for value in values]
    return sum(severity * weight for severity, weight in zip(severities, weights)) / total_weight


def _severity(value: float, soft_limit: float, hard_limit: float) -> float:
    if value <= soft_limit:
        return 0.0
    if value >= hard_limit:
        return 1.0

    ratio = (value - soft_limit) / (hard_limit - soft_limit)
    return ratio * ratio


def _aggressiveness(
        *,
        accelerations: list[float],
        total_time_s: float,
        threshold_ms2: float,
        hard_swings_per_min: float,
) -> float:
    if total_time_s <= 0:
        return 0.0

    states: list[int] = []
    for acceleration in accelerations:
        if acceleration >= threshold_ms2:
            state = 1
        elif acceleration <= -threshold_ms2:
            state = -1
        else:
            state = 0

        if state:
            states.append(state)

    if len(states) < 3:
        return 0.0

    swings = sum(1 for left, right in zip(states, states[1:]) if left != right)
    swings_per_min = swings / (total_time_s / 60.0)
    return min(swings_per_min / hard_swings_per_min, 1.0)
