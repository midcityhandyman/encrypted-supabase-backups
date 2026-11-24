#!/usr/bin/env bash
# Prove a backup restores. Verifies the checksum, decrypts into a scratch
# database, counts rows per table and compares them with the counts recorded
# when the backup was taken. Exit 0 only when every table matches.
#
# Usage: restore-test.sh [path/to/backup.dump.age]   (default: newest backup)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

load_env
require_var SCRATCH_ADMIN_URL AGE_IDENTITY_FILE BACKUP_DIR
require_cmd pg_restore psql age sha256sum

PREFIX="$(backup_prefix)"
SCHEMAS="$(backup_schemas)"
SCRATCH_DB="${SCRATCH_DB_NAME:-restore_test_scratch}"
TOLERANCE="${ROW_COUNT_TOLERANCE:-0}"
require_uint TOLERANCE
valid_ident "$SCRATCH_DB" || die "bad SCRATCH_DB_NAME: $SCRATCH_DB"
[[ -r "$AGE_IDENTITY_FILE" ]] || die "cannot read AGE_IDENTITY_FILE: $AGE_IDENTITY_FILE"

# The scratch database is dropped and recreated, so it must never be a real one.
[[ "$SCRATCH_DB" != "$(db_name_of "$SCRATCH_ADMIN_URL")" ]] \
  || die "SCRATCH_DB_NAME must differ from the database in SCRATCH_ADMIN_URL"
if [[ -n "${SOURCE_DATABASE_URL:-}" ]]; then
  [[ "$SCRATCH_DB" != "$(db_name_of "$SOURCE_DATABASE_URL")" ]] \
    || die "SCRATCH_DB_NAME must differ from the source database name"
fi

if [[ $# -ge 1 ]]; then
  TARGET="$1"
else
  latest="$(list_backups "$BACKUP_DIR" "$PREFIX" | tail -n 1)"
  [[ -n "$latest" ]] || die "no backups found in $BACKUP_DIR"
  TARGET="$BACKUP_DIR/$latest"
fi
NAME="$(basename "$TARGET")"
[[ -f "$TARGET" ]] || die "backup not found: $TARGET"
DIR="$(cd "$(dirname "$TARGET")" && pwd)"
[[ -f "$DIR/$NAME.sha256" ]] || die "checksum sidecar missing for $NAME"
[[ -s "$DIR/$NAME.counts.tsv" ]] \
  || die "row count sidecar missing or empty for $NAME; nothing to compare against"

SCRATCH_URL="$(with_db_name "$SCRATCH_ADMIN_URL" "$SCRATCH_DB")"
WORK="$(mktemp -d)"
RESULT="FAIL"

admin_sql() {
  psql -X -q -v ON_ERROR_STOP=1 --dbname="$SCRATCH_ADMIN_URL" -c "$1"
}

finish() {
  local rc=$?
  if [[ "${KEEP_SCRATCH_DB:-0}" != "1" ]]; then
    admin_sql "DROP DATABASE IF EXISTS \"$SCRATCH_DB\"" >/dev/null 2>&1 \
      || log "WARNING: could not drop scratch database $SCRATCH_DB"
  fi
  rm -rf "${WORK:?}"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$RESULT" \
    >>"$BACKUP_DIR/restore-test.log" 2>/dev/null || true
  exit "$rc"
}
trap finish EXIT

log "testing $NAME"
(cd "$DIR" && sha256sum -c --status "$NAME.sha256") \
  || die "checksum mismatch: $NAME is corrupt or was modified"
log "checksum ok"

admin_sql "DROP DATABASE IF EXISTS \"$SCRATCH_DB\"" || die "could not drop old scratch database"
admin_sql "CREATE DATABASE \"$SCRATCH_DB\" TEMPLATE template0" || die "could not create scratch database"

log "decrypting and restoring into scratch database $SCRATCH_DB"
# --clean --if-exists copes with dumps that carry their own CREATE SCHEMA.
if ! age -d -i "$AGE_IDENTITY_FILE" "$DIR/$NAME" \
  | pg_restore --clean --if-exists --no-owner --no-privileges --exit-on-error \
    --dbname="$SCRATCH_URL"; then
  die "decrypt or restore failed for $NAME"
fi

row_counts "$SCRATCH_URL" "$SCHEMAS" >"$WORK/actual.tsv" \
  || die "row count query failed on scratch database"

compare_rc=0
awk -F'\t' -v tol="$TOLERANCE" '
  FILENAME == ARGV[1] { expected[$1] = $2; next }
  { actual[$1] = $2 }
  END {
    bad = 0
    for (t in expected) {
      if (!(t in actual)) {
        printf "MISSING   %s expected=%s restored=none\n", t, expected[t]; bad++; continue
      }
      d = actual[t] - expected[t]; if (d < 0) d = -d
      if (d > tol) { printf "MISMATCH  %s expected=%s restored=%s\n", t, expected[t], actual[t]; bad++ }
      else printf "ok        %s expected=%s restored=%s\n", t, expected[t], actual[t]
    }
    for (t in actual) if (!(t in expected)) {
      printf "EXTRA     %s expected=none restored=%s\n", t, actual[t]; bad++
    }
    exit (bad > 0)
  }' "$DIR/$NAME.counts.tsv" "$WORK/actual.tsv" >"$WORK/report.txt" || compare_rc=$?

sort -k2 "$WORK/report.txt" | while IFS= read -r line; do log "  $line"; done
tables=$(($(wc -l <"$DIR/$NAME.counts.tsv")))
if ((compare_rc != 0)); then
  die "RESTORE TEST FAILED for $NAME: row counts differ (tolerance $TOLERANCE)"
fi
RESULT="PASS"
log "RESTORE TEST PASSED for $NAME: $tables tables match"
