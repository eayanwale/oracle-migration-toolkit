#!/usr/bin/env bash

set -euo pipefail

readonly EXIT_FAIL=1
readonly EXIT_DRYRUN=2
readonly EXIT_BAD_ARGS=3

help() {
    cat <<EOF
        Usage: $0 -s <src_db> -d <dst_db> -D <dpump_dir> -q <schema_query> [options]

        Orchestrate a local Oracle schema migration on a single host: export from the
        source database, then import into the destination database via Data Pump.
        Delegates to ora-export.sh (Phase 1) and ora-import.sh (Phase 2); the manifest
        produced by the export is consumed by the import automatically.

        Required:
        -s SRC_DB       Source database name (export from)
        -d DST_DB       Destination database name (import into)
        -D DPUMP_DIR    Data Pump directory object name shared by both DBs (e.g., DATA_PUMP_DIR)
        -q QUERY        SQL query returning schema names to export
                        (e.g., "select username from dba_users where username like 'STACK%'")

        Options:
        -c CONNECT      sqlplus/expdp/impdp connection string (default: "/ as sysdba")
                        Recommended: Oracle Wallet (/@DBNAME) to avoid plaintext passwords
        -e ENV_DIR      Directory containing oracle_env_<DBNAME>.sh files
                        (default: /home/oracle/scripts)
        -r SUFFIX       Suffix appended to schema names on import remap (SCHEMA -> SCHEMA_SUFFIX)
        -P PARALLEL     expdp PARALLEL degree for the export phase (default: 1)
        -t THRESHOLD    Disk usage percentage threshold — abort export if exceeded (default: 85)
        --dry-run       Validate inputs and show what would run for both phases — no export/import
        -v, --version   Show version
        -h, --help      Show this help

        Exit codes:
        0   Migration completed successfully (both phases)
        1   Export or import phase failed — migration aborted
        2   Dry run completed — no migration performed
        3   Invalid arguments or missing required flags

        Examples:
        # Migrate STACK% schemas from APEXDB to APEXDB2:
        $0 -s APEXDB -d APEXDB2 -D DATA_PUMP_DIR -q "select username from dba_users where username like 'STACK%'"

        # Migrate with schema remap (STACK01 -> STACK01_TEST) and wallet auth:
        $0 -s APEXDB -d APEXDB2 -D DATA_PUMP_DIR -q "select username from dba_users where username='STACK01'" -r TEST -c "/@APEXDB"

        # Dry run — validate both phases without exporting or importing:
        $0 --dry-run -s APEXDB -d APEXDB2 -D DATA_PUMP_DIR -q "select username from dba_users where username like 'STACK%'"
EOF
}

version() { echo "v1.0.0"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }

SRC_DB=""
DST_DB=""
DPUMP_DIR="DATA_PUMP_DIR"
QUERY=""
CONNECT_STRING="/ as sysdba"
ENV_DIR="/home/oracle/scripts"
SUFFIX=""
THRESHOLD=85
PARALLEL=1
DRY_RUN=false

ARGS=()
for arg in "$@"; do
    case ${arg} in
        --dry-run) DRY_RUN=true ;;
        --version) version; exit 0 ;;
        --help) help; exit 0 ;;
        *) ARGS+=("${arg}") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

while getopts ":vs:d:D:q:c:e:r:P:t:h" opt; do
    case ${opt} in
        s) SRC_DB="${OPTARG}" ;;
        d) DST_DB="${OPTARG}" ;;
        D) DPUMP_DIR="${OPTARG}" ;;
        q) QUERY="${OPTARG}" ;;
        t) THRESHOLD="${OPTARG}" ;;
        c) CONNECT_STRING="${OPTARG}" ;;
        e) ENV_DIR="${OPTARG}";;
        r) SUFFIX="${OPTARG}" ;;
        P) PARALLEL="${OPTARG}" ;;
        h) help; exit 0 ;;
        v) version; exit 0 ;;
        *) err "Invalid option: -${OPTARG}"; help; exit "${EXIT_BAD_ARGS}";;
    esac
done

if [[ -z "${SRC_DB}" || -z "${DST_DB}" || -z "${QUERY}" ]]; then
    help
    exit "${EXIT_BAD_ARGS}"
fi

log "=== $0 $(version) ==="

source "$(dirname "$0")/../lib/ora-common.sh"

require_commands "sqlplus" "impdp" "expdp"

dir_path="$(validate_dpump_dir "${DPUMP_DIR}" "${CONNECT_STRING}")"
mount_point="$(df -P "${dir_path}" | tail -1 | awk '{print $NF}')"
MANIFEST="${mount_point}/tmp/ora-exports/${SRC_DB}_manifest.log"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/ora-export.sh" ]]; then
    err "Export script not found: ${SCRIPT_DIR}/ora-export.sh"
    exit "${EXIT_FAIL}"
fi

if [[ ! -f "${SCRIPT_DIR}/ora-import.sh" ]]; then
    err "Import script not found: ${SCRIPT_DIR}/ora-import.sh"
    exit "${EXIT_FAIL}"
fi

export_cmd=(
    "${SCRIPT_DIR}/ora-export.sh"
    -d "${SRC_DB}"
    -D "${DPUMP_DIR}"
    -q "${QUERY}"
    -c "${CONNECT_STRING}"
    -e "${ENV_DIR}"
    -t "${THRESHOLD}"
    -P "${PARALLEL}"
    -M "${MANIFEST}"
)

import_cmd=(
    "${SCRIPT_DIR}/ora-import.sh"
    -d "${DST_DB}"
    -D "${DPUMP_DIR}"
    -f "${MANIFEST}"
)

if [[ -n "${SUFFIX}" ]]; then
    import_cmd+=(-r "${SUFFIX}")
fi

if [[ "${DRY_RUN}" == true ]]; then
    export_cmd+=(--dry-run)
    import_cmd+=(--dry-run)
fi

log "=== Phase 1: Export from ${SRC_DB} ==="

export_rc=0
"${export_cmd[@]}" || export_rc=$?

if [[ "${export_rc}" -eq "${EXIT_DRYRUN}" ]]; then
    log "=== Phase 2: Import to ${DST_DB} (dry-run plan) ==="
    log "Export was a dry run — manifest ${MANIFEST} not produced."
    log "Phase 2 would invoke: ${import_cmd[*]}"
    exit "${EXIT_DRYRUN}"
elif [[ "${export_rc}" -ne 0 ]]; then
    err "Export from ${SRC_DB} failed (exit ${export_rc}). Aborting migration."
    exit "${EXIT_FAIL}"
fi

log "=== Phase 2: Import to ${DST_DB} ==="

import_rc=0
"${import_cmd[@]}" || import_rc=$?

if [[ "${import_rc}" -ne 0 ]]; then
    err "Import to ${DST_DB} failed (exit ${import_rc}). Aborting migration."
    exit "${EXIT_FAIL}"
fi