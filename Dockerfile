# =============================================================================
# PostgreSQL 17 + pgvector + pgvectorscale + pg_textsearch
# Base: CloudNativePG official image
# =============================================================================

# --- Stage 1: Build pgvector ---
FROM ghcr.io/cloudnative-pg/postgresql:17 AS pgvector-builder

ARG PGVECTOR_VERSION=v0.8.2
ARG PG_VERSION=17

USER root

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-${PG_VERSION} \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --branch ${PGVECTOR_VERSION} --depth 1 \
    https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make -j$(nproc) \
    && make install \
    && echo "=== installed pgvector artifacts ===" \
    && find /usr/lib/postgresql/${PG_VERSION}/lib    -maxdepth 1 | grep vector \
    && find /usr/share/postgresql/${PG_VERSION}/extension -maxdepth 1 | grep vector


# --- Stage 2: Build pgvectorscale (Rust/PGRX) ---
FROM ghcr.io/cloudnative-pg/postgresql:17 AS pgvectorscale-builder

ARG PGVECTORSCALE_VERSION=0.9.0
ARG PGVECTOR_VERSION=v0.8.2
ARG PG_VERSION=17

USER root

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-${PG_VERSION} \
    git \
    curl \
    jq \
    make \
    gcc \
    pkg-config \
    clang \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# pgvectorscale depends on pgvector — install it first
RUN git clone --branch ${PGVECTOR_VERSION} --depth 1 \
    https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make -j$(nproc) \
    && make install

# Rust toolchain
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN git clone --branch ${PGVECTORSCALE_VERSION} --depth 1 \
    https://github.com/timescale/pgvectorscale.git /tmp/pgvectorscale

WORKDIR /tmp/pgvectorscale/pgvectorscale

# Install cargo-pgrx at the exact version expected by the project
RUN cargo install --locked cargo-pgrx \
    --version $(cargo metadata --format-version 1 | jq -r '.packages[] | select(.name == "pgrx") | .version')

# Initialize pgrx with the system pg_config — prevents pgrx from downloading its own PG
RUN cargo pgrx init --pg${PG_VERSION}=$(which pg_config)

# Build + install
RUN cargo pgrx install --release

# Verify (not guess) the actual files produced
RUN echo "=== installed pgvectorscale artifacts ===" \
    && find /usr/lib/postgresql/${PG_VERSION}/lib    -maxdepth 2 | grep vectorscale \
    && find /usr/share/postgresql/${PG_VERSION}/extension -maxdepth 1 | grep vectorscale

# Check runtime dependencies of the .so — any missing lib will show up here
RUN find /usr/lib/postgresql/${PG_VERSION}/lib -maxdepth 1 -name '*vectorscale*.so' \
    -exec echo "=== ldd: {} ===" \; \
    -exec ldd {} \;


# --- Stage 3: Build pg_textsearch ---
FROM ghcr.io/cloudnative-pg/postgresql:17 AS textsearch-builder

ARG PG_TEXTSEARCH_VERSION=main
ARG PGVECTOR_VERSION=v0.8.2
ARG PG_VERSION=17

USER root

RUN apt-get update && apt-get install -y \
    build-essential \
    postgresql-server-dev-${PG_VERSION} \
    git \
    && rm -rf /var/lib/apt/lists/*

# pg_textsearch depends on pgvector — install it first
RUN git clone --branch ${PGVECTOR_VERSION} --depth 1 \
    https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make -j$(nproc) \
    && make install

RUN git clone --branch ${PG_TEXTSEARCH_VERSION} --depth 1 \
    https://github.com/timescale/pg_textsearch.git /tmp/pg_textsearch \
    && cd /tmp/pg_textsearch \
    && make -j$(nproc) \
    && make install \
    && echo "=== installed pg_textsearch artifacts ===" \
    && find /usr/lib/postgresql/${PG_VERSION}/lib    -maxdepth 1 | grep textsearch \
    && find /usr/share/postgresql/${PG_VERSION}/extension -maxdepth 1 | grep textsearch


# --- Final Stage ---
FROM ghcr.io/cloudnative-pg/postgresql:17

ARG PG_VERSION=17

USER root

# Runtime libs required by pgvectorscale (compiled with Rust, linked against OpenSSL)
RUN apt-get update && apt-get install -y \
    libssl1.1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# --- pgvector ---
COPY --from=pgvector-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/vector.so \
    /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=pgvector-builder \
    /usr/share/postgresql/${PG_VERSION}/extension/vector* \
    /usr/share/postgresql/${PG_VERSION}/extension/

# --- pgvectorscale ---
# Broad pattern (*vectorscale*) to avoid assuming the exact filename produced by pgrx
COPY --from=pgvectorscale-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/*vectorscale*.so \
    /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=pgvectorscale-builder \
    /usr/share/postgresql/${PG_VERSION}/extension/vectorscale* \
    /usr/share/postgresql/${PG_VERSION}/extension/
COPY --from=pgvectorscale-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/ \
    /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/

# --- pg_textsearch ---
COPY --from=textsearch-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/pg_textsearch*.so \
    /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=textsearch-builder \
    /usr/share/postgresql/${PG_VERSION}/extension/pg_textsearch* \
    /usr/share/postgresql/${PG_VERSION}/extension/

# CloudNativePG runs as uid 26 (postgres)
USER 26