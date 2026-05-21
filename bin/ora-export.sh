#!/usr/bin/env bash

set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAIL=1
readonly EXIT_DRYRUN=2
readonly EXIT_BAD_ARGS=3

help() {
    cat <<EOF
        Usage: $0 -d <dbname> -D <dpump_dir> -q <schema_query> -o <output_dir> [options]

        Export Oracle schemas via Data Pump, tar the dump files, and log to a manifest.

        Required:
        -d DBNAME       Database name (used for env file, connect identifier, and file naming)
        -D DPUMP_DIR    Data Pump directory object name (e.g., EXPORT_DIR)
        -q QUERY        SQL query that returns schema names to export
                        (e.g., "select username from dba_users where username like 'STACK%'")

        Options:
        -c CONNECT      sqlplus/expdp connection string (default: "/ as sysdba")
                        Recommended: use Oracle Wallet (/@DBNAME) to avoid plaintext passwords
        -e ENV_DIR      Directory containing oracle_env_<DBNAME>.sh files
                        (default: /home/oracle/scripts)
        -t THRESHOLD    Disk usage percentage threshold — abort if exceeded (default: 85)
        -m MOUNT_POINT  Mount point to check disk space on (default: derived from DPUMP_DIR)
        -M MANIFEST     Path to manifest log file (default: <OUTPUT_DIR>/export_manifest.log)
        -P PARALLEL     expdp PARALLEL degree (default: 2)
        --dry-run       Validate inputs, check instance, show what would run — no export
        -v              Show version
        -h              Show this help

        Exit codes:
        0   Export completed successfully
        1   Export failed (disk full, expdp error, invalid directory, instance down)
        2   Dry run completed — no export performed
        3   Invalid arguments or missing required flags

        Manifest format (pipe-delimited, appended after each successful export):
        TIMESTAMP | DBNAME | SCHEMAS | TARFILE | SIZE

        Examples:
        # Export schemas matching STACK% from APEXDB:
        $0 -d APEXDB -D EXPORT_DIR -q "select username from dba_users where username like 'STACK%'" -o /backup/exports

        # With wallet auth and custom threshold:
        $0 -d FREEPDB1 -D DPUMP_DIR -q "select username from dba_users where account_status='OPEN'" -o /backup -c "/@FREEPDB1" -t 90

        # Dry run — validate everything without exporting:
        $0 --dry-run -d APEXDB -D EXPORT_DIR -q "select username from dba_users where username like 'STACK%'" -o /backup/exports

        # Cron job — nightly export with 14-day manifest history:
        0 1 * * * /opt/oracle/scripts/ora-export.sh -d APEXDB -D EXPORT_DIR -q "select username from dba_users where username like 'STACK%'" -o /backup/exports >> /var/log/ora-export.log 2>&1
EOF
}

version() { echo "v1.0.0"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }

TS=$(date +%Y-%m-%d_%H%M%S)

ENV_DIR="/home/oracle/scripts/"
DBNAME=""
DPUMP_DIR="DATA_PUMP_DIR"
QUERY=""
MANIFEST=""
THRESHOLD=85
CONNECT_STRING="/ as sysdba"
MOUNT_POINT=""
PARALLEL=1
DRY_RUN=false

ARGS=()
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --version) version; exit 0 ;;
        --help) help; exit 0 ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

while getopts ":vd:D:q:t:c:m:M:e:P:h" opt; do
    case $opt in
        d) DBNAME="$OPTARG" ;;
        D) DPUMP_DIR="$OPTARG" ;;
        q) QUERY="$OPTARG" ;;
        t) THRESHOLD="$OPTARG" ;;
        c) CONNECT_STRING="$OPTARG" ;;
        m) MOUNT_POINT="$OPTARG" ;;
        M) MANIFEST="$OPTARG" ;;
        e) ENV_DIR="$OPTARG";; 
        P) PARALLEL="$OPTARG" ;;
        h) help; exit 0 ;;
        v) version; exit 0 ;;
        ?) err "Invalid option"; help; exit 1;;
    esac
done

ENV_FILE="${ENV_DIR}/oracle_env_${DBNAME}.sh"

if [[ -z "$DBNAME" || -z "$DPUMP_DIR" || -z "$QUERY" ]]; then
    help
    exit $EXIT_BAD_ARGS
fi

log "=== $0 $(version) ==="
log "Database:      ${DBNAME}"
log "Directory:     ${DPUMP_DIR}"
log "Threshold:     ${THRESHOLD}"
log "Dry run:       ${DRY_RUN}"
echo

source "$(dirname "$0")/../lib/ora-common.sh"

require_commands "sqlplus" "expdp"

log "Sourcing Oracle environment for ${DBNAME}"
source "$ENV_FILE" || {
    log "No environmnt script defined. Sourcing via '${DBNAME}'"
    source_oracle_env "$DBNAME"
}

check_oracle_instance "$DBNAME" "$CONNECT_STRING"

if [[ -z "$MOUNT_POINT" ]]; then
    dir_path="$(validate_dpump_dir "$DPUMP_DIR" "$CONNECT_STRING")"
    dpump="${dir_path#/}"
    MOUNT_POINT="/${dpump%%/*}"
fi
log "Data Pump directory ${DPUMP_DIR} validated (${dir_path})"

check_disk_space "$MOUNT_POINT" "$THRESHOLD"

schemas=$(get_schemas "$QUERY" "$CONNECT_STRING")
if [[ -z "$schemas" ]]; then
    err "No schemas returned by query. Nothing to export"
    exit $EXIT_FAIL
fi
log "Schemas found: ${schemas}"

if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Would execute:"
    log "[DRY RUN] expdp parfile=./${TS}_[${schemas}]_${DBNAME}.par"
    log "[DRY RUN]      SCHEMAS=${schemas}"
    log "[DRY RUN]      DIRECTORY=${DPUMP_DIR}"
    log "[DRY RUN]      DUMPFILE=${DBNAME}_${TS}_%U.dmp"
    log "[DRY RUN]      LOGFILE=${DBNAME}_${TS}_export.log"
    log "[DRY RUN]      PARALLEL=${PARALLEL}"
    echo
    log "[DRY RUN] Create archive: ${TS}_export_${DBNAME}.tar.gz"
    log "[DRY RUN] Write to manifest file: ${MANIFEST}"
    log "[DRY RUN] No export performed"
    exit $EXIT_DRYRUN
fi

export_failures=0
while read -r schema; do
    [[ -z "$schema" ]] && continue

    log "Exporting schema: ${schema}"

    PARFILE="./${TS}_${schema}_${DBNAME}.par"
    mkdir -p "$(dirname "${PARFILE}")"
    touch "${PARFILE}"
    chmod 600 "${PARFILE}"

    cat > "${PARFILE}" <<EOF
schemas=${schema}
dumpfile=${TS}_${schema}_%U.dmp
logfile=${TS}_${schema}_export.log
directory=${DPUMP_DIR}
parallel=${PARALLEL}
EOF

    if ! expdp "'${CONNECT_STRING}'" parfile=${PARFILE}; then
        err "Export failed for schema: ${schema}"
        export_failures=$((export_failures + 1))
    else
        log "Export complete: ${schema} -> ${TS}_${schema}_%U.dmp"

        if ( grep -q "Successfully completed" "${dir_path}/${TS}_${schema}_export.log" ); then
            log "Export log indicates success for schema: ${schema}"
        elif ( grep -q "completed with" "${dir_path}/${TS}_${schema}_export.log" ); then
            warn "Export log indicates completion with warnings for schema: ${schema}"
        else
            err "Export log does not indicate success for schema: ${schema}"
            export_failures=$((export_failures + 1))
        fi
    fi

    rm -f "${PARFILE}"

done <<< "$schemas"

log "Archiving export logs for schemas: ${schemas}"
TAR_FILE="${dir_path}/${TS}_export_${DBNAME}.tar.gz"
cd "${dir_path}" || exit $EXIT_FAIL
if tar -czf "$TAR_FILE" "${TS}"*.dmp "${TS}"*.log; then
    rm -f "${dir_path}"/"${TS}"*.dmp "${dir_path}"/"${TS}"*.log
else
    err "Failed to archive export logs."
    exit $EXIT_FAIL
fi
cd - >/dev/null

log "Archive created: ${TAR_FILE}"
tar -tvf "$TAR_FILE"
tar_size=$(stat -c%s "$TAR_FILE")

if [[ -z $MANIFEST ]]; then
    MANIFEST="${MOUNT_POINT}/tmp/ora-exports/${DBNAME}_manifest.log"
fi
mkdir -p "$(dirname "${MANIFEST}")"
for sch in $schemas; do
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${DBNAME} | ${sch} | ${TAR_FILE} | ${tar_size}" >> "${MANIFEST}"
done
log "Export manifest updated: ${MANIFEST}"

if [[ $export_failures -gt 0 ]]; then
    err "Export completed with ${export_failures} failures. Check logs for details."
    exit $EXIT_FAIL
else
    log "All exports completed successfully."
    exit $EXIT_SUCCESS
fi
