FROM --platform=$BUILDPLATFORM golang:latest AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY api ./api
COPY src ./src

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /server ./src

FROM alpine:latest

COPY --from=builder /server /server
EXPOSE 8080

ENTRYPOINT [ "/server" ]
