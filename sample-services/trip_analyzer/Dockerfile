ARG DOCKER_HUB_MIRROR=europe-west4-docker.pkg.dev/horizon-sdv-lal/docker-hub
FROM ${DOCKER_HUB_MIRROR}/python:3.13-slim AS base

RUN pip install uv

WORKDIR /app

COPY . /app

RUN uv sync


ENV PATH="/app/.venv/bin:$PATH"

CMD ["uv", "run", "uvicorn", "trip_analyzer.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]