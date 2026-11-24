#!/usr/bin/env bash
# Shared by the Postgres stubs. A "database" is a directory under STUB_PG_ROOT
# and a table is a file named schema.table.tsv with one row per line.
: "${STUB_PG_ROOT:?STUB_PG_ROOT must point at the fake database root}"

stub_db_name() {
  local url="${1%%\?*}"
  printf '%s\n' "${url##*/}"
}

stub_require_db() {
  local name dir
  name="$(stub_db_name "$1")"
  dir="$STUB_PG_ROOT/$name"
  if [[ -z "$name" || ! -d "$dir" ]]; then
    echo "$2: error: FATAL: database \"$name\" does not exist (stub)" >&2
    exit 2
  fi
  printf '%s\n' "$dir"
}
