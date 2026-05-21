# oracle-migration-toolkit

Standalone Oracle database migration scripts — Data Pump export, import, local migration, and cloud (AWS) migration with dynamic remote script generation.

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
| `bin/ora-migrate-cloud.sh` | End-to-end on-prem → cloud migration with dynamic remote script generation | Extracted from `CLOUD_MIGRATION()` |
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
chmod +x bin/*.sh

# Dry run — validate without exporting:
./bin/ora-export.sh --dry-run \
  -d APEXDB \
  -D DATA_PUMP_DIR \
  -q "select username from dba_users where username like 'STACK%'"

# Full export:
./bin/ora-export.sh \
  -d APEXDB \
  -D DATA_PUMP_DIR \
  -q "select username from dba_users where username like 'STACK%'" \
  -c "/@APEXDB"

# Import from a tar archive with schema remap:
./bin/ora-import.sh \
  -d FREEPDB1 \
  -D IMPORT_DIR \
  -f /backup/exports/2026-05-20_export_APEXDB.tar.gz \
  -s STACK_USER \
  -t STACK_USER_DEV \
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

Imports schemas from a dump file or tar archive into a target database. Handles tar extraction into the Data Pump directory, supports `REMAP_SCHEMA` for source-to-target schema mapping, and runs post-import verification queries to confirm objects exist in the target schema.

```bash
# Import with schema remap:
./bin/ora-import.sh -d FREEPDB1 -D IMPORT_DIR \
  -f /backup/exports/2026-05-20_export_APEXDB.tar.gz \
  -s STACK_USER,STACK_ADMIN \
  -t STACK_USER_DEV,STACK_ADMIN_DEV

# Import as-is (no remap):
./bin/ora-import.sh -d FREEPDB1 -D IMPORT_DIR \
  -f /data/imports/STACK_USER.dmp

# Dry run:
./bin/ora-import.sh --dry-run -d FREEPDB1 -D IMPORT_DIR \
  -f /backup/exports/2026-05-20_export_APEXDB.tar.gz
```

### ora-migrate-local.sh

Orchestrates a full local migration by calling `ora-export.sh` then `ora-import.sh` on the same server. Passes flags through to both scripts.

```bash
# Migrate schemas from APEXDB to DEVDB:
./bin/ora-migrate-local.sh \
  -s APEXDB -d DEVDB \
  -D DATA_PUMP_DIR \
  -q "select username from dba_users where username like 'STACK%'"

# Dry run:
./bin/ora-migrate-local.sh --dry-run \
  -s APEXDB -d DEVDB \
  -D DATA_PUMP_DIR \
  -q "select username from dba_users where username like 'STACK%'"
```

### ora-migrate-cloud.sh

End-to-end migration from an on-prem Oracle database to a remote (cloud) instance. Exports locally, transfers the tar archive via SCP with retry and checksum verification, dynamically generates a remote import script tailored to the target environment, pushes and executes it over SSH.

```bash
# Migrate to AWS:
./bin/ora-migrate-cloud.sh \
  -s APEXDB -d CLOUDDB \
  -D DATA_PUMP_DIR \
  -H ec2-xx-xx-xx-xx.compute.amazonaws.com \
  -u ec2-user \
  -i ~/.ssh/aws.pem \
  -q "select username from dba_users where username like 'STACK%'"

# Dry run:
./bin/ora-migrate-cloud.sh --dry-run \
  -s APEXDB -d CLOUDDB \
  -D DATA_PUMP_DIR \
  -H ec2-xx-xx-xx-xx.compute.amazonaws.com \
  -u ec2-user \
  -i ~/.ssh/aws.pem \
  -q "select username from dba_users where username like 'STACK%'"
```

### lib/ora-common.sh

Shared library sourced by all scripts. Not executable on its own. Provides:

- `source_oracle_env` — source the correct Oracle environment file with validation
- `check_oracle_instance` — verify the database instance is OPEN via sqlplus
- `validate_dpump_dir` — confirm a Data Pump directory object exists in `dba_directories`
- `get_schemas` — run a SQL query and return schema names
- `check_disk_space` — verify disk usage is below threshold
- `require_commands` — fail fast if required tools are missing
- `log`, `err`, `warn` — timestamped output to stdout/stderr

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

- `ora-migrate-local.sh` and `ora-migrate-cloud.sh` — orchestration scripts (Phase 2)
- Bats unit tests for argument validation and exit codes
- ShellCheck enforcement in CI
- Oracle 23ai Free container integration tests in GitHub Actions
- Manifest rotation and reporting tools
- Support for pluggable database (PDB) level migrations

## Related repos

- [linux-automation-toolkit](https://github.com/eayanwale/linux-automation-toolkit) — general-purpose ops scripts (disk monitoring, backup rotation, file transfer, system health)
- [Control-Script_SH](https://github.com/eayanwale/Control-Script_SH) (archived) — the original monolithic DBA utility these scripts were extracted from

## License

MIT