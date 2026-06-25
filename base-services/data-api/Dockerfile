ARG DOCKER_HUB_MIRROR=europe-west4-docker.pkg.dev/horizon-sdv-lal/docker-hub
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
