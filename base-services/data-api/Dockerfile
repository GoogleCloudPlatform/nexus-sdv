FROM golang:latest AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY api ./api
COPY src ./src

RUN  CGO_ENABLED=0 go build -o /server ./src

FROM alpine:latest

COPY --from=builder /server /server
EXPOSE 8080

ENTRYPOINT [ "/server" ]
