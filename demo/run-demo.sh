#!/usr/bin/env bash
# Offline demo. Runs the real scripts against the stub Postgres tools (a file
# backed fake database with synthetic rows) so it needs no server and no keys.
# age is the real binary when installed, otherwise the stub.
#
# Usage: bash demo/run-demo.sh            (prints to the terminal)
#        bash demo/run-demo.sh > demo/output.txt 2>&1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
chmod +x bin/*.sh tests/stubs/pg/* tests/stubs/age/* 2>/dev/null || true

export PATH="$ROOT/tests/stubs/pg:$PATH"
if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
  age_mode="real age binary"
else
  export PATH="$ROOT/tests/stubs/age:$PATH"
  age_mode="stub (age not installed; the stub is NOT encryption)"
fi

WORK="demo/.work"
rm -rf "${ROOT:?}/demo/.work"
mkdir -p "$WORK"
export STUB_PG_ROOT="$ROOT/$WORK/pg" BACKUP_DIR="$WORK/backups" LOG_TIMESTAMPS=0
export SOURCE_DATABASE_URL="postgres://backup_reader@db.example.com:5432/app_source?sslmode=require"
export SCRATCH_ADMIN_URL="postgres://restore_tester@localhost:5432/postgres"
export KEEP_DAILY=3 KEEP_WEEKLY=2

step() { printf '\n== %s ==\n' "$*"; }

echo "encrypted-supabase-backups demo"
echo "postgres tools: stub (file backed fake database, synthetic rows)"
echo "age:            $age_mode"

step "1. Seed a fake source database and make an age key pair"
stub-seed app_source
age-keygen -o "$WORK/key.txt" 2>/dev/null
export AGE_IDENTITY_FILE="$WORK/key.txt"
AGE_RECIPIENT="$(age-keygen -y "$WORK/key.txt")"
export AGE_RECIPIENT
echo "source tables: $(cd "$STUB_PG_ROOT/app_source" && echo ./*.tsv)"
echo "recipient (public key) starts with: ${AGE_RECIPIENT:0:8}..."

step "2. Ten earlier nights of backups (2026-11-01 to 2026-11-10), logs hidden"
for d in 01 02 03 04 05 06 07 08 09 10; do
  BACKUP_NOW="202611${d}T021500Z" bash bin/backup.sh >/dev/null 2>&1
done
echo "backups on disk: $(find "$BACKUP_DIR" -name '*.dump.age' | wc -l | tr -d ' ')"

step "3. Night eleven: the full nightly cycle (backup, restore test, prune)"
BACKUP_NOW=20261111T021500Z bash bin/nightly.sh

step "4. What is left on disk"
(cd "$BACKUP_DIR" && ls -1)
echo
echo "row counts recorded with the newest backup:"
cat "$BACKUP_DIR/db-20261111T021500Z.dump.age.counts.tsv"
echo
if grep -q "Sample Customer" "$BACKUP_DIR/db-20261111T021500Z.dump.age"; then
  echo "plaintext check: FOUND customer rows in the backup file (bad)"
else
  echo "plaintext check: no readable customer rows in the backup file"
fi

step "5. Failure drill: a restore that silently loses one row"
set +e
STUB_PG_RESTORE_DROP_ROW=public.jobs bash bin/restore-test.sh
echo "restore-test exit code: $?"

step "6. Failure drill: the wrong decryption key"
age-keygen -o "$WORK/other-key.txt" 2>/dev/null
AGE_IDENTITY_FILE="$WORK/other-key.txt" bash bin/restore-test.sh
echo "restore-test exit code: $?"

step "7. Failure drill: a backup file that was modified after it was written"
printf 'x' >>"$BACKUP_DIR/db-20261110T021500Z.dump.age"
bash bin/restore-test.sh "$BACKUP_DIR/db-20261110T021500Z.dump.age"
echo "restore-test exit code: $?"
set -e

step "8. Restore test history"
cut -f2,3 "$BACKUP_DIR/restore-test.log"

rm -rf "${ROOT:?}/demo/.work"
echo
echo "demo finished; scratch files removed"
