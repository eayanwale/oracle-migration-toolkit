# oracle-migration-toolkit

Standalone Oracle database migration scripts — Data Pump export, import, local migration, and remote/cloud migration with dynamic remote script generation over SSH.

## Background

These scripts were extracted and refactored from [Control-Script_SH v1.19](https://github.com/eayanwale/Control-Script_SH) (now archived), a monolithic Oracle DBA utility I built and maintained. The original script handled everything in one file — exports, imports, migrations, file transfers, disk monitoring, and cleanup — with hardcoded paths, inline credentials, and no argument validation.

This repo breaks those functions into standalone, composable scripts that follow the same conventions established in my general-purpose [linux-automation-toolkit](https://github.com/eayanwale/linux-automation-toolkit): `getopts` argument parsing, consistent exit codes, `--dry-run` on destructive operations, and timestamped logging.

The general-purpose scripts (disk monitoring, backup rotation, file transfer, system health) live in `linux-automation-toolkit`. This repo contains only the Oracle-specific migration tooling.

## What's in the repo

| Script | What it does | Origin |
|--------|-------------|--------|
| `bin/ora-export.sh` | Data Pump schema export with parfile, tar archival, and manifest logging | Extracted from `DATABASE_BACKUP()` |
| `bin/ora-import.sh` | Data Pump schema import with tar extraction, remap, and post-import verification | Extracted from `DATABASE_IMPORT()` |
| `bin/ora-migrate-local.sh` | Orchestrates export → import on the same server | Extracted from `LOCAL_MIGRATION()` |
| `bin/ora-migrate-cloud` | End-to-end on-prem → remote/cloud migration with dynamic remote script generation | Extracted from `CLOUD_MIGRATION()` |
| `lib/ora-common.sh` | Shared helper functions sourced by all scripts | New — replaces duplicated logic |

## Prerequisites

- Oracle Database with Data Pump (`expdp`/`impdp`) configured
- Oracle environment files (e.g., `oracle_env_DBNAME.sh`) setting `ORACLE_HOME` and `ORACLE_SID`
- An Oracle user with access to `v$instance`, `dba_users`, and `dba_directories`
- Data Pump directory object configured in Oracle (e.g., `DATA_PUMP_DIR`)
- Bash 4+
- For cloud migration: SSH key access to the remote server

## Quick start

```bash
git clone https://github.com/eayanwale/oracle-migration-toolkit.git
cd oracle-migration-toolkit
chmod +x bin/*

# Dry run — validate without exporting:
./bin/ora-export.sh --dry-run \
  -d APEXDB \
  -q "select username from dba_users where username like 'STACK%'"

# Full export (DPUMP_DIR defaults to DATA_PUMP_DIR):
./bin/ora-export.sh \
  -d APEXDB \
  -q "select username from dba_users where username like 'STACK%'" \
  -c "/@APEXDB"

# Import from the manifest produced by the export (schemas + archive resolved automatically):
./bin/ora-import.sh \
  -d FREEPDB1 \
  -f /backup/exports/2026-05-20_export_APEXDB_manifest.log \
  -c "/@FREEPDB1"

# Import from a tar archive with schema remap (STACK_USER -> STACK_USER_DEV):
./bin/ora-import.sh \
  -d FREEPDB1 \
  -f /backup/exports/2026-05-20_export_APEXDB.tar.gz \
  -s "/@APEXDB" \
  -q "select username from dba_users where username='STACK_USER'" \
  -r DEV \
  -c "/@FREEPDB1"
```

## Script details

### ora-export.sh

Exports one or more Oracle schemas via Data Pump. Runs a SQL query to discover schemas, creates a secure parfile per schema (`chmod 600`), verifies the export log for success/warning/failure strings, archives dump and log files into a `.tar.gz`, and appends a record to a pipe-delimited manifest file.

```bash
# Export schemas matching a query:
./bin/ora-export.sh -d APEXDB -D EXPORT_DIR \
  -q "select username from dba_users where username like 'STACK%'" \
  -c "/@APEXDB"

# Custom threshold and parallel degree:
./bin/ora-export.sh -d APEXDB -D EXPORT_DIR \
  -q "select username from dba_users where username like 'STACK%'" \
  -t 90 -P 4

# Dry run:
./bin/ora-export.sh --dry-run -d APEXDB -D EXPORT_DIR \
  -q "select username from dba_users where username like 'STACK%'"
```

### ora-import.sh

Imports schemas into a target database from a `.dmp`, `.tar`/`.tar.gz`/`.tgz` archive, or an export manifest. When given a manifest, the schema list and tar path are resolved automatically; otherwise the schema list is discovered via a SQL query (`-q`) against a source connection (`-s`). Supports `REMAP_SCHEMA` via a `-r SUFFIX` flag (every source schema `X` is remapped to `X_<SUFFIX>`), and runs a post-import object count against `dba_objects` per schema.

```bash
# Import from a manifest (schemas and tar resolved automatically):
./bin/ora-import.sh -d FREEPDB1 \
  -f /backup/exports/2026-05-20_export_APEXDB_manifest.log

# Import a tar archive with schema discovery against a source DB, with suffix remap:
./bin/ora-import.sh -d FREEPDB1 \
  -f /backup/exports/2026-05-20_export_APEXDB.tar.gz \
  -s "/@APEXDB" \
  -q "select username from dba_users where username like 'STACK%'" \
  -r DEV

# Import a single .dmp as-is (still needs -s/-q to know which schemas to import):
./bin/ora-import.sh -d FREEPDB1 \
  -f /data/imports/STACK_USER.dmp \
  -s "/@APEXDB" \
  -q "select username from dba_users where username='STACK_USER'"

# Dry run:
./bin/ora-import.sh --dry-run -d FREEPDB1 \
  -f /backup/exports/2026-05-20_export_APEXDB_manifest.log
```

### ora-migrate-local.sh

Orchestrates a full local migration by calling `ora-export.sh` then `ora-import.sh` on the same server. Passes flags through to both scripts.

```bash
# Migrate schemas from APEXDB to DEVDB (DPUMP_DIR defaults to DATA_PUMP_DIR):
./bin/ora-migrate-local.sh \
  -s APEXDB -d DEVDB \
  -q "select username from dba_users where username like 'STACK%'"

# Dry run:
./bin/ora-migrate-local.sh --dry-run \
  -s APEXDB -d DEVDB \
  -q "select username from dba_users where username like 'STACK%'"
```

### ora-migrate-cloud

End-to-end migration from an on-prem Oracle database to a remote (cloud) instance. Exports locally via `ora-export.sh`, transfers the tar archive and manifest to the remote host via `scp`, dynamically generates a remote import script tailored to the destination environment, then pushes and executes it over `ssh`. The remote script extracts the archive into the destination's Data Pump directory and runs per-schema `impdp` with optional `remap_schema` suffix.

```bash
# Migrate to a remote host (e.g. AWS EC2):
./bin/ora-migrate-cloud \
  -s APEXDB -d CLOUDDB \
  -H ec2-xx-xx-xx-xx.compute.amazonaws.com \
  -u ec2-user \
  -i ~/.ssh/aws.pem \
  -p /u01/app/oracle/admin/CLOUDDB/dpdump \
  -q "select username from dba_users where username like 'STACK%'"

# Dry run:
./bin/ora-migrate-cloud --dry-run \
  -s APEXDB -d CLOUDDB \
  -H ec2-xx-xx-xx-xx.compute.amazonaws.com \
  -u ec2-user \
  -i ~/.ssh/aws.pem \
  -p /u01/app/oracle/admin/CLOUDDB/dpdump \
  -q "select username from dba_users where username like 'STACK%'"
```

### lib/ora-common.sh

Shared library sourced by all scripts. Not executable on its own. Provides:

- `source_oracle_env` — source `oraenv` for a DB listed in `/etc/oratab`, with `ORACLE_HOME`/`ORACLE_SID` validation
- `check_oracle_instance` — verify the instance has a `pmon_<DB>` process and `v$instance.status = 'OPEN'`
- `validate_dpump_dir` — confirm a Data Pump directory object exists in `all_directories` and the path exists on disk
- `get_schemas` — run a SQL query and return schema names (one per line)
- `check_disk_space` — verify disk usage on a mount point is below a percentage threshold
- `require_commands` — fail fast if required tools (sqlplus, expdp, impdp, ssh, scp, tar) are missing

The `log`, `err`, and `warn` helpers are defined in each top-level script and consumed by these library functions — so any script sourcing `ora-common.sh` must define them first (or source a shim that does).

## Conventions

All scripts follow consistent patterns:

- **Argument parsing** with POSIX `getopts` and `--dry-run`/`--help` long-option preprocessing
- **Exit codes**: 0 (success), 1 (failure), 2 (dry run), 3 (bad arguments)
- **Parfile-based expdp/impdp** — keeps credentials out of the process list (`chmod 600`, deleted after use)
- **Timestamped logging** — every action logged with `[YYYY-MM-DD HH:MM:SS]`
- **Shared library** (`lib/ora-common.sh`) — no duplicated Oracle logic across scripts
- **No hardcoded paths or credentials** — everything passed via flags or environment files

## Security

- Credentials are never hardcoded in scripts or parfiles that persist on disk
- Parfiles are created with `chmod 600` and deleted immediately after use
- Oracle Wallet authentication (`/@DBNAME`) is recommended over plaintext passwords
- SSH key paths are passed via `-i` flag, never stored in scripts
- The following are excluded via `.gitignore`: `*.pem`, `*.key`, `*.dmp`, `*.log`, `*.tar`, `*.par`, `*.env`, `wallet/`, `tnsnames.ora`, `sqlnet.ora`

## Roadmap

- Bats unit tests for argument validation and exit codes
- Oracle 23ai Free container integration tests in GitHub Actions
- Manifest rotation and reporting tools
- Support for pluggable database (PDB) level migrations
- `scp`/`ssh` retry with backoff and checksum verification on cloud transfer

## Related repos

- [linux-automation-toolkit](https://github.com/eayanwale/linux-automation-toolkit) — general-purpose ops scripts (disk monitoring, backup rotation, file transfer, system health)
- [Control-Script_SH](https://github.com/eayanwale/Control-Script_SH) (archived) — the original monolithic DBA utility these scripts were extracted from

## License

MIT