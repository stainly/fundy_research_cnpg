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
    && make install

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

# :white_check_mark: FIX: pgvectorscale dépend de pgvector
RUN git clone --branch ${PGVECTOR_VERSION} --depth 1 \
    https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make -j$(nproc) \
    && make install

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

RUN git clone --branch ${PGVECTORSCALE_VERSION} --depth 1 \
    https://github.com/timescale/pgvectorscale.git /tmp/pgvectorscale

WORKDIR /tmp/pgvectorscale/pgvectorscale

RUN cargo install --locked cargo-pgrx \
    --version $(cargo metadata --format-version 1 | jq -r '.packages[] | select(.name == "pgrx") | .version')

# :white_check_mark: FIX: utilise pg_config système, évite le téléchargement de PG par pgrx
RUN cargo pgrx init --pg${PG_VERSION}=$(which pg_config)

RUN cargo pgrx install --release

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

# :white_check_mark: FIX: pg_textsearch dépend de pgvector, on l'installe ici aussi
RUN git clone --branch ${PGVECTOR_VERSION} --depth 1 \
    https://github.com/pgvector/pgvector.git /tmp/pgvector \
    && cd /tmp/pgvector \
    && make -j$(nproc) \
    && make install

RUN git clone --branch ${PG_TEXTSEARCH_VERSION} --depth 1 \
    https://github.com/timescale/pg_textsearch.git /tmp/pg_textsearch \
    && cd /tmp/pg_textsearch \
    && make -j$(nproc) \
    && make install

# --- Final Stage ---
FROM ghcr.io/cloudnative-pg/postgresql:17
ARG PG_VERSION=17

USER root

# :white_check_mark: FIX: installer les libs runtime nécessaires à pgvectorscale (Rust/OpenSSL)
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# pgvector
COPY --from=pgvector-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/vector.so \
    /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=pgvector-builder \
    /usr/share/postgresql/${PG_VERSION}/extension/vector* \
    /usr/share/postgresql/${PG_VERSION}/extension/

# pgvectorscale
COPY --from=pgvectorscale-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/*vectorscale*.so \
    /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=pgvectorscale-builder \
    /usr/share/postgresql/${PG_VERSION}/extension/vectorscale* \
    /usr/share/postgresql/${PG_VERSION}/extension/
COPY --from=pgvectorscale-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/ \
    /usr/lib/postgresql/${PG_VERSION}/lib/bitcode/

# pg_textsearch
COPY --from=textsearch-builder \
    /usr/lib/postgresql/${PG_VERSION}/lib/pg_textsearch*.so \
    /usr/lib/postgresql/${PG_VERSION}/lib/
COPY --from=textsearch-builder \
    /usr/share/postgresql/${PG_VERSION}/extension/pg_textsearch* \
    /usr/share/postgresql/${PG_VERSION}/extension/

USER 26