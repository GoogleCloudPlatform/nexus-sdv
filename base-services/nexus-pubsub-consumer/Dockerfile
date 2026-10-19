# Two stages: build with the full toolchain, ship a thin runtime image.
# The DOCKER_HUB_MIRROR arg matches the convention the repo's other services use
# so this can later move onto the standard build pipeline unchanged.
ARG DOCKER_HUB_MIRROR=docker.io
# Both bases are pinned to the multi-arch index digest current on 2026-09-29, so a rebuild
# cannot pick up a different image under the same tag. The tag stays for the reader; the
# digest is what is pulled. To take base-image security updates, look up the new digests
# and change them here, deliberately.
FROM ${DOCKER_HUB_MIRROR}/rust:1-bookworm@sha256:93ce27a88655056a51dbdd8f5f2d7ddc071c7b0070fb288a37b5a285fc83971e AS builder
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler libprotobuf-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto ./proto
COPY src ./src
RUN cargo build --release --locked

FROM ${DOCKER_HUB_MIRROR}/debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 app
COPY --from=builder /src/target/release/nexus-pubsub-consumer /usr/local/bin/
USER app
ENV CONFIG_PATH=/etc/nexus-pubsub-consumer/config.toml
ENTRYPOINT ["/usr/local/bin/nexus-pubsub-consumer"]
