FROM --platform=$BUILDPLATFORM rust:bookworm AS builder

# Install cross-compilation toolchains for both target architectures
# cmake is required by aws-lc-sys (rustls dependency)
RUN apt-get update && apt-get install -y \
    musl-tools \
    cmake \
    gcc-aarch64-linux-gnu \
    gcc-x86-64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

RUN rustup target add aarch64-unknown-linux-musl x86_64-unknown-linux-musl

WORKDIR /app

COPY ./base-services/registration/server/ ./registration/server/

WORKDIR /app/registration/server

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
    cp "target/${TARGET}/release/server" /server

FROM scratch

COPY --from=builder /server /server

ENTRYPOINT ["/server"]
