FROM golang:latest AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY api ./api
COPY src ./src

RUN CGO_ENABLED=0 go build -o /data-converter ./src

FROM alpine:latest

RUN addgroup -S app && adduser -S app -G app
USER app

COPY --from=builder /data-converter /data-converter

ENTRYPOINT ["/data-converter"]
