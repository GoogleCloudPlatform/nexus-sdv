# --- Stage 1: The Builder ---
# Base-image registry, supplied by the deployment chain: the Cloud Build
# pipeline passes --build-arg DOCKER_HUB_MIRROR=<project registry>/docker-hub,
# derived from IMAGE_REPO, so images always come from the deploying project's
# own Artifact Registry. Intentionally has no default — a hardcoded one named a
# registry only one project can read.
ARG DOCKER_HUB_MIRROR
FROM --platform=$BUILDPLATFORM ${DOCKER_HUB_MIRROR}/golang:1.25-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -a -ldflags="-w -s" -o /vin-registry .

# --- Stage 2: The Final Image ---
FROM ${DOCKER_HUB_MIRROR}/alpine:latest
RUN addgroup -S registry && adduser -S registry -G registry
USER registry
COPY --from=builder /vin-registry /vin-registry
ENTRYPOINT ["/vin-registry"]
