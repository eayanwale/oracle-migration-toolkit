#!/usr/bin/env bats

load test_helper

SCRIPT="${BIN_DIR}/ora-migrate-cloud.sh"

@test "ora-migrate-cloud: --help exits 0 with usage" {
    run bash "${SCRIPT}" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-migrate-cloud: -h alone exits 0 (regression: getopts h: bug)" {
    run bash "${SCRIPT}" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "ora-migrate-cloud: --version exits 0 with semver" {
    run bash "${SCRIPT}" --version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "ora-migrate-cloud: -v exits 0" {
    run bash "${SCRIPT}" -v
    [ "$status" -eq 0 ]
}

@test "ora-migrate-cloud: no args exits 3" {
    run bash "${SCRIPT}"
    [ "$status" -eq 3 ]
}

@test "ora-migrate-cloud: missing -s exits 3" {
    run bash "${SCRIPT}" -d CLOUDDB -H host -u oracle -q "x" -p /oradata/dpdump
    [ "$status" -eq 3 ]
}

@test "ora-migrate-cloud: missing -d exits 3" {
    run bash "${SCRIPT}" -s APEXDB -H host -u oracle -q "x" -p /oradata/dpdump
    [ "$status" -eq 3 ]
}

@test "ora-migrate-cloud: missing -H exits 3" {
    run bash "${SCRIPT}" -s APEXDB -d CLOUDDB -u oracle -q "x" -p /oradata/dpdump
    [ "$status" -eq 3 ]
}

@test "ora-migrate-cloud: missing -u exits 3" {
    run bash "${SCRIPT}" -s APEXDB -d CLOUDDB -H host -q "x" -p /oradata/dpdump
    [ "$status" -eq 3 ]
}

@test "ora-migrate-cloud: missing -q exits 3" {
    run bash "${SCRIPT}" -s APEXDB -d CLOUDDB -H host -u oracle -p /oradata/dpdump
    [ "$status" -eq 3 ]
}

@test "ora-migrate-cloud: missing -p exits 3 mentioning -p (regression: unbound REMOTE_PATH)" {
    run bash "${SCRIPT}" -s APEXDB -d CLOUDDB -H host -u oracle -q "select 1 from dual"
    [ "$status" -eq 3 ]
    [[ "$output" == *"-p"* ]]
}

@test "ora-migrate-cloud: unknown flag exits 3" {
    run bash "${SCRIPT}" -s APEXDB -d CLOUDDB -H host -u oracle -q "x" -p /oradata/dpdump -Z BAD
    [ "$status" -eq 3 ]
}
