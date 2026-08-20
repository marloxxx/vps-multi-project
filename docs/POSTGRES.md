# PostgreSQL on the stack – server / backup

Single **postgres** container; data under `/opt/volumes/postgres`. You can run **multiple databases** on the same instance (create with `CREATE DATABASE ...`).

---

## Backups

**Safety model:** local `/opt/backups` is only staging. Real protection is **Google Drive** (rclone). Without `BACKUP_RCLONE_REMOTE`, the job **fails** by default (`BACKUP_REQUIRE_RCLONE=1`).

| Script | Purpose |
|--------|--------|
| `scripts/auto-backup.sh` | Dump DBs → prune local → **upload to Drive** |
| `scripts/setup-rclone-gdrive.sh` | Install rclone + Google Drive OAuth guide |
| `scripts/install-auto-backup.sh` | Install / remove `/etc/cron.d/stack-backup` |
| `scripts/backup-postgres.sh` | Dump **one** Postgres DB |
| `scripts/backup-postgres-all-dbs.sh` | Dump every non-template Postgres DB |
| `scripts/backup-mysql-all-dbs.sh` | Dump every non-system MySQL DB |
| `scripts/restore-drill.sh` | Prove a dump restores (temp DB) |

### 1. Google Drive first (required)

```bash
stackctl auto-backup gdrive-setup
sudo rclone config                  # remote name e.g. gdrive + OAuth

# /opt/stack/.env
BACKUP_RCLONE_REMOTE=gdrive:vps-backups/my-server
# BACKUP_REQUIRE_RCLONE=1
# BACKUP_RCLONE_MODE=copy

stackctl auto-backup gdrive-check
stackctl auto-backup enable
stackctl auto-backup run
```

Cron runs as **root** → `sudo rclone config`. Never commit `rclone.conf`.

### 2. Cron / local staging

```bash
stackctl auto-backup status
stackctl auto-backup enable
stackctl auto-backup run
```

| Variable | Default | Meaning |
|----------|---------|---------|
| `BACKUP_RCLONE_REMOTE` | _(empty)_ | **Required** — e.g. `gdrive:vps-backups/host` |
| `BACKUP_REQUIRE_RCLONE` | `1` | Fail if Drive upload did not succeed |
| `BACKUP_RCLONE_MODE` | `copy` | `copy` keeps extra Drive files; `sync` mirrors local |
| `BACKUP_RCLONE_CONFIG` | _(rclone default)_ | Path to root’s `rclone.conf` if needed |
| `BACKUP_UPLOAD_DIR` | `/opt/backups` | Folder uploaded to Drive |
| `BACKUP_RCLONE_ARGS` | `--transfers=4 --checkers=8` | Extra rclone flags |
| `BACKUP_CRON` | `0 3 * * *` | Schedule (re-`enable` after change) |
| `BACKUP_RETENTION_DAYS` | `7` | Local prune only |
| `BACKUP_POSTGRES_MODE` | `all` | `all` or `default` |
| `BACKUP_INCLUDE_MYSQL` | `auto` | `auto` / `1` / `0` |
| `BACKUP_DIR` | `/opt/backups/postgres` | Local Postgres dumps |
| `BACKUP_DIR_MYSQL` | `/opt/backups/mysql` | Local MySQL dumps |
| `BACKUP_LOG` | `/opt/backups/auto-backup.log` | Job log |

---

## Restore (manual)

```bash
# Create empty DB first if needed
docker exec postgres psql -U "$POSTGRES_USER" -d postgres -c 'CREATE DATABASE mydb;'
gunzip -c /opt/backups/postgres/pg_mydb_YYYYMMDD.sql.gz | docker exec -i postgres psql -U "$POSTGRES_USER" -d mydb
```

---

## Multiple databases

All DBs share the same Postgres data directory (one volume). Connection string differs only by **database name**:

`postgresql://user:pass@postgres:5432/dbname`

---

## Tuning (memory, checkpoints, connections)

Tuning Postgres **tidak menggantikan** perbaikan aplikasi (deadlock, query `OFFSET` besar). Tetap ukur RAM host dan beban nyata setelah deploy.

### 1. Tentukan RAM yang “terlihat” oleh Postgres

Di dalam container, Postgres memakai memori **host** (kecuali Anda set `mem_limit` di Docker). Anggap **25–40% RAM** untuk Postgres total (shared buffers + koneksi × `work_mem` + cache OS), selebihnya untuk OS, container lain, dan aplikasi.

Contoh VPS **4 GiB RAM**, satu DB berat:

| Parameter | Arah umum | Contoh konservatif |
|-----------|-----------|-------------------|
| `shared_buffers` | Cache data di Postgres | `512MB` – `1GB` (jangan setengah RAM kecuali khusus DWH) |
| `effective_cache_size` | Petunjuk planner (RAM OS + shared) | `2GB` – `3GB` |
| `work_mem` | Sort/hash **per operasi per query**; `× max_connections` bisa besar | `4MB` – `16MB` (turunkan jika OOM) |
| `maintenance_work_mem` | VACUUM, CREATE INDEX | `128MB` – `512MB` |
| `max_connections` | Setiap koneksi punya overhead | Sesuaikan pool app; default 100 sering berlebihan → **turunkan** atau naikkan RAM |

### 2. Kurangi lonjakan checkpoint (log `write=269s`)

Wal banyak dirty page → checkpoint panjang.

| Parameter | Fungsi |
|-----------|--------|
| `max_wal_size` | Naikkan (mis. `2GB`–`4GB`) agar checkpoint lebih jarang (trade-off: recovery lebih lama jika crash) |
| `checkpoint_timeout` | Default 5 menit; bisa `15min` bersama `max_wal_size` yang wajar |
| `checkpoint_completion_target` | `0.9` (spread flush) — sering sudah default di PG16 |

### 3. Cara menerapkan di stack ini

**Skrip (disarankan):** dari repo / `/opt/stack` setelah `git pull`:

```bash
cd /opt/stack
./scripts/tune-postgres.sh
./scripts/stack-manage.sh restart postgres
```

Skrip menunggu `pg_isready` hingga **120 detik** (ubah dengan `TUNE_WAIT_READY_SECONDS=300`). Jangan menjalankan saat container belum `Up` atau DB masih recovery — jika `psql` gagal dulu, **jalankan lagi** `tune-postgres.sh` setelah log menunjukkan *ready to accept connections*, lalu **restart** Postgres sekali lagi agar `shared_buffers` / `max_connections` terpakai.

Nilai default (~16 GiB RAM) bisa dioverride lewat env, contoh:

```bash
TUNE_SHARED_BUFFERS=1GB TUNE_EFFECTIVE_CACHE_SIZE=6GB ./scripts/tune-postgres.sh
```

**Opsi A — `ALTER SYSTEM` manual (setara isi skrip)**

```bash
set -a && source /opt/stack/.env && set +a
docker exec postgres psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c "
ALTER SYSTEM SET shared_buffers = '512MB';
ALTER SYSTEM SET effective_cache_size = '2GB';
ALTER SYSTEM SET work_mem = '8MB';
ALTER SYSTEM SET maintenance_work_mem = '256MB';
ALTER SYSTEM SET max_connections = '80';
ALTER SYSTEM SET max_wal_size = '2GB';
ALTER SYSTEM SET checkpoint_timeout = '15min';
"
docker compose -f /opt/stack/services/postgres/docker-compose.yml --env-file /opt/stack/.env restart postgres
```

Sesuaikan angka ke **RAM VPS** Anda sebelum menjalankan.

**Opsi B — override lewat `command` di `services/postgres/docker-compose.yml`**

Tambahkan pada service `postgres` (contoh; nilai wajib disesuaikan):

```yaml
command:
  - postgres
  - -c
  - shared_buffers=512MB
  - -c
  - effective_cache_size=2GB
  - -c
  - work_mem=8MB
  - -c
  - max_wal_size=2GB
  - -c
  - checkpoint_timeout=15min
```

Recreate container agar `command` terpakai. Catatan: jika sudah pakai `ALTER SYSTEM`, nilai di data dir bisa menang atau bentrok — pilih **satu** sumber kebenaran (biasanya `ALTER SYSTEM` + restart, tanpa duplikat di `command`).

### 4. Verifikasi

```bash
docker exec postgres psql -U "$POSTGRES_USER" -d postgres -c "SHOW shared_buffers; SHOW work_mem; SHOW max_connections; SHOW max_wal_size;"
```

### 5. SSD vs HDD

Di SSD/NVMe, planner sering diuntungkan dengan:

```sql
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;  -- Linux async read
```

(Hanya relevan jika storage benar-benar cepat.)

### 6. Alat bantu sizing

- [pgtune](https://pgtune.leopard.in.ua/) — masukkan RAM dan tipe workload, salin saran lalu sesuaikan konservatif untuk VPS kecil.
- Pantau: `docker logs postgres`, `pg_stat_statements` (extension), dan `EXPLAIN (ANALYZE, BUFFERS)` untuk query berat.

---

## pgvector (vector similarity search)

The `postgres` service image is `pgvector/pgvector:pg16-trixie` (Debian 13 base;
pgvector ships no Alpine variant), which bundles the
[pgvector](https://github.com/pgvector/pgvector) extension binaries on top of a
regular `postgres:16` image. The extension is **not** enabled by default — it
must be created **per database**, only for the projects that need it:

```bash
set -a && source /opt/stack/.env && set +a
docker exec postgres psql -U "$POSTGRES_USER" -d <dbname> -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Run this after `stackctl provision-postgres <project>` (using `<project>_db` as
`<dbname>`) if that project needs vector search.

Verify:

```bash
docker exec postgres psql -U "$POSTGRES_USER" -d <dbname> -c "\dx vector"
```

Example table with a vector column and an HNSW index (adjust dimensions to match
your embedding model):

```sql
CREATE TABLE items (
  id bigserial PRIMARY KEY,
  embedding vector(1536)
);
CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);
```

**Upgrading an existing stack:** pulling the new image and recreating the
container (`stackctl restart postgres` or `docker compose ... up -d postgres`) is
safe — it is still Postgres 16 (same data directory layout), only the OS base
moves from Alpine to Debian trixie and the extension binaries are added. No
dump/restore needed.

---

## Related

- `.env` – `POSTGRES_USER`, `POSTGRES_PASSWORD`, `BACKUP_DIR`, auto-backup vars (`BACKUP_RETENTION_DAYS`, `BACKUP_CRON`, …)
- `services/postgres/docker-compose.yml` – container definition (`shm_size`, `stop_grace_period`, healthcheck)
- `stackctl auto-backup` – enable / disable / run scheduled backups
