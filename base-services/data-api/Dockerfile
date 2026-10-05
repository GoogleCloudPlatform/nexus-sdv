# Base-image registry, supplied by the deployment chain: the Cloud Build
# pipeline passes --build-arg DOCKER_HUB_MIRROR=<project registry>/docker-hub,
# derived from IMAGE_REPO, so images always come from the deploying project's
# own Artifact Registry. Intentionally has no default — a hardcoded one named a
# registry only one project can read.
ARG DOCKER_HUB_MIRROR
FROM --platform=$BUILDPLATFORM ${DOCKER_HUB_MIRROR}/golang:latest AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY api ./api
COPY src ./src

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /server ./src

FROM ${DOCKER_HUB_MIRROR}/alpine:latest

COPY --from=builder /server /server
EXPOSE 8080

ENTRYPOINT [ "/server" ]
