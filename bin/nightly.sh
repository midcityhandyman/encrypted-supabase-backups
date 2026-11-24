#!/usr/bin/env bash
# The nightly cycle: backup, restore test, prune. Pruning only runs after the
# new backup has been proven restorable, so a bad night never pushes good
# history out of the retention window.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"

load_env
new_backup="$(bash "$HERE/backup.sh")" \
  || die "backup failed; restore test and prune skipped"
bash "$HERE/restore-test.sh" "$new_backup" \
  || die "restore test failed; prune skipped, older backups left alone"
bash "$HERE/prune.sh" || die "prune failed"
log "nightly cycle complete"
