# Built from the REPOSITORY ROOT as context:
#   docker buildx build --platform linux/<arch> -f base-services/nexus-registry/Dockerfile .
# DOCKER_HUB_MIRROR is the deploying project's registry (<IMAGE_REPO minus /artifact-registry>/docker-hub),
# passed by the pipeline; there is deliberately no default.
ARG DOCKER_HUB_MIRROR
FROM --platform=$BUILDPLATFORM ${DOCKER_HUB_MIRROR}/rust:bookworm AS builder

RUN apt-get update && apt-get install -y \
    musl-tools \
    cmake \
    gcc-aarch64-linux-gnu \
    gcc-x86-64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*
RUN rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl

WORKDIR /app
COPY ./aaos/nexus-aaos-sdk/ ./aaos/nexus-aaos-sdk/
COPY ./base-services/nexus-registry/ ./base-services/nexus-registry/
WORKDIR /app/base-services/nexus-registry

# A red test stops the image (Plan B ruling 5). The tests that need a NATS server are
# ignored here and run against Docker locally.
RUN cargo test --manifest-path ../../aaos/nexus-aaos-sdk/Cargo.toml && cargo test

ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      arm64) \
        export TARGET="aarch64-unknown-linux-musl" && \
        export CC_aarch64_unknown_linux_musl=aarch64-linux-gnu-gcc && \
        export AR_aarch64_unknown_linux_musl=aarch64-linux-gnu-ar && \
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-linux-gnu-gcc ;; \
      amd64) \
        export TARGET="x86_64-unknown-linux-musl" && \
        export CC_x86_64_unknown_linux_musl=x86_64-linux-gnu-gcc && \
        export AR_x86_64_unknown_linux_musl=x86_64-linux-gnu-ar && \
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=x86_64-linux-gnu-gcc ;; \
    esac && \
    cargo build --release --target "${TARGET}" && \
    cp "target/${TARGET}/release/nexus-registry" /nexus-registry

FROM scratch
COPY --from=builder /nexus-registry /nexus-registry
USER 10001:10001
ENTRYPOINT ["/nexus-registry"]
