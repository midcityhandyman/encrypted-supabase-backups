#!/usr/bin/env bash
# pg_dump piped straight into age. Plaintext never touches the disk.
# Writes <prefix>-<stamp>.dump.age plus a .sha256 and a .counts.tsv sidecar,
# and prints the path of the new backup on stdout.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

load_env
require_var SOURCE_DATABASE_URL AGE_RECIPIENT BACKUP_DIR
require_cmd pg_dump psql age sha256sum

PREFIX="$(backup_prefix)"
SCHEMAS="$(backup_schemas)"
MIN_BYTES="${BACKUP_MIN_BYTES:-64}"
require_uint MIN_BYTES

dump_args=(--format=custom --no-owner --no-privileges)
for s in $SCHEMAS; do
  dump_args+=("--schema=$s")
done

umask 077
mkdir -p "$BACKUP_DIR"
STAMP="$(now_stamp)"
NAME="$PREFIX-$STAMP.dump.age"
FINAL="$BACKUP_DIR/$NAME"
PARTIAL="$FINAL.partial"
COUNTS_PARTIAL="$FINAL.counts.partial"

cleanup() {
  rm -f "${PARTIAL:?}" "${COUNTS_PARTIAL:?}"
}
trap cleanup EXIT

[[ ! -e "$FINAL" ]] || die "refusing to overwrite existing backup $NAME"

log "counting rows in schemas: $SCHEMAS"
row_counts "$SOURCE_DATABASE_URL" "$SCHEMAS" >"$COUNTS_PARTIAL" \
  || die "row count query failed; no backup written"

log "dumping and encrypting to $NAME"
# pipefail makes a pg_dump failure fail the whole pipeline, so a half written
# dump can never be renamed into place.
if ! pg_dump "${dump_args[@]}" --dbname="$SOURCE_DATABASE_URL" \
  | age -r "$AGE_RECIPIENT" -o "$PARTIAL"; then
  die "pg_dump or age failed; no backup written"
fi

size=$(($(wc -c <"$PARTIAL")))
((size >= MIN_BYTES)) || die "encrypted dump is only $size bytes (minimum $MIN_BYTES); no backup written"

mv "$PARTIAL" "$FINAL"
(cd "$BACKUP_DIR" && sha256sum "$NAME" >"$NAME.sha256")
mv "$COUNTS_PARTIAL" "$FINAL.counts.tsv"

tables=$(($(wc -l <"$FINAL.counts.tsv")))
rows=$(awk -F'\t' '{ n += $2 } END { print n + 0 }' "$FINAL.counts.tsv")
log "backup written: $NAME ($size bytes, $tables tables, $rows rows)"
printf '%s\n' "$FINAL"
