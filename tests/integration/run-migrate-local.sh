#!/usr/bin/env bash

set -euo pipefail

cd /workspace

bash bin/ora-migrate-local.sh \
    -s FREE -d FREE \
    -q "select 'TEST_USER' from dual" \
    -c "system/testpw@FREEPDB1" \
    -r DEV

result=$(sqlplus -S system/testpw@FREEPDB1 <<'SQL'
set echo off heading off feedback off term off pagesize 0
select count(*) from test_user_dev.employees;
exit;
SQL
)

result=$(echo "${result}" | tr -d '[:space:]')

if [[ "${result}" != "3" ]]; then
    echo "FAIL: TEST_USER_DEV.employees has ${result} rows, expected 3"
    exit 1
fi
echo "PASS: TEST_USER_DEV.employees has ${result} rows, expected 3"
