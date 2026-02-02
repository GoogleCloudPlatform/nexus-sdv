FROM ghcr.io/rust-cross/rust-musl-cross:x86_64-musl AS builder

WORKDIR /app

COPY ./base-services/registration/server/ ./registration/server/

WORKDIR /app/registration/server

RUN cargo build --release --target x86_64-unknown-linux-musl

FROM scratch

COPY --from=builder /app/registration/server/target/x86_64-unknown-linux-musl/release/server /server

ENTRYPOINT ["/server"]
