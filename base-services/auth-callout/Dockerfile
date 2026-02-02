# --- Stage 1: The Builder ---
# This stage compiles the Go application into a static binary.
FROM golang:1.24-alpine AS builder

# Set the working directory inside the container
WORKDIR /app

# Copy the Go module files first to leverage Docker's layer caching.
# If these files don't change, the 'go mod download' layer won't be re-run.
COPY go.mod go.sum ./

# Download the dependencies
RUN go mod download

# Copy the rest of the application's source code
COPY *.go ./

# Build the Go application.
# CGO_ENABLED=0 creates a static binary without any C dependencies.
# -a forces rebuilding of packages that are already up-to-date.
# -ldflags="-w -s" strips debug symbols and information, reducing the binary size.
RUN CGO_ENABLED=0 GOOS=linux go build -a -ldflags="-w -s" -o /auth-service .


# --- Stage 2: The Final Image ---
# This stage creates the final, lightweight image with only the compiled binary.
FROM alpine:latest

# It's a good security practice to run the application as a non-root user.
RUN addgroup -S natsapp && adduser -S natsapp -G natsapp

# Switch to the non-root user
USER natsapp

# Copy only the compiled binary from the 'builder' stage.
COPY --from=builder /auth-service /auth-service

# Set the entrypoint for the container. This command will be executed when the container starts.
ENTRYPOINT ["/auth-service"]
