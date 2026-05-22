#!/usr/bin/env bash

set -euo pipefail

readonly EXIT_SUCCESS=0
readonly EXIT_FAIL=1
readonly EXIT_DRYRUN=2
readonly EXIT_BAD_ARGS=3

help() {
    cat <<EOF
        Usage: $0 -d <dbname> -D <dpump_dir> -f <file> [options]

        Import Oracle schemas via Data Pump from a dump file, archive, or manifest.
        When given a manifest, the schema list and referenced archive are resolved
        automatically; otherwise the schema list is discovered via a SQL query.

        Required:
        -d DBNAME       Target database name (used for env file and connect identifier)
        -D DPUMP_DIR    Data Pump directory object name (e.g., DATA_PUMP_DIR)
        -f FILE         Input file: .dmp, .tar, .tar.gz, .tgz, or *manifest*.log

        Required when NOT using a manifest:
        -q QUERY        SQL query returning schema names to import
                        (e.g., "select username from dba_users where username like 'STACK%'")

        Options:
        -s SRC_CONNECT  Source database connect string (paired with -q)
        -c TGT_CONNECT  Target sqlplus/impdp connection string (default: "/ as sysdba")
                        Recommended: Oracle Wallet (/@DBNAME) to avoid plaintext passwords
        -e ENV_DIR      Directory containing oracle_env_<DBNAME>.sh files
                        (default: /home/oracle/scripts)
        -m MOUNT_POINT  Mount point hosting the Data Pump directory
                        (default: derived from DPUMP_DIR)
        -r SUFFIX       Suffix appended to schema names on remap (SCHEMA -> SCHEMA_SUFFIX)
        --dry-run       Validate inputs, list archive contents, show what would run — no import
        -v, --version   Show version
        -h, --help      Show this help

        Exit codes:
        0   Import completed successfully
        1   Import failed (impdp error, extraction failed, missing files, instance down)
        2   Dry run completed — no import performed
        3   Invalid arguments or missing required flags

        Manifest format (pipe-delimited, last line consumed):
        STARTTIME|SOURCEDB|SCHEMAS|TARFILE|SIZE|ENDTIME

        Examples:
        # Import from a manifest (schemas and tar resolved automatically):
        $0 -d APEXDB -D DATA_PUMP_DIR -f /backup/2026-05-21_export_manifest.log

        # Import from a tar archive with explicit schema query:
        $0 -d APEXDB -D DATA_PUMP_DIR -f /backup/dumps.tar.gz -s "/@SRCDB" -q "select username from dba_users where username like 'STACK%'"

        # Import with schema remap (STACK01 -> STACK01_TEST):
        $0 -d APEXDB -D DATA_PUMP_DIR -f /backup/dumps.tar.gz -s "/@SRCDB" -q "select username from dba_users where username='STACK01'" -r TEST

        # Dry run — validate inputs and show plan, no import:
        $0 --dry-run -d APEXDB -D DATA_PUMP_DIR -f /backup/2026-05-21_export_manifest.log
EOF
}

version() { echo "v1.0.0"; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2; }

TS=$(date +%Y-%m-%d_%H%M%S)

extract_archive() {
    local archive="$1"
    local dest="$2"

    if [[ "${archive}" == *.tar.gz || "${archive}" == *.tgz ]]; then
        tar -xzf "${archive}" -C "${dest}"
    else
        tar -xf "${archive}" -C "${dest}"
    fi
}

schema_remap() {
    local schema_str="$1"
    local remap_attach="$2"

    if [[ -n "${remap_attach}" ]]; then
        echo "${schema_str}:${schema_str}_${remap_attach}"
    else
        return 1
    fi
}

ENV_DIR="/home/oracle/scripts"
DBNAME=""
SRC_CONNECT="/ as sysdba"
FILE=()
DPUMP_DIR="DATA_PUMP_DIR"
QUERY=""
TGT_CONNECT="/ as sysdba"
SUFFIX=""
MOUNT_POINT=""
DRY_RUN=false
SCHEMAS=""

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

while getopts ":vd:s:D:f:q:c:m:e:r:h" opt; do
    case ${opt} in
        d) DBNAME="${OPTARG}" ;;
        s) SRC_CONNECT="${OPTARG}" ;;
        D) DPUMP_DIR="${OPTARG}" ;;
        f) FILE+=("${OPTARG}") ;;
        q) QUERY="${OPTARG}" ;;
        c) TGT_CONNECT="${OPTARG}" ;;
        m) MOUNT_POINT="${OPTARG}" ;;
        e) ENV_DIR="${OPTARG}";;
        r) SUFFIX="${OPTARG}" ;;
        h) help; exit 0 ;;
        v) version; exit 0 ;;
        *) err "Invalid option: -${OPTARG}"; help; exit "${EXIT_BAD_ARGS}";;
    esac
done

ENV_FILE="${ENV_DIR}/oracle_env_${DBNAME}.sh"

if [[ -z "${DBNAME}" ||  ${#FILE[@]} -eq 0 || -z "${DPUMP_DIR}" ]]; then
    err "At least database name (-d), file (-f) and datapump dir name (-D) are required"
    exit "${EXIT_BAD_ARGS}"
fi

for f in "${FILE[@]}"; do
    if [[ "${f}" == *manifest* ]]; then
        if [[ ${#FILE[@]} -gt 1 ]]; then
            warn "Manifest provided (${f}); ignoring other -f arguments"
        fi
        FILE=("${f}")
        break
    fi
done

if [[ "${FILE[0]}" != *manifest* && ${#FILE[@]} -gt 1 ]]; then
    mapfile -t uniq < <(printf '%s\n' "${FILE[@]}" | awk '!seen[$0]++')
    if (( ${#uniq[@]} < ${#FILE[@]} )); then
        warn "Duplicate -f values ignored"
    fi
    FILE=("${uniq[@]}")
fi

if [[ "${FILE[0]}" != *manifest* && -z "${QUERY}" ]]; then
    err "Schema query (-q) required when not using a manifest"
    exit "${EXIT_BAD_ARGS}"
fi

for f in "${FILE[@]}"; do
    if [[ ! -f "${f}" ]]; then
        err "File not found: ${f}"
        exit "${EXIT_BAD_ARGS}"
    fi
done

# shellcheck source=../lib/ora-common.sh
source "$(dirname "$0")/../lib/ora-common.sh"

require_commands "sqlplus" "impdp" "tar"

log "Sourcing Oracle environment for ${DBNAME}"
source "${ENV_FILE}" || {
    log "No environmnt script defined. Sourcing via '${DBNAME}'"
    source_oracle_env "${DBNAME}"
}

check_oracle_instance "${DBNAME}" "${TGT_CONNECT}"

dir_path="$(validate_dpump_dir "${DPUMP_DIR}" "${TGT_CONNECT}")"
dpump="${dir_path#/}"
log "Data Pump directory ${DPUMP_DIR} validated (${dir_path})"

[[ -z ${MOUNT_POINT} ]] && MOUNT_POINT="/${dpump%%/*}"

ORA_EXPORTS="${dir_path}/tmp/ora-exports"
mkdir -p "${ORA_EXPORTS}"

ARCHIVE_TO_EXTRACT=""
DMP_TO_COPY=()

if [[ "${FILE[0]}" == *manifest* ]]; then
    IFS='|' read -r _ SOURCEDB SCHEMAS TARFILE _ _ <<< "$(tail -1 "${FILE[0]}")"
    SOURCEDB="${SOURCEDB// /}"
    TARFILE="${TARFILE// /}"
    [[ "${TARFILE}" != /* ]] && TARFILE="$(dirname "${FILE[0]}")/${TARFILE}"
    SCHEMAS=$(tr ',' '\n' <<< "${SCHEMAS// /}")

    log "Manifest file detected"
    log "Source DB: ${SOURCEDB}"
    log "Schemas:   ${SCHEMAS}"
    log "Using archive: ${TARFILE}"

    if [[ ! -f "${TARFILE}" ]]; then
        err "Referenced tar file not found"
        exit "${EXIT_FAIL}"
    fi

    DUMP_FILES=$(tar -tf "${TARFILE}" | grep '\.dmp$' || true)

    if [[ -z "${DUMP_FILES}" ]]; then
        err "No .dmp files found in archive"
        exit "${EXIT_FAIL}"
    fi

    ARCHIVE_TO_EXTRACT="${TARFILE}"
else
    SCHEMAS=$(get_schemas "${QUERY}" "${SRC_CONNECT}")
    if [[ -z "${SCHEMAS}" ]]; then
        err "No schemas returned by query. Nothing to import."
        exit "${EXIT_FAIL}"
    fi
    log "Schemas found: ${SCHEMAS}"

    if [[ "${FILE[0]}" == *.tar.gz || "${FILE[0]}" == *.tgz || "${FILE[0]}" == *.tar ]]; then
        if [[ ${#FILE[@]} -gt 1 ]]; then
            warn "Archive provided (${FILE[0]}); ignoring other -f arguments"
        fi
        DUMP_FILES=$(tar -tf "${FILE[0]}" | grep '\.dmp$' || true)

        if [[ -z "${DUMP_FILES}" ]]; then
            err "No .dmp files found in archive: ${FILE[0]}"
            exit "${EXIT_FAIL}"
        fi

        ARCHIVE_TO_EXTRACT="${FILE[0]}"
    elif [[ "${FILE[0]}" == *.dmp ]]; then
        DUMP_FILES=""
        for f in "${FILE[@]}"; do
            if [[ "${f}" != *.dmp ]]; then
                err "Mixed file types — all -f must be .dmp when more than one is provided: ${f}"
                exit "${EXIT_BAD_ARGS}"
            fi
            [[ -n "${DUMP_FILES}" ]] && DUMP_FILES+=$'\n'
            DUMP_FILES+="$(basename "${f}")"
        done
        DMP_TO_COPY=("${FILE[@]}")
    else
        err "Unrecognized file type: ${FILE[0]}. Expected .dmp, .tar, .tar.gz, .tgz, or manifest"
        exit "${EXIT_BAD_ARGS}"
    fi
fi

if [[ "${DRY_RUN}" == true ]]; then
    log "[DRY RUN] Would extract to: ${dir_path}"
    log "[DRY RUN] Dump files in archive:"
    echo "${DUMP_FILES}"
    log "[DRY RUN] Schemas to import:"
    while read -r schema; do
        [[ -z "${schema// }" ]] && continue
        target_schema="${schema}"
        [[ -n "${SUFFIX}" ]] && target_schema="${schema}_${SUFFIX}"
        log "[DRY RUN]   ${schema} -> ${target_schema}"
    done <<< "${SCHEMAS}"
    log "[DRY RUN] impdp options:"
    log "[DRY RUN]   directory=${DPUMP_DIR}"
    log "[DRY RUN]   table_exists_action=replace"
    log "[DRY RUN] No import performed"
    exit "${EXIT_DRYRUN}"
fi

if [[ -n "${ARCHIVE_TO_EXTRACT}" ]]; then
    if ! extract_archive "${ARCHIVE_TO_EXTRACT}" "${dir_path}/"; then
        err "Extraction failed for: ${ARCHIVE_TO_EXTRACT}"
        exit "${EXIT_FAIL}"
    fi
elif [[ ${#DMP_TO_COPY[@]} -gt 0 ]]; then
    cp "${DMP_TO_COPY[@]}" "${dir_path}"
fi

while read -r f; do
    basename_f=$(basename "${f}")
    if [[ ! -f "${dir_path}/${basename_f}" ]]; then
        err "Expected dump not found after extraction: ${basename_f}"
        exit "${EXIT_FAIL}"
    fi
done <<< "${DUMP_FILES}"

log "Extracted to ${dir_path}"
log "Found dump files:"
echo "${DUMP_FILES}"

begin_imp_ts="Start-$(date '+%H:%M:%S')"

import_failures=0
while read -r schema; do
    [[ -z "${schema// }" ]] && continue

    log "Importing schema: ${schema}"

    PARFILE="/tmp/imp_${TS}_${schema}_${DBNAME}.par"
    touch "${PARFILE}"
    chmod 600 "${PARFILE}"

    remap_line=$(schema_remap "${schema}" "${SUFFIX}")

    mapfile -t DUMPS <<< "${DUMP_FILES}"
    schema_dumps=""
    for f in "${DUMPS[@]}"; do
        basename_f=$(basename "${f}")
        if [[ "${basename_f}" =~ (^|_)${schema}(_|\.) ]]; then
            if [[ -n "${schema_dumps}" ]]; then
                schema_dumps="${schema_dumps},${basename_f}"
            else
                schema_dumps="${basename_f}"
            fi
        fi
    done

    if [[ -z "${schema_dumps}" ]]; then
        err "No dump files found matching schema: ${schema}"
        import_failures=$((import_failures + 1))
        continue
    fi

    log "Dump files for ${schema}: ${schema_dumps}"

    cat > "${PARFILE}" <<EOF
schemas=${schema}
dumpfile=${schema_dumps}
logfile=${TS}_${schema}_import.log
directory=${DPUMP_DIR}
table_exists_action=replace
EOF

    if [[ -n "${SUFFIX}" ]]; then
        echo "remap_schema=${remap_line}" >> "${PARFILE}"
    fi

    if ! impdp "'${TGT_CONNECT}'" parfile="${PARFILE}"; then
        err "Import failed for schema: ${schema}"
        import_failures=$((import_failures + 1))
    else
        log "Import complete: ${schema} -> ${schema_dumps}"

        if grep -qi "successfully completed" "${dir_path}/${TS}_${schema}_import.log"; then
            log "Import log indicates success for schema: ${schema}"
        elif grep -qi "completed with" "${dir_path}/${TS}_${schema}_import.log"; then
            warn "Import log indicates completion with warnings for schema: ${schema}"
        else
            err "Import log does not indicate success for schema: ${schema}"
            import_failures=$((import_failures + 1))
        fi
    fi

    target_schema="${schema}"
    [[ -n "${SUFFIX}" ]] && target_schema="${schema}_${SUFFIX}"

    obj_count=$(sqlplus -s "${TGT_CONNECT}" <<SQL
    SET HEADING OFF FEEDBACK OFF PAGESIZE 0
    SELECT COUNT(*) FROM dba_objects WHERE owner = UPPER('${target_schema}');
    EXIT;
SQL
    )
    obj_count="${obj_count//[[:space:]]/}"
    log "Post-import: ${target_schema} has ${obj_count} objects"
    if [[ ! "${obj_count}" =~ ^[0-9]+$ ]]; then
        warn "Could not parse object count for ${target_schema} (got: '${obj_count}')"
    elif (( obj_count == 0 )); then
        warn "Zero objects found — import may have failed silently"
    fi

    rm -f "${PARFILE}"

done <<< "${SCHEMAS}"
fin_imp_ts="End-$(date '+%H:%M:%S')"

log "Import started: ${begin_imp_ts}"
log "Import ended:   ${fin_imp_ts}"

if [[ ${import_failures} -gt 0 ]]; then
    err "Import completed with ${import_failures} failure(s). Check logs."
    exit "${EXIT_FAIL}"
else
    log "All imports completed successfully."
    exit "${EXIT_SUCCESS}"
fi
