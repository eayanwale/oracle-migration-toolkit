# Design decisions

This document records the architectural choices behind `oracle-migration-toolkit` — what was picked, what was rejected, and why. It is meant for contributors and for future-me, to avoid relitigating decisions every time the code is touched.

## 1. One purpose per script, orchestrated by thin wrappers

The original monolithic `Control-Script_SH` did everything in one file. Here, each capability lives in its own script:

- [bin/ora-export.sh](bin/ora-export.sh) — export only
- [bin/ora-import.sh](bin/ora-import.sh) — import only
- [bin/ora-migrate-local.sh](bin/ora-migrate-local.sh) — calls export then import on one host
- [bin/ora-migrate-cloud](bin/ora-migrate-cloud) — calls export, scp, then a generated remote import

**Why:** each script is independently testable, independently cron-able, and independently auditable. Migrations are the composition; export/import are the primitives.

**How the orchestrators stay thin:** they shell out to the primitives as subprocesses rather than sourcing them. This keeps blast radius small — a bug in `ora-export.sh` cannot leak state (variables, traps, `set -e` flags) into `ora-migrate-local.sh`. The cost is one extra process and re-validation of inputs in each phase, which is cheap.

## 2. The manifest is the contract between export and import

Each export run appends one line to a pipe-delimited manifest:

```
STARTTIME|DBNAME|SCHEMAS|TARFILE|SIZE|ENDTIME
```

`ora-import.sh` accepts a manifest path (`-f <...manifest...log>`) and resolves schemas + tar from the last line. `ora-migrate-local.sh` produces the manifest in Phase 1 and passes it to Phase 2.

**Why pipe-delimited and not JSON:**
- No `jq` dependency on the Oracle host (often a locked-down RHEL box).
- Manifest is human-grep-able and append-only — operators can `tail -1` it from any shell.
- Schema lists are comma-separated within the `SCHEMAS` field, which is a known sharp edge but acceptable because schema names cannot contain commas.

**Why "last line wins":** appending is atomic on Linux for writes under PIPE_BUF, and the most recent run is what an import almost always wants. Multi-run replay is a future feature, not a current one.

## 3. Data Pump via parfile, not CLI flags

Every `expdp`/`impdp` invocation goes through a parfile, written with `chmod 600` and deleted after use.

**Why:**
- Connect strings in `expdp '/@WALLET' parfile=...` keep credentials off the process list (`ps`), unlike `expdp ... PASSWORD=foo`.
- Parfiles are the only way to pass `parallel`, multi-line `remap_schema`, and complex filters without escaping hell.
- A parfile is a reviewable artifact during incident response — `/tmp/exp_2026-05-21_*_APEXDB.par` shows exactly what ran.

**Why `chmod 600` and delete:** even with wallet auth, the parfile contains the schema list and the connect identifier. It's not catastrophic if it leaks, but there is no reason to leave it on disk.

## 4. Connect identifier defaults to `/ as sysdba`, with wallet recommended

Default `-c "/ as sysdba"` lets the scripts run from the `oracle` OS account without any further setup — which is the by-far-common case on the boxes I run these on. Documentation everywhere recommends `/@DBNAME` (Oracle Wallet) for any non-local use.

**Why not require wallet:** wallet setup is a prerequisite that bounces new users. Defaulting to OS auth gets people to a working dry-run on attempt #1; switching to wallet is a documented one-flag change.

## 5. Argument parsing: `getopts` + manual long-option preprocessing

Every script does this dance:

```bash
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

while getopts ":vd:D:q:..." opt; do ...
```

**Why:** POSIX `getopts` does not support long options. `getopt` (GNU) does, but its behavior differs between GNU and BSD versions and it is not always installed. The pre-pass handles only three long flags I care about (`--dry-run`, `--help`, `--version`) and hands the rest to `getopts`, which is portable.

The repeated boilerplate is the cost. Centralising it in `ora-common.sh` was considered and rejected because the variable names being set differ per script and the indirection would obscure rather than clarify.

## 6. Exit code scheme

All scripts use the same four codes:

| Code | Meaning |
|------|---------|
| 0    | Success |
| 1    | Failure during execution (Oracle error, disk full, scp failed, etc.) |
| 2    | Dry run completed — no side effects |
| 3    | Bad arguments — script never started real work |

**Why this matters:** orchestrators branch on `2` to print the dry-run plan for downstream phases without trying to consume artifacts that don't exist (e.g. the manifest). `ora-migrate-local.sh` and `ora-migrate-cloud` both check `export_rc -eq EXIT_DRYRUN` before treating the import phase as real.

Reserving `3` for bad-args distinguishes "user typo" from "operational failure" — useful in cron pipelines that page on failure but ignore configuration drift caught at startup.

## 7. Dry-run is a first-class mode, not a print-statement

`--dry-run` is plumbed all the way down: orchestrators pass `--dry-run` to their children, and the children produce a structured `[DRY RUN]` plan rather than just early-exiting. The cloud orchestrator's dry-run goes further and prints the per-schema impdp parfile contents that *would* be generated on the remote host.

**Why:** the most common failure mode for Data Pump migrations is "the parfile was almost right." Showing the operator the exact parfile body before any side effect is the cheapest possible safety net.

## 8. Validation runs against the live database, not config files

Before any export/import, the scripts:

1. Check the Oracle instance has a `pmon_<DB>` OS process (`pgrep`) — fast.
2. Connect via sqlplus and confirm `v$instance.status = 'OPEN'` — proves credentials work.
3. Look up the Data Pump directory in `all_directories` and verify the OS path exists on disk — catches "directory object points somewhere that doesn't exist" silent failures.

**Why this order:** each step is cheaper to fail at than the next, and each catches a distinct class of error. `pgrep` catches "DB is down"; sqlplus catches "wrong credentials" and "instance restricted"; the directory check catches the most painful Data Pump misconfiguration there is, which is a directory object whose `directory_path` no longer exists on the filesystem (e.g. after a filesystem remount).

## 9. Disk threshold check before export, not during

`check_disk_space` runs once at the top of `ora-export.sh` and aborts if the mount is over threshold (default 85%). There is no mid-export check.

**Why:** Data Pump does not stream incrementally in a way that's easy to monitor mid-flight, and aborting partway through leaves orphan `.dmp` chunks the user has to clean up by hand. A pre-flight check that says "you would probably fill the disk, refusing to start" is more useful than a "we filled the disk halfway through" message.

The threshold defaults to 85% rather than 95% because Data Pump compression ratios are hard to predict and 15% headroom on a multi-hundred-GB volume catches realistic worst cases.

## 10. The cloud orchestrator generates its remote script locally and pushes it

[bin/ora-migrate-cloud](bin/ora-migrate-cloud) writes the per-migration import script to a local `mktemp` file (chmod 600), `scp`'s it to the destination, runs it once, then removes it remotely.

**Why generate it per-run rather than maintain a `remote/` directory of scripts:**
- The remote script embeds the timestamped dump filenames, the destination DB name, the suffix-remap decision, and the destination `REMOTE_CONNECT` string. Most of that is per-run, not per-environment.
- The destination host might not have this repo checked out at all. Self-contained shipping of the script is the lowest-coupling option.
- Anything else (a deployed remote agent, a CI/CD step on the destination side) requires infrastructure the typical "I have ssh and oracle, that's it" deployment cannot assume.

**Trade-off:** the heredoc that builds the remote script uses escaped `\$` and `\${}` extensively, which is awkward to edit. The alternative — a templated file with `sed` substitutions — was rejected because it adds an artefact for shellcheck to ignore and makes the data flow harder to trace.

## 11. SSH/scp uses `BatchMode=yes` and explicit `ConnectTimeout`

```bash
scp -o "ConnectTimeout=${TIMEOUT}" -o BatchMode=yes ...
ssh -o "ConnectTimeout=${TIMEOUT}" -o BatchMode=yes ...
```

**Why `BatchMode=yes`:** in a non-interactive run (cron, CI), a missing host key or auth failure should fail loudly and immediately, not hang waiting for a `(yes/no)?` prompt. `BatchMode=yes` turns every interactive prompt into an immediate error.

**Why explicit `ConnectTimeout`:** default OpenSSH timeouts are kernel-level TCP timeouts, which can mean a 2+ minute hang on a misconfigured destination. Defaulting to 10s, configurable via `-T`, makes startup failures observable.

## 12. The shared library does not define logging — the scripts do

`lib/ora-common.sh` calls `log`, `err`, and `warn` but does not define them. Each top-level script defines its own copies before sourcing the library.

**Why:** this is mild but deliberate. Each script wants slightly different logging behavior in the future (file logging for `ora-export.sh` in cron, structured JSON for cloud orchestrator, etc.) and centralising loggers in the library would either ossify one shape or force every script to override anyway. Defining them per-script keeps the contract obvious: the library expects these symbols to be in scope.

The cost is duplication of three small functions. I'll move them to the library the day they need to do anything non-trivial.

## 13. No bash arrays in the manifest, no Python anywhere

These scripts run on production Oracle hosts whose `python3` may or may not be present and whose bash may be 4.x. The toolkit constrains itself to:

- POSIX sh-ish bash 4+ features (`mapfile`, `[[ ]]`, arrays as locals)
- `awk`, `grep`, `tr`, `tar`, `scp`, `ssh`, `sqlplus`, `expdp`, `impdp`
- No `jq`, no `python`, no `ruby`, no `yq`

**Why:** every dependency added is one more thing that can be missing or wrong-version on a locked-down DB host. The toolkit's value proposition is "drop it on the Oracle box and it runs" — anything that breaks that proposition has to clear a high bar.

## 14. ShellCheck in CI, but with `.shellcheckrc` overrides

ShellCheck runs on every PR via [.github/workflows/CI.yml](.github/workflows/CI.yml). `.shellcheckrc` disables a small number of checks that conflict with deliberate choices in this codebase (e.g. dynamically-built command arrays, sourcing files whose paths are computed at runtime).

**Why not "just fix the warnings":** a few of the warnings flag patterns that are correct in this domain but unusual in general scripts. Suppressing them once at the project root, with a comment, is clearer than embedding `# shellcheck disable=...` at every callsite.

## 15. What's deliberately NOT here yet

Listed so the absence isn't read as oversight:

- **Cross-version Data Pump compatibility checks** — moving 19c → 23ai works at the impdp level; checking it upfront would require parsing `v$version` on both ends and is not yet worth the complexity.
- **PDB-level migrations** — the scripts target schema-level moves. PDB unplug/plug uses a different toolchain.
- **Resumability** — a failed export currently has to be re-run from the top. Data Pump's own `ATTACH` is fragile across script invocations; resumability would mean tracking job names externally.
- **scp checksum verification** — `scp` does not natively verify; doing it would require an `ssh ... sha256sum` round-trip after each transfer. Worth doing, not done yet.
- **Multi-destination fan-out** — one source, one destination. Multi-target migrations are a loop in shell over the script, not a feature inside it.
