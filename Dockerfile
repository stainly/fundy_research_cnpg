ARG CNPG_BASE_IMAGE=ghcr.io/cloudnative-pg/postgresql:17.9-202603160825-standard-bookworm@sha256:bc45cd03c67bf6603109181d23d6f7c9a7f3bc9af71848c91743e732a715538c
ARG PG_VERSION=17

# =============================================================================
# PostgreSQL 17 + pgvectorscale + pg_textsearch
# Base: CloudNativePG official standard image (pinned)
# Notes:
# - pgvector is already included in the CNPG standard image
# - pg_textsearch still requires shared_preload_libraries at runtime
# =============================================================================

# --- Stage 1: Build pgvectorscale ---
FROM ${CNPG_BASE_IMAGE} AS pgvectorscale-builder

ARG PGVECTORSCALE_VERSION=0.9.0
ARG PG_VERSION=17

USER root

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-${PG_VERSION} \
    git \
    curl \
    jq \
    pkg-config \
    clang \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN git clone --branch ${PGVECTORSCALE_VERSION} --depth 1 \
    https://github.com/timescale/pgvectorscale.git /tmp/pgvectorscale

WORKDIR /tmp/pgvectorscale/pgvectorscale

RUN cargo install --locked cargo-pgrx \
    --version $(cargo metadata --format-version 1 | jq -r '.packages[] | select(.name == "pgrx") | .version')

RUN cargo pgrx init --pg${PG_VERSION}=$(which pg_config)

RUN cargo pgrx install --release --no-default-features --features pg${PG_VERSION},build_parallel \
    && echo "=== Verifying pgvectorscale installation ===" \
    && ls -la /usr/lib/postgresql/${PG_VERSION}/lib/ | grep -i vectorscale || echo "No pgvectorscale files in lib" \
    && ls -la /usr/share/postgresql/${PG_VERSION}/extension/ | grep -i vectorscale || echo "No pgvectorscale files in extension"

RUN mkdir -p /tmp/vectorscale-artifacts/usr/lib/postgresql/${PG_VERSION}/lib \
    && mkdir -p /tmp/vectorscale-artifacts/usr/share/postgresql/${PG_VERSION}/extension \
    && cp /usr/lib/postgresql/${PG_VERSION}/lib/vectorscale*.so /tmp/vectorscale-artifacts/usr/lib/postgresql/${PG_VERSION}/lib/ \
    && cp /usr/share/postgresql/${PG_VERSION}/extension/vectorscale* /tmp/vectorscale-artifacts/usr/share/postgresql/${PG_VERSION}/extension/ \
    && if [ -d /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/vectorscale ]; then mkdir -p /tmp/vectorscale-artifacts/usr/lib/postgresql/${PG_VERSION}/lib/bitcode/vectorscale && cp -R /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/vectorscale/. /tmp/vectorscale-artifacts/usr/lib/postgresql/${PG_VERSION}/lib/bitcode/vectorscale/; fi \
    && if [ -f /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/vectorscale.index.bc ]; then mkdir -p /tmp/vectorscale-artifacts/usr/lib/postgresql/${PG_VERSION}/lib/bitcode && cp /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/vectorscale.index.bc /tmp/vectorscale-artifacts/usr/lib/postgresql/${PG_VERSION}/lib/bitcode/; fi


# --- Stage 2: Build pg_textsearch ---
FROM ${CNPG_BASE_IMAGE} AS textsearch-builder

ARG PG_TEXTSEARCH_VERSION=v0.6.1
ARG PG_VERSION=17

USER root

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-${PG_VERSION} \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --branch ${PG_TEXTSEARCH_VERSION} --depth 1 \
    https://github.com/timescale/pg_textsearch.git /tmp/pg_textsearch \
    && cd /tmp/pg_textsearch \
    && make -j$(nproc) \
    && make install \
    && echo "=== Verifying pg_textsearch installation ===" \
    && ls -la /usr/lib/postgresql/${PG_VERSION}/lib/ | grep -i pg_textsearch || echo "No pg_textsearch files in lib" \
    && ls -la /usr/share/postgresql/${PG_VERSION}/extension/ | grep -i pg_textsearch || echo "No pg_textsearch files in extension"

RUN mkdir -p /tmp/textsearch-artifacts/usr/lib/postgresql/${PG_VERSION}/lib \
    && mkdir -p /tmp/textsearch-artifacts/usr/share/postgresql/${PG_VERSION}/extension \
    && cp /usr/lib/postgresql/${PG_VERSION}/lib/pg_textsearch*.so /tmp/textsearch-artifacts/usr/lib/postgresql/${PG_VERSION}/lib/ \
    && cp /usr/share/postgresql/${PG_VERSION}/extension/pg_textsearch* /tmp/textsearch-artifacts/usr/share/postgresql/${PG_VERSION}/extension/


# --- Final Stage ---
FROM ${CNPG_BASE_IMAGE}

ARG PG_VERSION=17

USER root

# Install barman-cli-cloud for WAL archiving and backup support
RUN apt-get update && apt-get install -y --no-install-recommends \
    barman-cli-cloud \
    && rm -rf /var/lib/apt/lists/*

# --- pgvectorscale and pg_textsearch ---
COPY --from=pgvectorscale-builder /tmp/vectorscale-artifacts/ /
COPY --from=textsearch-builder /tmp/textsearch-artifacts/ /

# CloudNativePG runs with user 26 (postgres)
USER 26
