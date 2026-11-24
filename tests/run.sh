#!/usr/bin/env bash
# Test suite. Plain bash, no test framework to install.
#
# Postgres is always stubbed here (a real server is exercised by
# ci/full-cycle.sh). age is stubbed only when the real binary is missing.
#
# Usage: tests/run.sh [name-filter]
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
chmod +x "$ROOT"/bin/*.sh "$ROOT"/tests/stubs/pg/* "$ROOT"/tests/stubs/age/* 2>/dev/null || true

export PATH="$ROOT/tests/stubs/pg:$PATH"
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  AGE_MODE="real age binary"
else
  export PATH="$ROOT/tests/stubs/age:$PATH"
  AGE_MODE="STUB (age not installed)"
fi
echo "postgres tools: STUB (file backed fake database)"
echo "age:            $AGE_MODE"
echo

fail() {
  echo "ASSERT FAILED: $*"
  exit 1
}
assert_file() { [[ -f "$1" ]] || fail "expected file $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "did not expect $1"; }
assert_ok() { "$@" || fail "expected success: $*"; }
assert_fails() { if "$@"; then fail "expected failure: $*"; fi; }
assert_grep() { grep -q -- "$1" "$2" || fail "expected '$1' in $2"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }
count_backups() { find "$BACKUP_DIR" -name '*.dump.age' | wc -l | tr -d ' '; }
backup_at() { BACKUP_NOW="$1" bash "$BIN/backup.sh"; }

sandbox() {
  SB="$1"
  export STUB_PG_ROOT="$SB/pg" BACKUP_DIR="$SB/backups" LOG_TIMESTAMPS=0
  export SOURCE_DATABASE_URL="postgres://backup_reader@db.example.com:5432/app_source?sslmode=require"
  export SCRATCH_ADMIN_URL="postgres://restore_tester@localhost:5432/postgres"
  stub-seed app_source
  age-keygen -o "$SB/key.txt" 2>/dev/null
  export AGE_IDENTITY_FILE="$SB/key.txt"
  AGE_RECIPIENT="$(age-keygen -y "$SB/key.txt")"
  export AGE_RECIPIENT
}

make_history() {
  # 20 consecutive nights, 2026-11-01 (a Sunday) through 2026-11-20.
  local d
  for d in $(seq -w 1 20); do backup_at "202611${d}T021500Z" >/dev/null; done
}

test_url_helpers() {
  # shellcheck source=../lib/common.sh
  . "$ROOT/lib/common.sh"
  assert_eq "$(db_name_of 'postgres://u@h:5432/app?sslmode=require')" "app"
  assert_eq "$(db_name_of 'postgres://u@h:5432/app')" "app"
  assert_eq "$(with_db_name 'postgres://u@h:5432/postgres?sslmode=require' scratch)" \
    "postgres://u@h:5432/scratch?sslmode=require"
  assert_eq "$(with_db_name 'postgres://u@h:5432/postgres' scratch)" "postgres://u@h:5432/scratch"
  assert_ok valid_ident restore_test_scratch
  assert_fails valid_ident 'x"; DROP DATABASE y; --'
}

test_backup_writes_encrypted_file_and_sidecars() {
  local out
  out="$(backup_at 20261101T021500Z)"
  assert_eq "$out" "$BACKUP_DIR/db-20261101T021500Z.dump.age"
  assert_file "$out"
  assert_file "$out.sha256"
  assert_no_file "$out.partial"
  assert_grep "public.customers	5" "$out.counts.tsv"
  assert_grep "public.jobs	8" "$out.counts.tsv"
  assert_grep "public.invoices	3" "$out.counts.tsv"
  assert_fails grep -q "private.audit_log" "$out.counts.tsv"
  assert_fails grep -q "Sample Customer" "$out"
  assert_fails grep -q "STUB-PGDUMP" "$out"
  (cd "$BACKUP_DIR" && sha256sum -c --status "$(basename "$out").sha256") \
    || fail "checksum sidecar does not verify"
}

test_backup_failure_leaves_nothing_behind() {
  STUB_PG_DUMP_FAIL=1 assert_fails backup_at 20261101T021500Z
  assert_eq "$(find "$BACKUP_DIR" -type f | wc -l | tr -d ' ')" "0"
}

test_backup_refuses_to_overwrite() {
  backup_at 20261101T021500Z >/dev/null
  assert_fails backup_at 20261101T021500Z
  assert_file "$BACKUP_DIR/db-20261101T021500Z.dump.age"
}

test_backup_rejects_bad_schema_name() {
  BACKUP_SCHEMAS="public; drop" assert_fails backup_at 20261101T021500Z
}

test_backup_requires_settings() {
  AGE_RECIPIENT="" assert_fails backup_at 20261101T021500Z
}

test_restore_test_passes_and_drops_scratch() {
  backup_at 20261101T021500Z >/dev/null
  assert_ok bash "$BIN/restore-test.sh"
  assert_no_file "$STUB_PG_ROOT/restore_test_scratch"
  assert_grep "db-20261101T021500Z.dump.age	PASS" "$BACKUP_DIR/restore-test.log"
}

test_restore_test_picks_newest_backup() {
  backup_at 20261101T021500Z >/dev/null
  backup_at 20261102T021500Z >/dev/null
  bash "$BIN/restore-test.sh" 2>"$SB/err.log" || fail "restore test failed"
  assert_grep "testing db-20261102T021500Z.dump.age" "$SB/err.log"
}

test_restore_test_fails_when_a_row_is_lost() {
  local out
  out="$(backup_at 20261101T021500Z)"
  if STUB_PG_RESTORE_DROP_ROW=public.jobs bash "$BIN/restore-test.sh" "$out" 2>"$SB/err.log"; then
    fail "expected the restore test to fail"
  fi
  assert_grep "MISMATCH  public.jobs expected=8 restored=7" "$SB/err.log"
  assert_grep "ok        public.customers expected=5 restored=5" "$SB/err.log"
  assert_grep "FAIL" "$BACKUP_DIR/restore-test.log"
  assert_no_file "$STUB_PG_ROOT/restore_test_scratch"
}

test_restore_test_tolerance_allows_small_drift() {
  local out
  out="$(backup_at 20261101T021500Z)"
  STUB_PG_RESTORE_DROP_ROW=public.jobs ROW_COUNT_TOLERANCE=1 assert_ok bash "$BIN/restore-test.sh" "$out"
}

test_restore_test_fails_on_missing_table() {
  local out
  out="$(backup_at 20261101T021500Z)"
  printf 'public.payments\t4\n' >>"$out.counts.tsv"
  if bash "$BIN/restore-test.sh" "$out" 2>"$SB/err.log"; then fail "expected failure"; fi
  assert_grep "MISSING   public.payments" "$SB/err.log"
}

test_restore_test_fails_on_corrupt_ciphertext() {
  local out
  out="$(backup_at 20261101T021500Z)"
  printf 'garbage' >>"$out"
  if bash "$BIN/restore-test.sh" "$out" 2>"$SB/err.log"; then fail "expected failure"; fi
  assert_grep "checksum mismatch" "$SB/err.log"
}

test_restore_test_fails_with_wrong_identity() {
  local out
  out="$(backup_at 20261101T021500Z)"
  age-keygen -o "$SB/other.txt" 2>/dev/null
  AGE_IDENTITY_FILE="$SB/other.txt" assert_fails bash "$BIN/restore-test.sh" "$out"
  assert_no_file "$STUB_PG_ROOT/restore_test_scratch"
}

test_restore_test_fails_without_counts_sidecar() {
  local out
  out="$(backup_at 20261101T021500Z)"
  : >"$out.counts.tsv"
  assert_fails bash "$BIN/restore-test.sh" "$out"
}

test_restore_test_refuses_to_use_a_real_database_as_scratch() {
  local out
  out="$(backup_at 20261101T021500Z)"
  SCRATCH_DB_NAME=app_source assert_fails bash "$BIN/restore-test.sh" "$out"
  SCRATCH_DB_NAME=postgres assert_fails bash "$BIN/restore-test.sh" "$out"
  assert_file "$STUB_PG_ROOT/app_source/public.customers.tsv"
}

test_prune_keeps_daily_and_weekly() {
  make_history
  KEEP_DAILY=3 KEEP_WEEKLY=3 assert_ok bash "$BIN/prune.sh"
  # Daily: 18, 19, 20. Weekly: newest of ISO weeks 47 (20), 46 (15), 45 (08).
  assert_eq "$(cd "$BACKUP_DIR" && echo ./*.dump.age)" \
    "./db-20261108T021500Z.dump.age ./db-20261115T021500Z.dump.age ./db-20261118T021500Z.dump.age ./db-20261119T021500Z.dump.age ./db-20261120T021500Z.dump.age"
  assert_eq "$(find "$BACKUP_DIR" -name '*.sha256' | wc -l | tr -d ' ')" "5"
  assert_eq "$(find "$BACKUP_DIR" -name '*.counts.tsv' | wc -l | tr -d ' ')" "5"
}

test_prune_dry_run_removes_nothing() {
  make_history
  KEEP_DAILY=2 KEEP_WEEKLY=0 assert_ok bash "$BIN/prune.sh" --dry-run
  assert_eq "$(count_backups)" "20"
}

test_prune_counts_days_with_backups_not_calendar_days() {
  backup_at 20250301T021500Z >/dev/null
  backup_at 20250302T021500Z >/dev/null
  KEEP_DAILY=7 KEEP_WEEKLY=0 assert_ok bash "$BIN/prune.sh"
  assert_eq "$(count_backups)" "2"
}

test_prune_keeps_only_newest_of_a_day() {
  backup_at 20261101T021500Z >/dev/null
  backup_at 20261101T230000Z >/dev/null
  KEEP_DAILY=7 KEEP_WEEKLY=0 assert_ok bash "$BIN/prune.sh"
  assert_file "$BACKUP_DIR/db-20261101T230000Z.dump.age"
  assert_no_file "$BACKUP_DIR/db-20261101T021500Z.dump.age"
}

test_prune_rejects_keep_daily_zero() {
  backup_at 20261101T021500Z >/dev/null
  KEEP_DAILY=0 assert_fails bash "$BIN/prune.sh"
  assert_eq "$(count_backups)" "1"
}

test_prune_ignores_unrelated_files() {
  backup_at 20261101T021500Z >/dev/null
  backup_at 20261102T021500Z >/dev/null
  touch "$BACKUP_DIR/notes.txt" "$BACKUP_DIR/db-manual.dump.age"
  KEEP_DAILY=1 KEEP_WEEKLY=0 assert_ok bash "$BIN/prune.sh"
  assert_file "$BACKUP_DIR/notes.txt"
  assert_file "$BACKUP_DIR/db-manual.dump.age"
  assert_no_file "$BACKUP_DIR/db-20261101T021500Z.dump.age"
  assert_file "$BACKUP_DIR/db-20261102T021500Z.dump.age"
}

test_nightly_full_cycle() {
  make_history
  BACKUP_NOW=20261121T021500Z KEEP_DAILY=2 KEEP_WEEKLY=0 assert_ok bash "$BIN/nightly.sh"
  assert_eq "$(count_backups)" "2"
  assert_file "$BACKUP_DIR/db-20261121T021500Z.dump.age"
  assert_grep "db-20261121T021500Z.dump.age	PASS" "$BACKUP_DIR/restore-test.log"
}

test_nightly_skips_prune_when_restore_test_fails() {
  make_history
  BACKUP_NOW=20261121T021500Z KEEP_DAILY=2 KEEP_WEEKLY=0 STUB_PG_RESTORE_DROP_ROW=public.invoices \
    assert_fails bash "$BIN/nightly.sh"
  assert_eq "$(count_backups)" "21"
}

test_env_file_is_loaded() {
  {
    echo "SOURCE_DATABASE_URL=$SOURCE_DATABASE_URL"
    echo "AGE_RECIPIENT=$AGE_RECIPIENT"
    echo "BACKUP_DIR=$SB/from-env-file"
    echo "BACKUP_PREFIX=nightly"
  } >"$SB/backup.env"
  (
    unset SOURCE_DATABASE_URL AGE_RECIPIENT BACKUP_DIR
    BACKUP_ENV_FILE="$SB/backup.env" BACKUP_NOW=20261101T021500Z bash "$BIN/backup.sh" >/dev/null
  ) || fail "backup with env file failed"
  assert_file "$SB/from-env-file/nightly-20261101T021500Z.dump.age"
}

passed=0
failed=0
only="${1:-}"
for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
  [[ -z "$only" || "$t" == *"$only"* ]] || continue
  sb="$(mktemp -d)"
  (
    set -eu
    sandbox "$sb"
    "$t"
  ) >"$sb/test-output.log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "ok    $t"
    passed=$((passed + 1))
  else
    echo "FAIL  $t"
    sed 's/^/        /' "$sb/test-output.log"
    failed=$((failed + 1))
  fi
  rm -rf "${sb:?}"
done
echo
echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 && "$passed" -gt 0 ]]
