# Base-image registry, supplied by the deployment chain: the Cloud Build
# pipeline passes --build-arg DOCKER_HUB_MIRROR=<project registry>/docker-hub,
# derived from IMAGE_REPO, so images always come from the deploying project's
# own Artifact Registry. Intentionally has no default — a hardcoded one named a
# registry only one project can read.
ARG DOCKER_HUB_MIRROR
FROM ${DOCKER_HUB_MIRROR}/python:3.13-slim AS base

RUN pip install uv

WORKDIR /app

COPY . /app

RUN uv sync


ENV PATH="/app/.venv/bin:$PATH"

CMD ["uv", "run", "uvicorn", "trip_analyzer.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "1"]