# PostgreSQL on the stack – server / backup

Single **postgres** container; data under `/opt/volumes/postgres`. You can run **multiple databases** on the same instance (create with `CREATE DATABASE ...`).

---

## Backups

| Script | Purpose |
|--------|--------|
| `scripts/backup-postgres.sh` | Dumps **one** DB (`POSTGRES_DB` from `.env`) |
| `scripts/backup-postgres-all-dbs.sh` | Dumps **every** non-template DB (optional `DB_PREFIX=` to filter by name prefix) |
| `scripts/restore-drill.sh` | Restores a dump into a **temporary** DB then drops it (proves backups work) |

Cron for single DB is installed by `setup.sh` (daily 03:00). For **all DBs**, add a second cron line calling `backup-postgres-all-dbs.sh` if needed.

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

## Related

- `.env` – `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `BACKUP_DIR`
- `services/postgres/docker-compose.yml` – container definition
