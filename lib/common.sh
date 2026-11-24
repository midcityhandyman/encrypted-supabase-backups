#!/usr/bin/env bash
# Shared helpers for the backup scripts. Sourced, never executed.

SCRIPT_NAME="$(basename "$0" .sh)"

log() {
  if [[ "${LOG_TIMESTAMPS:-1}" == "1" ]]; then
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME" "$*" >&2
  else
    printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

# Optional env file. systemd passes config through EnvironmentFile instead.
load_env() {
  if [[ -n "${BACKUP_ENV_FILE:-}" ]]; then
    [[ -r "$BACKUP_ENV_FILE" ]] || die "cannot read BACKUP_ENV_FILE: $BACKUP_ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$BACKUP_ENV_FILE"
    set +a
  fi
}

require_var() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "required setting $v is not set"
  done
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found on PATH: $c"
  done
}

# Lower case SQL identifier that is safe to interpolate into a statement.
valid_ident() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]]
}

require_uint() {
  local v
  for v in "$@"; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be a non-negative integer, got: ${!v}"
  done
}

# postgres://user@host:5432/dbname?sslmode=require  ->  dbname
db_name_of() {
  local url="${1%%\?*}"
  printf '%s\n' "${url##*/}"
}

# Same connection string, different database name. Keeps any ?query part.
with_db_name() {
  local url="$1" name="$2" query=""
  if [[ "$url" == *\?* ]]; then
    query="?${url#*\?}"
    url="${url%%\?*}"
  fi
  printf '%s/%s%s\n' "${url%/*}" "$name" "$query"
}

# UTC stamp used in file names. BACKUP_NOW overrides it for tests and the demo.
now_stamp() {
  local stamp="${BACKUP_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"
  [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "bad timestamp (want YYYYMMDDTHHMMSSZ): $stamp"
  printf '%s\n' "$stamp"
}

backup_prefix() {
  local prefix="${BACKUP_PREFIX:-db}"
  [[ "$prefix" =~ ^[A-Za-z0-9_-]+$ ]] || die "BACKUP_PREFIX may only hold letters, digits, _ and -"
  printf '%s\n' "$prefix"
}

# Space separated schema list, validated. Supabase keeps its own managed schemas
# (auth, storage and friends); the default dumps only your application schema.
backup_schemas() {
  local schemas="${BACKUP_SCHEMAS:-public}" s
  for s in $schemas; do
    valid_ident "$s" || die "bad schema name in BACKUP_SCHEMAS: $s"
  done
  printf '%s\n' "$schemas"
}

# Backup file names in a directory, oldest first. The stamp sorts lexically.
list_backups() {
  local dir="$1" prefix="$2" f name
  [[ -d "$dir" ]] || return 0
  for f in "$dir/$prefix"-*.dump.age; do
    name="$(basename "$f")"
    if [[ -f "$f" && "$name" =~ ^$prefix-[0-9]{8}T[0-9]{6}Z\.dump\.age$ ]]; then
      printf '%s\n' "$name"
    fi
  done | sort
}

# Exact row count per table, one "schema.table<TAB>count" line each, sorted.
# query_to_xml lets a single statement run count(*) against every table.
row_counts() {
  local url="$1" schemas="$2" s in_list=""
  for s in $schemas; do
    in_list+="${in_list:+,}'$s'"
  done
  local sql="SELECT table_schema || '.' || table_name, (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint FROM information_schema.tables WHERE table_type = 'BASE TABLE' AND table_schema IN ($in_list) ORDER BY 1"
  psql -X -At -F $'\t' -v ON_ERROR_STOP=1 --dbname="$url" -c "$sql"
}
