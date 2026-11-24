#!/usr/bin/env bash
# Retention pruning. Keeps the newest backup of each of the last KEEP_DAILY
# days that have a backup, plus the newest backup of each of the last
# KEEP_WEEKLY ISO weeks that have one. Days and weeks are counted from the
# backups that exist, not from the calendar, so a stalled backup job never
# causes the remaining history to age out.
#
# Usage: prune.sh [--dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

load_env
require_var BACKUP_DIR
PREFIX="$(backup_prefix)"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
DRY_RUN="${PRUNE_DRY_RUN:-0}"
[[ "${1:-}" != "--dry-run" ]] || DRY_RUN=1
require_uint KEEP_DAILY KEEP_WEEKLY
((KEEP_DAILY >= 1)) || die "KEEP_DAILY must be at least 1 so the newest backup always survives"

declare -A seen_day=() seen_week=()
days=0
weeks=0
kept=0
removed=0

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  stamp="${name#"$PREFIX"-}"
  day="${stamp:0:8}"
  week="$(date -u -d "${day:0:4}-${day:4:2}-${day:6:2}" +%G-W%V)" || die "cannot parse date from $name"
  reason=""
  if [[ -z "${seen_day[$day]:-}" ]]; then
    seen_day[$day]=1
    days=$((days + 1))
    ((days > KEEP_DAILY)) || reason="daily"
  fi
  if [[ -z "${seen_week[$week]:-}" ]]; then
    seen_week[$week]=1
    weeks=$((weeks + 1))
    ((weeks > KEEP_WEEKLY)) || reason="${reason:+$reason+}weekly"
  fi
  if [[ -n "$reason" ]]; then
    kept=$((kept + 1))
    log "keep    $name ($reason)"
  elif [[ "$DRY_RUN" == "1" ]]; then
    removed=$((removed + 1))
    log "would remove $name"
  else
    target="${BACKUP_DIR:?}/${name:?}"
    rm -f "$target" "$target.sha256" "$target.counts.tsv"
    removed=$((removed + 1))
    log "removed $name"
  fi
done < <(list_backups "$BACKUP_DIR" "$PREFIX" | sort -r)

if [[ "$DRY_RUN" == "1" ]]; then
  log "dry run: $kept kept, $removed would be removed (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY)"
else
  log "prune done: $kept kept, $removed removed (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY)"
fi
