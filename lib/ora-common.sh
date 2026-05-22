#!/usr/bin/env bash

require_commands() {
    local cmd
    local missing=0

    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "Required command not found: ${cmd}"
            missing=1
        fi
    done

    return "${missing}"
}

source_oracle_env() {
    local db_name="$1"

    if [[ ! -f /etc/oratab ]]; then
        echo "/etc/oratab not found"
        return 1
    fi

    if ! grep -q "^${db_name}:" /etc/oratab; then
        echo "Database '${db_name}' not found in /etc/oratab"
        return 1
    fi

    export ORACLE_SID="${db_name}"
    . oraenv <<< "${db_name}"

    if [[ -z "${ORACLE_HOME:-}" ]]; then
        echo "ORACLE_HOME not set after sourcing oraenv for '${db_name}'"
        return 1
    fi

    echo "ORACLE_HOME=${ORACLE_HOME}"
    echo "ORACLE_SID=${ORACLE_SID}"
    return 0
}

check_oracle_instance() {
    local db_name="$1"
    local db_connect="${2:-/ as sysdba}"

    if ! pgrep -fi "pmon_${db_name}" >/dev/null 2>&1; then
        echo "No pmon process found for ${db_name} via pgrep - continuing to SQL check (cmdline can be empty depending on how Oracle was started)" >&2
    fi

    local output
    output=$(sqlplus -S "${db_connect}" <<EOF
set echo off feedback off term off pagesize 0
select status from v\$instance;
exit
EOF
    )

    local status
    status=$(echo "${output}" | tr -s ' ')

    if echo "${output}" | grep -q "OPEN"; then
        echo "Instance status: OPEN"
        return 0
    else
        echo "The database ${db_name} is not open - status: ${status}"
        return 1
    fi
}

validate_dpump_dir() {
    local dpump_dir="$1"
    local db_connect="${2:-/ as sysdba}"

    local dir_path
    dir_path=$(sqlplus -S "${db_connect}" <<EOF | tr -d ' \n\r'
set echo off heading off feedback off term off pagesize 0
select directory_path from all_directories where directory_name = UPPER('${dpump_dir}');
exit
EOF
    )

    if [[ -z "${dir_path}" ]]; then
        echo "Directory ${dpump_dir} does not exist"
        return 1
    elif [[ ! -d ${dir_path} ]]; then
        echo "Directory ${dpump_dir} at ${dir_path} does not exist on disk"
        return 1
    else
        echo "${dir_path}"
        return 0
    fi
}

get_schemas() {
    local query="$1"
    local db_connect="${2:-/ as sysdba}"

    local schemalist
    schemalist=$(sqlplus -S "${db_connect}" <<EOF
set echo off heading off feedback off term off pagesize 0
${query};
exit
EOF
    )
    local schema_ex=$?
    if [[ ${schema_ex} -ne 0 || -z "${schemalist}" ]]; then
        echo "Schema query failed (exit code: ${schema_ex})"
        return 1
    fi
    echo "${schemalist}"
}

check_disk_space() {
    local mount="$1"
    local threshold="$2"

    local disk_check
    disk_check=$(df -P | awk -v mp="${mount}" '$NF == mp {gsub(/%/, "", $5); print $5}')

    if [[ -z "${disk_check}" ]]; then
        echo "Mount point '${mount}' not found in df output"
        return 1
    fi

    if (( disk_check > threshold )); then
        echo "${mount} at ${disk_check}% - exceeds ${threshold}% threshold"
        return 1
    else
        echo "${mount} at ${disk_check}% - under ${threshold}% threshold"
        return 0
    fi
}
