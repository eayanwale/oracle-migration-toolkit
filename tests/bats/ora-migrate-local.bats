#!/usr/bin/env bats

load test_helper

SCRIPT="${BIN_DIR}/ora-migrate-local.sh"

@test "ora-migrate-local: --help exits 0 with usage" {
    run bash "${SCRIPT}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-migrate-local: -h exits 0 with usage" {
    run bash "${SCRIPT}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-migrate-local: --version exits 0 with semver" {
    run bash "${SCRIPT}" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "ora-migrate-local: -v exits 0" {
    run bash "${SCRIPT}" -v
    [ "$status" -eq 0 ]
}

@test "ora-migrate-local: no args exits 3" {
    run bash "${SCRIPT}"
    [ "$status" -eq 3 ]
}

@test "ora-migrate-local: missing -s exits 3" {
    run bash "${SCRIPT}" -d DEVDB -q "select 1 from dual"
    [ "$status" -eq 3 ]
}

@test "ora-migrate-local: missing -d exits 3" {
    run bash "${SCRIPT}" -s APEXDB -q "select 1 from dual"
    [ "$status" -eq 3 ]
}

@test "ora-migrate-local: missing -q exits 3" {
    run bash "${SCRIPT}" -s APEXDB -d DEVDB
    [ "$status" -eq 3 ]
}

@test "ora-migrate-local: unknown flag exits 3" {
    run bash "${SCRIPT}" -s APEXDB -d DEVDB -q "select 1 from dual" -Z BAD
    [ "$status" -eq 3 ]
}
