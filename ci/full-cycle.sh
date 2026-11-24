#!/usr/bin/env bash
# Full cycle against a REAL Postgres server with the REAL age binary.
# Run by the GitHub Actions workflow against a Postgres service container.
# Needs pg_dump, pg_restore, psql, age and age-keygen on PATH, plus a
# superuser connection in CI_ADMIN_URL (password via PGPASSWORD or ~/.pgpass).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_URL="${CI_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
SOURCE_DB="ci_backup_source"

for c in pg_dump pg_restore psql age age-keygen; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing required command: $c" >&2; exit 1; }
done

say() { printf '\n== %s ==\n' "$*"; }
expect_fail() {
  local what="$1"
  shift
  if "$@"; then
    echo "EXPECTED FAILURE DID NOT HAPPEN: $what" >&2
    exit 1
  fi
  echo "ok: failed as expected: $what"
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

say "seed the source database"
psql -X -q -v ON_ERROR_STOP=1 --dbname="$ADMIN_URL" \
  -c "DROP DATABASE IF EXISTS $SOURCE_DB" -c "CREATE DATABASE $SOURCE_DB"
export SOURCE_DATABASE_URL="${ADMIN_URL%/*}/$SOURCE_DB"
psql -X -q -v ON_ERROR_STOP=1 --dbname="$SOURCE_DATABASE_URL" -f "$ROOT/ci/seed.sql"

say "generate an age key pair"
age-keygen -o "$WORK/key.txt"
export AGE_IDENTITY_FILE="$WORK/key.txt"
AGE_RECIPIENT="$(age-keygen -y "$WORK/key.txt")"
export AGE_RECIPIENT
export BACKUP_DIR="$WORK/backups" SCRATCH_ADMIN_URL="$ADMIN_URL"
export KEEP_DAILY=2 KEEP_WEEKLY=0

say "two older backups, then the nightly cycle"
BACKUP_NOW=20261101T021500Z bash "$ROOT/bin/backup.sh" >/dev/null
BACKUP_NOW=20261102T021500Z bash "$ROOT/bin/backup.sh" >/dev/null
nightly_rc=0
BACKUP_NOW=20261103T021500Z bash "$ROOT/bin/nightly.sh" 2>"$WORK/nightly.log" || nightly_rc=$?
cat "$WORK/nightly.log"
[[ "$nightly_rc" == "0" ]] || { echo "nightly cycle failed" >&2; exit 1; }
grep -q "RESTORE TEST PASSED" "$WORK/nightly.log" \
  || { echo "nightly cycle did not report a passed restore test" >&2; exit 1; }
newest="$BACKUP_DIR/db-20261103T021500Z.dump.age"

say "assertions"
[[ -f "$newest" ]] || { echo "newest backup missing" >&2; exit 1; }
[[ "$(head -c 21 "$newest")" == "age-encryption.org/v1" ]] || { echo "backup is not an age file" >&2; exit 1; }
if grep -q -a "Sample Customer" "$newest"; then echo "plaintext found in backup" >&2; exit 1; fi
[[ ! -e "$BACKUP_DIR/db-20261101T021500Z.dump.age" ]] || { echo "prune did not remove the oldest backup" >&2; exit 1; }
[[ -f "$BACKUP_DIR/db-20261102T021500Z.dump.age" ]] || { echo "prune removed too much" >&2; exit 1; }
grep -q "^public.customers	250$" "$newest.counts.tsv"
grep -q "^public.jobs	1200$" "$newest.counts.tsv"
grep -q "^public.invoices	900$" "$newest.counts.tsv"
grep -q "^public.empty_table	0$" "$newest.counts.tsv"
if grep -q "private.audit_log" "$newest.counts.tsv"; then echo "private schema leaked into counts" >&2; exit 1; fi
scratch_left="$(psql -X -At --dbname="$ADMIN_URL" -c "SELECT count(*) FROM pg_database WHERE datname = 'restore_test_scratch'")"
[[ "$scratch_left" == "0" ]] || { echo "scratch database was not dropped" >&2; exit 1; }
echo "ok: age header, no plaintext, retention, row counts, scratch database dropped"

say "negative: recorded counts that do not match the dump"
cp "$newest.counts.tsv" "$WORK/counts.bak"
sed -i 's/^public.jobs\t1200$/public.jobs\t1201/' "$newest.counts.tsv"
expect_fail "row count mismatch" bash "$ROOT/bin/restore-test.sh" "$newest"
cp "$WORK/counts.bak" "$newest.counts.tsv"

say "negative: wrong identity"
age-keygen -o "$WORK/other.txt"
expect_fail "wrong identity" env AGE_IDENTITY_FILE="$WORK/other.txt" bash "$ROOT/bin/restore-test.sh" "$newest"

say "negative: source database unreachable"
expect_fail "backup of a missing database" env SOURCE_DATABASE_URL="${ADMIN_URL%/*}/no_such_database" \
  BACKUP_NOW=20261104T021500Z bash "$ROOT/bin/backup.sh"
[[ ! -e "$BACKUP_DIR/db-20261104T021500Z.dump.age" ]] || { echo "failed backup left a file behind" >&2; exit 1; }

say "positive again after the negatives"
bash "$ROOT/bin/restore-test.sh" "$newest"

psql -X -q --dbname="$ADMIN_URL" -c "DROP DATABASE IF EXISTS $SOURCE_DB"
echo
echo "full cycle against real Postgres and real age: PASSED"
