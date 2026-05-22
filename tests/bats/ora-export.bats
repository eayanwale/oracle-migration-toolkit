#!/usr/bin/env bats

load test_helper

SCRIPT="${BIN_DIR}/ora-export.sh"

@test "ora-export: --help exits 0 with usage" {
    run bash "${SCRIPT}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-export: -h exits 0 with usage" {
    run bash "${SCRIPT}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-export: --version exits 0 with semver" {
    run bash "${SCRIPT}" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "ora-export: -v exits 0" {
    run bash "${SCRIPT}" -v
    [ "$status" -eq 0 ]
}

@test "ora-export: no args exits 3" {
    run bash "${SCRIPT}"
    [ "$status" -eq 3 ]
}

@test "ora-export: missing -d exits 3" {
    run bash "${SCRIPT}" -q "select 1 from dual"
    [ "$status" -eq 3 ]
}

@test "ora-export: missing -q exits 3" {
    run bash "${SCRIPT}" -d APEXDB
    [ "$status" -eq 3 ]
}

@test "ora-export: unknown flag exits 3" {
    run bash "${SCRIPT}" -d APEXDB -q "select 1 from dual" -Z BAD
    [ "$status" -eq 3 ]
}
