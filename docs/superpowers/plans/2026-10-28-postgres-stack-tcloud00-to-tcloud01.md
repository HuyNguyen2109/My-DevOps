# PostgreSQL Stack Migration (talos-cloud-00 → talos-cloud-01) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Move the postgresql + pgbouncer stacks from x86_64 talos-cloud-00 to ARM64 talos-cloud-01, validate, then re-point every DB client on t00, tower, and t01.

**Architecture:** Rehearsal physical `pg_basebackup` restore on t01 → brief write-freeze cutover with a final basebackup → recreate Databasus slot → re-point clients to `100.88.110.94:5432` (Tailscale) or `postgres:5432` (OpenBao, same docker network).

**Tech Stack:** Docker Compose, PostgreSQL 18 (`pgvector/pgvector:pg18-trixie`, arm64), PgBouncer v1.25.2, pgAdmin4 9.16, Databasus, Tailscale, Arcane.

## Global Constraints

- Source: `ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00` (x86_64, Tailscale `100.116.205.94`)
- Target: `ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01` — **use `sudo -n docker`** (aarch64, Tailscale `100.88.110.94`)
- Tower: `ssh -i /root/.secrets/ssh-keys/homelab-linux root@unraid.internal` (Tailscale `100.70.225.21`)
- Source PGDATA: `/var/lib/docker-stack-data/postgres/postgres-data/18/docker` (uid/gid `999:999`), container path `/var/lib/postgresql/18/docker`
- Target data root: `/docker-volume/docker-stack-data/postgres`
- Target Arcane projects: `/docker-volume/arcane/projects/{PostgreSQL,PgBouncer}`
- Target binds: pgbouncer `100.88.110.94:5432`, pgadmin4 `100.88.110.94:3001` (3000 = obs-grafana), databasus `100.88.110.94:4005`
- Replication slot: `databasus_slot_2cbac9339c6c4249aecd615688593104` (single-quoted in SQL)
- Old t00 stack stays running/intact until all clients verified.
- Artifacts on controller: `/tmp/opencode/migration-t01/`

---

### Task 1: Snapshot source + baseline

**Files:** none

- [ ] **Step 1: Baseline (9 DBs + roles + sizes)**

```bash
mkdir -p /tmp/opencode/migration-t01
ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00 \
 'docker exec postgres18 psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;" && echo "---ROLES---" && docker exec postgres18 psql -U postgres -tAc "SELECT rolname,rolcanlogin,rolsuper FROM pg_roles WHERE rolcanlogin ORDER BY 1;" && echo "---SIZES---" && docker exec postgres18 psql -U postgres -tAc "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate=false ORDER BY 1;"' \
 > /tmp/opencode/migration-t01/baseline.txt
cat /tmp/opencode/migration-t01/baseline.txt
```
Expected: 9 DBs, 11+ roles, sizes (benchmarkdb 760MB, immichdb 269MB, kanbn 10MB, pocketid-db 9502kB, postgres 7878kB, termix 24MB, vault-data 43MB, vault-data-oci 8278kB, zitadel 26MB).

- [ ] **Step 2: Physical + logical backups**

```bash
ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00 \
 'docker exec postgres18 pg_basebackup -h 127.0.0.1 -U postgres -D - -Ft -z -X fetch' \
 > /tmp/opencode/migration-t01/postgres-basebackup.tar.gz
ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00 \
 'docker exec postgres18 pg_dumpall -h 127.0.0.1 -U postgres' \
 > /tmp/opencode/migration-t01/postgres-dumpall.sql
gzip -t /tmp/opencode/migration-t01/postgres-basebackup.tar.gz && echo "gzip OK"
ls -lh /tmp/opencode/migration-t01/
```
Expected: basebackup ~200-250 MB (gzip), dumpall ~700 MB, `gzip OK`.

---

### Task 2: Provision target

**Files:** target dirs

- [ ] **Step 1: Create `db-intranet`, dirs, Arcane project dirs**

```bash
ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01 \
 'sudo -n docker network create --driver bridge db-intranet 2>&1 || echo exists; \
  sudo -n mkdir -p /docker-volume/docker-stack-data/postgres/{postgres-data,pgbouncer,pgadmin4,databasus} \
     /docker-volume/arcane/projects/PostgreSQL /docker-volume/arcane/projects/PgBouncer; \
  sudo -n ls -ld /docker-volume/docker-stack-data/postgres /docker-volume/arcane/projects/PostgreSQL'
```
Expected: `db-intranet` created; dirs exist.

---

### Task 3: Deploy Postgres on target + restore (rehearsal)

**Files:** `/docker-volume/arcane/projects/PostgreSQL/{compose.yaml,.env}`

- [ ] **Step 1: Copy `.env` from source, set MASTER_DIR**

```bash
ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00 \
 'cat /mnt/docker-data/arcane/projects/PostgreSQL/.env' > /tmp/opencode/migration-t01/pg.env
sed -i 's|^MASTER_DIR=.*|MASTER_DIR=/docker-volume/docker-stack-data/postgres|' /tmp/opencode/migration-t01/pg.env
scp -i /root/.secrets/ssh-keys/oracle /tmp/opencode/migration-t01/pg.env \
 opc@talos-cloud-01:/tmp/pg.env
ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01 \
 'sudo -n cp /tmp/pg.env /docker-volume/arcane/projects/PostgreSQL/.env && sudo -n grep MASTER_DIR /docker-volume/arcane/projects/PostgreSQL/.env'
```
Expected: `MASTER_DIR=/docker-volume/docker-stack-data/postgres`.

- [ ] **Step 2: Write compose (PostgreSQL stack: postgres, pgadmin4, databasus) and scp**

Use this exact content (adapt ports to `100.88.110.94`, pgadmin `3001`):

```yaml
services:
  postgres:
    image: pgvector/pgvector:${POSTGRES18_IMAGE_TAG}
    container_name: postgres18
    logging:
      driver: json-file
      options: {max-size: 50m, max-file: "3"}
    user: 0:0
    hostname: postgres
    restart: always
    shm_size: 1gb
    env_file: [.env]
    networks:
      db-intranet: {}
    mem_limit: 1G
    mem_reservation: 1G
    cpus: 2
    volumes:
      - ${MASTER_DIR}/postgres-data:/var/lib/postgresql
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
  pgadmin4:
    image: dpage/pgadmin4:${PGADMIN_IMAGE_TAG:-9.16}
    container_name: pgadmin4
    logging:
      driver: json-file
      options: {max-size: 50m, max-file: "3"}
    hostname: pgadmin
    env_file: [.env]
    ports:
      - "100.88.110.94:3001:80"
    volumes:
      - ${MASTER_DIR}/pgadmin4:/var/lib/pgadmin
    networks:
      db-intranet: {}
    restart: unless-stopped
    environment:
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_DEFAULT_PASSWORD}
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_DEFAULT_EMAIL}
      PGADMIN_CONFIG_LOG_FILE: "'/dev/null'"
    mem_limit: 1G
    mem_reservation: 256m
    cpus: 1
  databasus:
    container_name: databasus
    logging:
      driver: json-file
      options: {max-size: 50m, max-file: "3"}
    image: databasus/databasus:latest
    ports:
      - "100.88.110.94:4005:4005"
    volumes:
      - ${MASTER_DIR}/databasus:/databasus-data
    restart: unless-stopped
    networks:
      db-intranet: {}
    mem_limit: 512M
    mem_reservation: 256m
    cpus: 1
networks:
  db-intranet:
    external: true
```
```bash
scp -i /root/.secrets/ssh-keys/oracle /tmp/opencode/migration-t01/compose.yaml \
 opc@talos-cloud-01:/tmp/compose.yaml
```
(Write the YAML locally first, then copy to the Arcane project dir.)

- [ ] **Step 3: Restore basebackup into PGDATA**

```bash
scp -i /root/.secrets/ssh-keys/oracle /tmp/opencode/migration-t01/postgres-basebackup.tar.gz opc@talos-cloud-01:/tmp/
ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01 \
 'sudo -n mkdir -p /docker-volume/docker-stack-data/postgres/postgres-data/18/docker && \
  sudo -n tar -xzf /tmp/postgres-basebackup.tar.gz -C /docker-volume/docker-stack-data/postgres/postgres-data/18/docker && \
  sudo -n chown -R 999:999 /docker-volume/docker-stack-data/postgres/postgres-data/18/docker && \
  sudo -n ls /docker-volume/docker-stack-data/postgres/postgres-data/18/docker | head'
```
Expected: `base global pg_wal PG_VERSION postgresql.conf pg_hba.conf ...`.

- [ ] **Step 4: Start postgres + verify arch/data**

```bash
ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01 \
 'cd /docker-volume/arcane/projects/PostgreSQL && sudo -n docker compose up -d postgres && sleep 10 && sudo -n docker exec postgres18 pg_isready -U postgres && sudo -n docker inspect postgres18 --format "arch={{.Platform}}" 2>/dev/null; sudo -n docker exec postgres18 uname -m'
```
Expected: `accepting connections`, `aarch64`.

- [ ] **Step 5: Verify DBs/roles/sizes match baseline** (same query as Task 1; compare names/roles exactly; sizes informational).

---

### Task 4: Deploy PgBouncer on target

**Files:** `PgBouncer/{compose.yaml,.env}`, config files

- [ ] **Step 1: Copy pgbouncer config from source**

```bash
scp -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00:/var/lib/docker-stack-data/postgres/pgbouncer/pgbouncer.ini /tmp/opencode/migration-t01/
scp -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00:/var/lib/docker-stack-data/postgres/pgbouncer/userlist.txt /tmp/opencode/migration-t01/
scp -i /root/.secrets/ssh-keys/oracle /tmp/opencode/migration-t01/pgbouncer.ini /tmp/opencode/migration-t01/userlist.txt opc@talos-cloud-01:/tmp/
ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01 'sudo -n cp /tmp/pgbouncer.ini /tmp/userlist.txt /docker-volume/docker-stack-data/postgres/pgbouncer/ && sudo -n head -3 /docker-volume/docker-stack-data/postgres/pgbouncer/pgbouncer.ini'
```
Expected: `[databases]` / `* = host=postgres port=5432 pool_mode=session`.

- [ ] **Step 2: Write PgBouncer compose (bind `100.88.110.94:5432`) and `.env` (`MASTER_DIR`, `PGBOUNCER_IMAGE_TAG`), then start + verify `SELECT 1` via pgbouncer and `ss` shows only `100.88.110.94:5432`.

---

### Task 5: Deploy pgAdmin + Databasus, migrate data, re-point Databasus

- [ ] **Step 1: Stop source databasus + pgadmin4 briefly for a consistent copy, then copy and restart**

```bash
ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00 \
 'docker stop databasus pgadmin4 && tar -C /var/lib/docker-stack-data/postgres -czf - pgadmin4 databasus' \
 | ssh -i /root/.secrets/ssh-keys/oracle opc@talos-cloud-01 \
   'sudo -n tar -C /docker-volume/docker-stack-data/postgres -xzf -'
ssh -i /root/.secrets/ssh-keys/oracle root@talos-cloud-00 'docker start databasus pgadmin4'
```
Verify `databasus/{pgdata,secret.key,instance.json,backups}` present. (Stopping Databasus does not affect the slot; streaming resumes on start.)

- [ ] **Step 2: Start pgadmin4 + databasus; verify pgadmin HTTP 302 on `100.88.110.94:3001`, databasus healthy on 4005.

- [ ] **Step 3: Recreate replication slot on new primary (single quotes), then verify `pg_stat_replication` shows `databasus_wal_receiver... | streaming`.

- [ ] **Step 4: Databasus re-point check**: confirm its managed instance uses hostname `postgres` (works on db-intranet); if not, update via Databasus API/UI. Verify WAL queue + S3 config intact.

---

### Task 6: Pre-cutover connectivity gate

- [ ] From t00: `psql -h 100.88.110.94 -p 5432 -U postgres -d postgres -c "SELECT 1"`.
- [ ] From tower: same.
- [ ] From t01 local: `sudo -n docker run --rm --network db-intranet postgres:18 psql -h 100.88.110.94 -p 5432 ...` (expect `1`).
- [ ] `ss -tlnp` on t01 shows only `100.88.110.94:5432/3001/4005` for the stack.
- [ ] `SHOW POOLS` on new pgbouncer responds.

---

### Task 7: Cutover (freeze + final sync)

- [ ] **Step 1: Freeze writes**: stop t00 `pgbouncer` + `openbao-oci` (direct writer to `vault-data-oci`). Databasus is replication-only.
- [ ] **Step 2: Final basebackup** to `/tmp/opencode/migration-t01/postgres-final-backup.tar.gz`; `gzip -t`.
- [ ] **Step 3: Restore final over rehearsal**: on t01 `docker compose down`, `rm -rf .../18/docker/*`, extract, `chown 999:999`, `docker compose up -d` (all services), `pg_isready`.
- [ ] **Step 4: Recreate slot** (single quotes) + verify streaming.
- [ ] **Step 5: Consistency gate**: 9 DB names match baseline; `DBS MATCH`.

---

### Task 8: Re-point every client + validate

| # | Client / host | Change | Verify |
|---|---|---|---|
| 1 | zitadel-api (t00) | `Zitadel/.env` DSN host `pgbouncer` → `100.88.110.94` | container healthy; logs no auth errors |
| 2 | kanbn (t00) | `kanbn/.env` `POSTGRES_URL` host `pgbouncer` → `100.88.110.94` | `kan-web` up; migration log OK |
| 3 | immich-server (tower) | `Immich/.env` `DB_HOSTNAME=100.116.205.94` → `100.88.110.94` | healthy; no schema drift |
| 4 | termix (tower) | `DATABASE_URL` host `100.116.205.94` → `100.88.110.94` | healthy |
| 5 | openbao-oci (t01) | attach to `db-intranet`; `bao-config.hcl` storage URL → `postgres://vault-admin:***@postgres:5432/vault-data-oci?sslmode=disable`; stop+disable `db-tunnel.service` | `bao status` unsealed; a KV write/read succeeds |

Each: edit config → recreate → verify health + logs; do one client at a time.

---

### Task 9: Final verification + rollback posture

- [ ] `SHOW POOLS` on new pgbouncer shows all client DBs active (zitadel, kanbn, immichdb, termix, vault-data-oci).
- [ ] All clients healthy; databasus streaming + S3 intact.
- [ ] Keep t00 stack stopped-but-intact as rollback; document revert steps.
- [ ] Update repo copies `docker/standalone/{postgresql,pgbouncer}/compose.yaml` to the new host/ports; commit docs + artifacts.

## Rollback

Revert each client DSN to the old endpoint (`pgbouncer:5432` / `100.116.205.94`), restart openbao/pgbouncer on t00, stop t01 stack. Old data untouched.
