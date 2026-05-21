#!/usr/bin/env bash

set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAIL=1
readonly EXIT_DRYRUN=2
readonly EXIT_BAD_ARGS=3

help() {
    cat <<EOF
        Usage: $0 -s <src_db> -d <dst_db> -H <host> -u <remote_user> -q <schema_query> [options]

        Orchestrate an Oracle schema migration from a local source database to a remote
        (cloud) destination host: export from the source DB, scp the dump tarball and
        manifest to the remote host, then generate and execute a remote import script
        that imports each schema via Data Pump.

        Delegates Phase 1 (export) to ora-export.sh; Phases 2-4 (transfer, generate,
        execute) are handled in this script. The manifest produced by the export is
        scp'd alongside the archive for traceability.

        Required:
        -s SRC_DB       Source database name (export from)
        -d DST_DB       Destination database name on the remote host (import into)
        -H HOST         Remote hostname or IP of the destination database server
        -u REMOTE_USER  SSH user on the remote host (e.g., oracle)
        -q QUERY        SQL query returning schema names to export
                        (e.g., "select username from dba_users where username like 'STACK%'")

        Options:
        -D DPUMP_DIR    Data Pump directory object name on the source DB (default: DATA_PUMP_DIR)
        -p REMOTE_PATH  Filesystem path on the remote host where the Data Pump directory
                        lives (tarball and manifest are scp'd here). Required.
        -c SRC_CONNECT  sqlplus/expdp connection string for the source DB (default: "/ as sysdba")
                        Recommended: Oracle Wallet (/@DBNAME) to avoid plaintext passwords
        -C REMOTE_CONNECT
                        impdp connection string used on the remote host (default: "/ as sysdba")
        -e ENV_DIR      Local directory containing oracle_env_<SRC_DB>.sh (default: /home/oracle/scripts)
        -E REMOTE_ENV_DIR
                        Directory on the remote host containing oracle_env_<DST_DB>.sh
                        (default: /home/oracle/scripts)
        -i IDENTITY     SSH private key file used for scp/ssh to the remote host
        -r SUFFIX       Suffix appended to schema names on import remap (SCHEMA -> SCHEMA_SUFFIX)
        -P PARALLEL     expdp PARALLEL degree for the export phase (default: 1)
        -t THRESHOLD    Disk usage percentage threshold — abort export if exceeded (default: 85)
        -T TIMEOUT      SSH/scp ConnectTimeout in seconds (default: 10)
        --dry-run       Validate inputs and show the import plan — no export, scp, or impdp
        -v, --version   Show version
        -h, --help      Show this help

        Exit codes:
        0   Migration completed successfully (all phases)
        1   Export, transfer, or remote import phase failed — migration aborted
        2   Dry run completed — no migration performed
        3   Invalid arguments or missing required flags

        Examples:
        # Migrate STACK% schemas from APEXDB to cloud APEXDB2 at oracle@10.0.0.5:
        $0 -s APEXDB -d APEXDB2 -H 10.0.0.5 -u oracle -q "select username from dba_users where username like 'STACK%'" -p /u01/app/oracle/admin/APEXDB2/dpdump

        # With schema remap (STACK01 -> STACK01_TEST), wallet auth, and an SSH key:
        $0 -s APEXDB -d APEXDB2 -H db-host.example.com -u oracle -q "select username from dba_users where username='STACK01'" -p /oradata/dpdump -r TEST -c "/@APEXDB" -C "/@APEXDB2" -i ~/.ssh/oracle_id_rsa

        # Dry run — validate inputs and preview the import plan without exporting or scp:
        $0 --dry-run -s APEXDB -d APEXDB2 -H 10.0.0.5 -u oracle -q "select username from dba_users where username like 'STACK%'" -p /u01/app/oracle/admin/APEXDB2/dpdump
EOF
}

version() { echo "v1.0.0"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }

check_connectivity() {
    local user="$1"
    local host="$2"

    log "=== Testing SSH connectivity to ${user}@${host} ==="

    local -a options=()
    options+=(-o "ConnectTimeout=${TIMEOUT}" -o BatchMode=yes -o LogLevel=QUIET)
    [[ -n "${IDENTITY}" ]] && options+=(-i "${IDENTITY}")

    if ! ssh -q "${options[@]}" "${user}@${host}" "exit 0"; then
        err "Unable to authenticate to ${host} with user ${user}."
        return 1
    fi

    log "SSH connection confirmed."
    return 0
}

scp_file() {
    local src_path="$1"
    local destination="$2"

    local -a scp_cmd=(scp -r -o "ConnectTimeout=${TIMEOUT}" -o BatchMode=yes)
    [[ -n "${IDENTITY}" ]] && scp_cmd+=( -i "${IDENTITY}" )

    scp_cmd+=( "${src_path}" "${destination}")

    if ! "${scp_cmd[@]}"; then
        err "Failed to transfer ${src_path} to ${destination}."
        return 1
    fi

    log "Successfully transferred ${src_path} to ${destination}."
    return 0
}

TS=$(date +%Y-%m-%d_%H%M%S)

SRC_DB=""
DST_DB=""
HOST=""
REMOTE_USER=""
DPUMP_DIR="DATA_PUMP_DIR"
QUERY=""
IDENTITY=""
SRC_CONNECT="/ as sysdba"
REMOTE_CONNECT="/ as sysdba"
ENV_DIR="/home/oracle/scripts"
REMOTE_ENV_DIR="/home/oracle/scripts"
REMOTE_PATH="DATA_PUMP_DIR"
SUFFIX=""
THRESHOLD=85
PARALLEL=1
TIMEOUT=10
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

while getopts ":vs:d:H:u:D:q:i:c:C:e:E:r:p:t:P:T:" opt; do
    case ${opt} in
        s) SRC_DB="${OPTARG}" ;;
        d) DST_DB="${OPTARG}" ;;
        H) HOST="${OPTARG}" ;;
        u) REMOTE_USER="${OPTARG}" ;;
        D) DPUMP_DIR="${OPTARG}" ;;
        q) QUERY="${OPTARG}" ;;
        i) IDENTITY="${OPTARG}" ;;
        t) THRESHOLD="${OPTARG}" ;;
        c) SRC_CONNECT="${OPTARG}" ;;
        C) REMOTE_CONNECT="${OPTARG}" ;;
        e) ENV_DIR="${OPTARG}";;
        E) REMOTE_ENV_DIR="${OPTARG}";;
        r) SUFFIX="${OPTARG}" ;;
        p) REMOTE_PATH="${OPTARG}" ;;
        P) PARALLEL="${OPTARG}" ;;
        T) TIMEOUT="${OPTARG}" ;;
        h) help; exit 0 ;;
        v) version; exit 0 ;;
        *) err "Invalid option: -${OPTARG}"; help; exit "${EXIT_BAD_ARGS}";;
    esac
done

if [[ -z "${SRC_DB}" || -z "${DST_DB}" || -z "${HOST}" || -z "${REMOTE_USER}" || -z "${QUERY}" ]]; then
    help
    exit "${EXIT_BAD_ARGS}"
fi

if [[ -z "${REMOTE_PATH}" ]]; then
    err "Remote path (-p) is required for cloud migration"
    exit "${EXIT_BAD_ARGS}"
fi

log "=== $0 $(version) ==="

source "$(dirname "$0")/../lib/ora-common.sh"

require_commands "sqlplus" "impdp" "expdp" "scp" "ssh"

dir_path="$(validate_dpump_dir "${DPUMP_DIR}" "${SRC_CONNECT}")"
dpump="${dir_path#/}"
mount_point="/${dpump%%/*}"
MANIFEST="${mount_point}/tmp/ora-exports/${SRC_DB}_manifest.log"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/ora-export.sh" ]]; then
    err "Export script not found: ${SCRIPT_DIR}/ora-export.sh"
    exit "${EXIT_FAIL}"
fi

export_cmd=(
    "${SCRIPT_DIR}/ora-export.sh"
    -d "${SRC_DB}"
    -D "${DPUMP_DIR}"
    -q "${QUERY}"
    -c "${SRC_CONNECT}"
    -e "${ENV_DIR}"
    -t "${THRESHOLD}"
    -P "${PARALLEL}"
)

if [[ "${DRY_RUN}" == true ]]; then
    export_cmd+=(--dry-run)
fi

log "=== Phase 1: Export from ${SRC_DB} ==="

export_rc=0
"${export_cmd[@]}" || export_rc=$?

log "=== Testing SSH connectivity to $REMOTE_USER@$HOST ==="

check_connectivity "$REMOTE_USER" "$HOST" || {
    err "Cannot connect to $HOST as $REMOTE_USER. Aborting migration."
    exit "${EXIT_FAIL}"
}

if [[ "${export_rc}" -eq "${EXIT_DRYRUN}" ]]; then
    log "=== Phase 2: Import to ${DST_DB} (dry-run plan) ==="
    log "Export was a dry run — manifest ${MANIFEST} not produced."

    schemas=$(get_schemas "${QUERY}" "${SRC_CONNECT}")
    if [[ -z "${schemas}" ]]; then
        err "No schemas returned by query. Nothing to migrate."
        exit "${EXIT_FAIL}"
    fi
    TARFILE="${dir_path}/${TS}_export_${SRC_DB}.tar.gz"

    log "[DRY RUN] Schemas to migrate: $(tr '\n' ' ' <<< "${schemas}")"
    log "[DRY RUN] Would scp ${TARFILE} → ${REMOTE_USER}@${HOST}:${REMOTE_PATH}/"
    log "[DRY RUN] Would scp ${MANIFEST} → ${REMOTE_USER}@${HOST}:${REMOTE_PATH}/tmp/ora-exports/"
    log "[DRY RUN] Would generate /tmp/ora_import_${DST_DB}_${TS}.sh on ${HOST}"
    log "[DRY RUN] Per-schema impdp parfile would contain:"
    log "[DRY RUN]     schemas=<schema>"
    log "[DRY RUN]     dumpfile=${TS}_<schema>_export_%U.dmp"
    log "[DRY RUN]     logfile=${TS}_<schema>_import.log"
    log "[DRY RUN]     directory=${DPUMP_DIR}"
    log "[DRY RUN]     table_exists_action=replace"
    [[ -n "${SUFFIX}" ]] && log "[DRY RUN]     remap_schema=<schema>:<schema>_${SUFFIX}"
    log "[DRY RUN] Would run: impdp '${REMOTE_CONNECT}' parfile=<parfile>"
    log "[DRY RUN] No migration performed"
    exit "${EXIT_DRYRUN}"
elif [[ "${export_rc}" -ne 0 ]]; then
    err "Export from ${SRC_DB} failed (exit ${export_rc}). Aborting migration."
    exit "${EXIT_FAIL}"
fi

log "=== Phase 2: Import to ${DST_DB} ==="

IFS='|' read -r _ _ SCHEMAS TARFILE _ _ <<< "$(tail -1 "${MANIFEST}")"
TARFILE="${TARFILE// /}"
[[ "${TARFILE}" != /* ]] && TARFILE="${dir_path}/${TARFILE}"
SCHEMAS=$(tr ',' '\n' <<< "${SCHEMAS// /}")

scp_file "${TARFILE}" "${REMOTE_USER}@${HOST}:${REMOTE_PATH}/" || {
    err "Failed to transfer ${TARFILE} to ${HOST}. Aborting migration."
    exit "${EXIT_FAIL}"
}

scp_file "${MANIFEST}" "${REMOTE_USER}@${HOST}:${REMOTE_PATH}/tmp/ora-exports/" || {
    err "Failed to transfer ${MANIFEST} to ${HOST}. Aborting migration."
    exit "${EXIT_FAIL}"
}

log "=== Phase 3: Generate remote import script ==="

REMOTE_SCRIPT="/tmp/ora_import_${DST_DB}_${TS}.sh"
LOCAL_SCRIPT="$(mktemp)"
chmod 600 "${LOCAL_SCRIPT}"

cat > "${LOCAL_SCRIPT}" <<REMOTE_EOF
#!/usr/bin/env bash
set -euo pipefail

# Auto-generated by ora-migrate-cloud.sh on ${TS}
# Migration: ${SRC_DB} → ${DST_DB} on ${HOST}

source ${REMOTE_ENV_DIR}/oracle_env_${DST_DB}.sh

REMOTE_DPUMP_DIR="${REMOTE_PATH}"
TAR_FILE="${REMOTE_PATH}/$(basename "${TARFILE}")"

DUMP_FILES=\$(tar -tf "\${TAR_FILE}" | grep '\.dmp$' || true)
if [[ -z "\${DUMP_FILES}" ]]; then
    echo "ERROR: No .dmp files found in archive: \${TAR_FILE}"
    exit 1
fi

echo "Extracting archive..."
tar -xzf "\${TAR_FILE}" -C "\${REMOTE_DPUMP_DIR}/"

import_failures=0
for schema in ${SCHEMAS}; do
    echo "Importing \${schema}..."
    
    PARFILE="/tmp/imp_${TS}_\${schema}_${DST_DB}.par"
    
    cat > "\${PARFILE}" <<PAR
schemas=\${schema}
dumpfile=${TS}_\${schema}_export_%U.dmp
logfile=${TS}_\${schema}_import.log
directory=${DPUMP_DIR}
table_exists_action=replace
PAR

    if [[ -n "${SUFFIX}" ]]; then
        echo "remap_schema=\${schema}:\${schema}_${SUFFIX}" >> "\${PARFILE}"
    fi

    if ! impdp '${REMOTE_CONNECT}' parfile="\${PARFILE}"; then
        echo "ERROR: Import failed for \${schema}"
        import_failures=\$((import_failures + 1))
    fi
    
    rm -f "\${PARFILE}"
done

exit \${import_failures}
REMOTE_EOF

log "=== Phase 4: Transfer and execute remote script ==="
scp_file "${LOCAL_SCRIPT}" "${REMOTE_USER}@${HOST}:${REMOTE_SCRIPT}" || {
    err "Failed to transfer remote import script to ${HOST}. Aborting migration."
    rm -f "${LOCAL_SCRIPT}"
    exit "${EXIT_FAIL}"
}

ssh_opts=(-o "ConnectTimeout=${TIMEOUT}" -o BatchMode=yes)
[[ -n "${IDENTITY}" ]] && ssh_opts+=(-i "${IDENTITY}")

ssh "${ssh_opts[@]}" "${REMOTE_USER}@${HOST}" "mkdir -p ${REMOTE_PATH}/tmp/ora-exports/" || true

ssh -T "${ssh_opts[@]}" "${REMOTE_USER}@${HOST}" "bash ${REMOTE_SCRIPT}"
remote_rc=$?

ssh "${ssh_opts[@]}" "${REMOTE_USER}@${HOST}" "rm -f ${REMOTE_SCRIPT}" 2>/dev/null || true
rm -f "${LOCAL_SCRIPT}"

if [[ ${remote_rc} -ne 0 ]]; then
    err "Remote import failed with ${remote_rc} failure(s)"
    exit "${EXIT_FAIL}"
fi

log "Cloud migration complete: ${SRC_DB} → ${DST_DB} on ${HOST}"
exit "${EXIT_SUCCESS}"