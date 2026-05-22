#!/usr/bin/env bats

load test_helper

SCRIPT="${BIN_DIR}/ora-import.sh"

@test "ora-import: --help exits 0 with usage" {
    run bash "${SCRIPT}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-import: -h exits 0 with usage" {
    run bash "${SCRIPT}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-import: --version exits 0 with semver" {
    run bash "${SCRIPT}" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "ora-import: -v exits 0" {
    run bash "${SCRIPT}" -v
    [ "$status" -eq 0 ]
}

@test "ora-import: no args exits 3" {
    run bash "${SCRIPT}"
    [ "$status" -eq 3 ]
}

@test "ora-import: missing -d exits 3" {
    run bash "${SCRIPT}" -f /tmp/anything.tar.gz
    [ "$status" -eq 3 ]
}

@test "ora-import: missing -f exits 3" {
    run bash "${SCRIPT}" -d APEXDB
    [ "$status" -eq 3 ]
}

@test "ora-import: non-manifest file without -q exits 3 mentioning -q" {
    run bash "${SCRIPT}" -d APEXDB -f /tmp/data.tar.gz
    [ "$status" -eq 3 ]
    [[ "$output" == *"-q"* ]]
}

@test "ora-import: nonexistent file exits 3" {
    run bash "${SCRIPT}" -d APEXDB -f "/tmp/does-not-exist-$$.tar.gz" -q "select 1 from dual"
    [ "$status" -eq 3 ]
    [[ "$output" == *"not found"* ]]
}

@test "ora-import: unknown flag exits 3" {
    run bash "${SCRIPT}" -d APEXDB -f /tmp/x -Z BAD
    [ "$status" -eq 3 ]
}
