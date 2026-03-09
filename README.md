# Fundy Research CNPG

A custom PostgreSQL Docker image for use with the [CloudNativePG](https://cloudnative-pg.io/) operator, featuring pgvector, pgvectorscale, and pg_textsearch extensions for AI-powered vector and text search.

## Purpose

This image extends the official CloudNativePG PostgreSQL base image with:
- **pgvector** - Open-source vector similarity search for PostgreSQL
- **pgvectorscale** - High-performance StreamingDiskANN index for pgvector (Rust/PGRX extension by Timescale)
- **pg_textsearch** - BM25 relevance-ranked full-text search for PostgreSQL

Together, these extensions enable hybrid search (vector similarity + BM25 keyword ranking) directly in PostgreSQL.

## Included Extensions

| Extension | Default Version | Source |
|-----------|-----------------|--------|
| pgvector | v0.8.2 | [pgvector/pgvector](https://github.com/pgvector/pgvector) |
| pgvectorscale | 0.9.0 | [timescale/pgvectorscale](https://github.com/timescale/pgvectorscale) |
| pg_textsearch | main | [timescale/pg_textsearch](https://github.com/timescale/pg_textsearch) |

## Supported Architectures

- `linux/amd64` (x86_64)
- `linux/arm64` (ARM64/AWS Graviton)

> **Note:** pgvectorscale requires AVX2+FMA on x86_64 and NEON on ARM64. Most modern CPUs support these. If running on VMs, verify the hypervisor exposes these instruction sets:
> ```bash
> grep -o 'avx2\|fma' /proc/cpuinfo | sort -u  # x86_64
> grep -o 'neon\|asimd' /proc/cpuinfo | sort -u  # arm64
> ```

## Usage with CloudNativePG

Create a CloudNativePG Cluster manifest that uses this image:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: research-cluster
spec:
  instances: 2
  imageName: ghcr.io/stainly/fundy_research_cnpg:v1.0.0

  postgresql:
    shared_preload_libraries:
      - pg_textsearch
    parameters:
      pg_textsearch.default_limit: "1000"

  storage:
    size: 10Gi
    storageClass: your-storage-class

  bootstrap:
    initdb:
      database: app
      owner: app
```

After the cluster is running, enable extensions in your database:

```sql
-- Enable pgvectorscale (CASCADE auto-installs pgvector)
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;

-- Enable pg_textsearch
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
```

## Building Locally

### Build with default versions

```bash
docker build -t fundy_research_cnpg:local .
```

### Build with custom versions

```bash
docker build \
  --build-arg PGVECTOR_VERSION=v0.8.2 \
  --build-arg PGVECTORSCALE_VERSION=0.9.0 \
  --build-arg PG_TEXTSEARCH_VERSION=main \
  --build-arg PG_VERSION=17 \
  -t fundy_research_cnpg:local .
```

### Build for specific platform

```bash
# For ARM64 (e.g., AWS Graviton, Apple Silicon)
docker build --platform linux/arm64 -t fundy_research_cnpg:local-arm64 .

# For AMD64
docker build --platform linux/amd64 -t fundy_research_cnpg:local-amd64 .
```

> **Note:** The build includes compiling Rust code (pgvectorscale via PGRX), so it takes significantly longer than a standard C extension build (~10-20 min depending on hardware).

## Creating a New Release

1. Create and push a new git tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

2. The GitHub Actions workflow will automatically build and push the image to GHCR with the tag.

### Tag Naming Convention

Recommended tag format: `v<release>-pg<pg_version>`

Examples:
- `v1.0.0` - Simple version
- `v1.0.0-pg17` - Version with PostgreSQL version

## Image Tags

| Tag | Description |
|-----|-------------|
| `latest` | Latest build from main branch |
| `pg17-latest` | Latest PostgreSQL 17 build from main branch |
| `v*` | Specific release version |
| `<sha>` | Git commit SHA for traceability |

## Quick Usage Examples

### Vector Search with StreamingDiskANN

```sql
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT,
    embedding VECTOR(1536)
);

CREATE INDEX ON documents USING diskann (embedding vector_cosine_ops);

SELECT id, content
FROM documents
ORDER BY embedding <=> '[0.1, 0.2, ...]'
LIMIT 10;
```

### BM25 Text Search

```sql
CREATE INDEX ON documents USING bm25(content) WITH (text_config='english');

SELECT id, content
FROM documents
ORDER BY content <@> 'search query'
LIMIT 10;
```

## Notes

- This image is designed for CloudNativePG and does **not** include Patroni or pgBackRest (CNPG handles HA and backups differently)
- `pg_textsearch` must be added to `shared_preload_libraries` in the CNPG Cluster manifest
- pgvectorscale automatically installs pgvector as a dependency when using `CASCADE`
- The image runs as user 26 (postgres) as required by CloudNativePG
- pgvectorscale requires CPU support for AVX2+FMA (x86_64) or NEON (ARM64)

## License

This project builds upon open-source components:
- PostgreSQL: [PostgreSQL License](https://www.postgresql.org/about/licence/)
- pgvector: [PostgreSQL License](https://github.com/pgvector/pgvector/blob/master/LICENSE)
- pgvectorscale: [PostgreSQL License](https://github.com/timescale/pgvectorscale/blob/main/LICENSE)
- pg_textsearch: [PostgreSQL License](https://github.com/timescale/pg_textsearch/blob/main/LICENSE)
- CloudNativePG base image: [Apache 2.0](https://github.com/cloudnative-pg/cloudnative-pg/blob/main/LICENSE)
