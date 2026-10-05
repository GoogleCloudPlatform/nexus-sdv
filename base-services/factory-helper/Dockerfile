# Built from the REPO ROOT as context (like registration):
#   docker buildx build --platform linux/<arch> -f base-services/factory-helper/Dockerfile .
# Base-image registry, supplied by the deployment chain: the Cloud Build
# pipeline passes --build-arg DOCKER_HUB_MIRROR=<project registry>/docker-hub,
# derived from IMAGE_REPO, so images always come from the deploying project's
# own Artifact Registry. Intentionally has no default — a hardcoded one named a
# registry only one project can read.
ARG DOCKER_HUB_MIRROR
FROM --platform=$BUILDPLATFORM ${DOCKER_HUB_MIRROR}/rust:bookworm AS builder

# Cross-compilation toolchains for both target architectures.
# cmake is required by aws-lc-sys (rustls dependency).
RUN apt-get update && apt-get install -y \
    musl-tools \
    cmake \
    gcc-aarch64-linux-gnu \
    gcc-x86-64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

RUN rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl

WORKDIR /app

COPY ./base-services/factory-helper/ ./factory-helper/

WORKDIR /app/factory-helper

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
    cp "target/${TARGET}/release/factory-helper" /factory-helper

FROM scratch

COPY --from=builder /factory-helper /factory-helper

ENTRYPOINT ["/factory-helper"]
