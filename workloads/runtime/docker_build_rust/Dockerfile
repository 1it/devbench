# Multi-stage Rust image build. Deliberately representative of a real dev workflow:
#   1. Build stage on the standard rust image — hits cargo registry + compiler + linker.
#   2. Runtime stage on distroless — pure COPY, minimal.
#
# Versions are pinned so the workload is reproducible across runs and machines.
# The source is a Rust project mounted at /src via the build context (see run.sh).

FROM rust:1.95-slim-bookworm AS builder
WORKDIR /build
# System deps commonly needed by Rust crates with C dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy only the manifest first (cache-friendly). This is realistic dev behaviour;
# many real Dockerfiles use this pattern so that only-source changes don't
# re-fetch dependencies.
COPY Cargo.toml Cargo.lock* ./
# Fetch deps against an empty src so that dep compilation layer caches.
RUN mkdir -p src && echo "fn main(){}" > src/main.rs && cargo build --release && rm -rf src target/release/deps/devbench_dockerload*

# Real source; rebuild now uses cached dep compilation.
COPY src ./src
RUN cargo build --release --locked

FROM gcr.io/distroless/cc-debian12:latest
COPY --from=builder /build/target/release/devbench-dockerload /usr/local/bin/devbench-dockerload
ENTRYPOINT ["/usr/local/bin/devbench-dockerload"]
