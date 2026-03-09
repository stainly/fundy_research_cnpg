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
    && echo "=== Verifying pgvector installation ===" \
    && ls -la /usr/lib/postgresql/${PG_VERSION}/lib/ | grep -i vector || echo "No pgvector files in lib" \
    && ls -la /usr/share/postgresql/${PG_VERSION}/extension/ | grep -i vector || echo "No pgvector files in extension"

# --- Stage 2: Build pgvectorscale (Rust/PGRX) ---
FROM ghcr.io/cloudnative-pg/postgresql:17 AS pgvectorscale-builder

ARG PGVECTORSCALE_VERSION=0.9.0
ARG PGVECTOR_VERSION=v0.8.2
ARG PG_VERSION=17

USER root

# Install build dependencies including Rust toolchain prerequisites
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

# pgvectorscale depends on pgvector being installed first
RUN git clone --branch ${PGVECTOR_VERSION} --depth 1 \
    https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make -j$(nproc) \
    && make install

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Clone pgvectorscale
RUN git clone --branch ${PGVECTORSCALE_VERSION} --depth 1 \
    https://github.com/timescale/pgvectorscale.git /tmp/pgvectorscale

WORKDIR /tmp/pgvectorscale/pgvectorscale

# Install cargo-pgrx matching the version used by the project
RUN cargo install --locked cargo-pgrx --version $(cargo metadata --format-version 1 | jq -r '.packages[] | select(.name == "pgrx") | .version')

# Initialize pgrx with system PostgreSQL
RUN cargo pgrx init --pg${PG_VERSION} pg_config

# Build and install pgvectorscale
RUN cargo pgrx install --release \
    && echo "=== Verifying pgvectorscale installation ===" \
    && ls -la /usr/lib/postgresql/${PG_VERSION}/lib/ | grep -i vectorscale || echo "No pgvectorscale files in lib" \
    && ls -la /usr/share/postgresql/${PG_VERSION}/extension/ | grep -i vectorscale || echo "No pgvectorscale files in extension"

# --- Stage 3: Build pg_textsearch ---
FROM ghcr.io/cloudnative-pg/postgresql:17 AS textsearch-builder

ARG PG_TEXTSEARCH_VERSION=main
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
    && ls -la /usr/lib/postgresql/${PG_VERSION}/lib/ | grep -i textsearch || echo "No pg_textsearch files in lib" \
    && ls -la /usr/share/postgresql/${PG_VERSION}/extension/ | grep -i textsearch || echo "No pg_textsearch files in extension"

# --- Final Stage ---
FROM ghcr.io/cloudnative-pg/postgresql:17

ARG PG_VERSION=17

USER root

# Copy pgvector extension files
COPY --from=pgvector-builder /usr/lib/postgresql/${PG_VERSION}/lib/vector.so /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=pgvector-builder /usr/share/postgresql/${PG_VERSION}/extension/vector* /usr/share/postgresql/${PG_VERSION}/extension/

# Copy pgvectorscale extension files
COPY --from=pgvectorscale-builder /usr/lib/postgresql/${PG_VERSION}/lib/pgvectorscale*.so /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=pgvectorscale-builder /usr/share/postgresql/${PG_VERSION}/extension/vectorscale* /usr/share/postgresql/${PG_VERSION}/extension/

# Copy pg_textsearch extension files
COPY --from=textsearch-builder /usr/lib/postgresql/${PG_VERSION}/lib/pg_textsearch*.so /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=textsearch-builder /usr/share/postgresql/${PG_VERSION}/extension/pg_textsearch* /usr/share/postgresql/${PG_VERSION}/extension/

# CloudNativePG runs with user 26 (postgres)
USER 26
