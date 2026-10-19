"""The NATS subjects this SDK publishes on.

The subject names the format and the vehicle: the Nexus message (TelemetryMessage) goes on
telemetry.<VIN>. A message carries readings of several sensors, so no sensor is named.
"""


def telemetry_subject(vin: str) -> str:
    """The subject for a vehicle's TelemetryMessage.

    The VIN becomes one token of the subject, so it must be one: a dot would add a token, a
    wildcard or a space would not be a subject at all.
    """
    if not vin or any(c in vin for c in ".*> \t\r\n"):
        raise ValueError(f"not usable as a subject token: {vin!r}")
    return f"telemetry.{vin}"
