# Built from the REPOSITORY ROOT as context, because the library lives in aaos/nexus-aaos-sdk:
#   docker buildx build --platform linux/<arch> -f sample-services/aaos/door-control/Dockerfile .
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
# The message types are generated at build time from the VSIDL catalog's .proto — the same
# file the vehicle side is generated from — so the catalog is part of the build context.
COPY ./aaos/nexus-sdv-sample/catalog/ ./aaos/nexus-sdv-sample/catalog/
COPY ./aaos/nexus-sdk-catalog/ ./aaos/nexus-sdk-catalog/
COPY ./sample-services/aaos/messages/ ./sample-services/aaos/messages/
COPY ./sample-services/aaos/door-control/ ./sample-services/aaos/door-control/
WORKDIR /app/sample-services/aaos/door-control

RUN cargo test

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
    cp "target/${TARGET}/release/door-control" /service

FROM scratch
COPY --from=builder /service /service
USER 10001:10001
ENTRYPOINT ["/service"]
