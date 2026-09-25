#!/bin/bash
# End-to-end tests for the Zammad backup and restore flow.
#
# Requires: docker, docker compose, and the stack already up.
#
#   ./tests/e2e-backup-restore.sh
#
# The backup here runs once a day and then sleeps until tomorrow, so the tests
# drive it through the one-shot entrypoints the script already provides rather
# than waiting for a schedule.
#
# TWO LESSONS FROM THE REST OF THE FLEET ARE BUILT IN, because both cost CI
# runs to learn elsewhere:
#
#   * The file under test is named by a log line, never picked as "the newest
#     one". The newest file is very often the one being written.
#   * Every assertion about content names a file produced AFTER the state it is
#     asserting about. A run that finishes after a change may have begun before
#     it, and it is correct for that file not to contain the change.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-zammad}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-zammad-traefik-letsencrypt-docker-compose.yml}"
BACKUP_DIR_IN_CONTAINER="${BACKUP_DIR_IN_CONTAINER:-/var/tmp/zammad}"

WORK="$(mktemp -d)"
PASSED=0; FAILED=0
trap 'rm -rf "$WORK"' EXIT

pass() { echo "  PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
dc() { docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }

BACKUP_CONTAINER="$(dc ps -aq backup | head -n 1)"
DB_CONTAINER="$(dc ps -aq postgres | head -n 1)"
[ -n "$BACKUP_CONTAINER" ] || { echo "error: backup container not found — is the stack up?" >&2; exit 1; }
[ -n "$DB_CONTAINER" ] || { echo "error: postgres container not found — is the stack up?" >&2; exit 1; }

DB_NAME="${ZAMMAD_DB_NAME:-zammaddb}"
DB_USER="${ZAMMAD_DB_USER:-zammaddbuser}"

# Runs one backup cycle to completion and prints its output. The script's own
# one-shot mode, so no schedule is involved and nothing races.
run_cycle() { dc run --rm --no-deps -T backup "$1" 2>&1; }

# In the backup volume, not on the host: the directory is a named volume.
in_backup() { docker exec "$BACKUP_CONTAINER" sh -c "$1" 2>/dev/null; }

# The path a log line reports as finished. Complete by definition: the line is
# printed after the rename.
named_in_log() { printf '%s' "$1" | grep -oE "$2: [^ ]+" | tail -1 | sed "s/^$2: //"; }

echo "=== zammad: does a backup come back? ==="
echo

# ---------------------------------------------------------------- a full cycle
echo "=== test_backup_cycle ==="
out="$(run_cycle zammad-backup-once)"
DB_FILE="$(named_in_log "$out" 'Database backup OK')"
DATA_FILE="$(named_in_log "$out" 'Data backup OK')"
if [ -n "$DB_FILE" ]; then
  pass "a database dump was reported finished ($DB_FILE)"
else
  fail "no 'Database backup OK' line"
  printf '%s\n' "$out" | tail -8 | sed 's/^/        /'
  echo; echo "passed: $PASSED   failed: $FAILED"; exit 1
fi
if [ -n "$DATA_FILE" ]; then
  pass "a file archive was reported finished ($DATA_FILE)"
else
  fail "no 'Data backup OK' line"
fi

# ---------------------------------------------------------------- readable
echo "=== test_files_are_whole ==="
if in_backup "gzip -t '$DB_FILE'"; then
  pass "the dump is a complete gzip"
else
  fail "gzip -t rejected the dump"
fi
if [ "$(in_backup "gunzip -c '$DB_FILE' | grep -c 'CREATE TABLE'")" -gt 0 ]; then
  pass "it contains SQL that creates tables, not an empty or error-filled file"
else
  fail "no CREATE TABLE in the dump"
  in_backup "gunzip -c '$DB_FILE' | head -5" | sed 's/^/        /'
fi
if in_backup "tar -tzf '$DATA_FILE' >/dev/null"; then
  pass "the file archive is readable"
else
  fail "the file archive would not list"
fi

# ------------------------------------------- the write is atomic, and it shows
echo "=== test_writes_are_atomic ==="
# THE POINT: the final name must never exist unless the file behind it is
# whole. The .failed rename in the script only runs if the shell lives to
# reach it, and a container stopped mid-dump does not — which used to leave a
# truncated file under exactly the name a restore would pick.
leftovers="$(in_backup "find '$BACKUP_DIR_IN_CONTAINER' -maxdepth 1 -name '*.partial' | grep -c ." )"
if [ "${leftovers:-0}" -eq 0 ]; then
  pass "no .partial files left behind after a completed cycle"
else
  fail "$leftovers .partial file(s) left behind"
fi

# --------------------------------------------------- a failure is detected
echo "=== test_failure_is_detected ==="
# Point the dump at a database that is not there. The script must report the
# failure and must NOT leave a file under the name a restore would choose.
before_count="$(in_backup "find '$BACKUP_DIR_IN_CONTAINER' -maxdepth 1 -name '*_zammad_db.psql.gz' | grep -c ." )"
bad="$(dc run --rm --no-deps -T -e POSTGRESQL_HOST=nosuchhost.invalid backup zammad-backup-db 2>&1)"
if printf '%s' "$bad" | grep -qF 'Database backup FAILED'; then
  pass "a dump against an unreachable database is reported as failed"
else
  fail "a failing dump was not reported"
  printf '%s\n' "$bad" | tail -6 | sed 's/^/        /'
fi
after_count="$(in_backup "find '$BACKUP_DIR_IN_CONTAINER' -maxdepth 1 -name '*_zammad_db.psql.gz' | grep -c ." )"
if [ "${after_count:-0}" -eq "${before_count:-0}" ]; then
  pass "and it left no new file under a name a restore would pick"
else
  fail "a failed dump still produced a file that looks like a backup"
fi
failed_marks="$(in_backup "find '$BACKUP_DIR_IN_CONTAINER' -maxdepth 1 -name '*.failed' | grep -c ." )"
if [ "${failed_marks:-0}" -gt 0 ]; then
  pass "the partial file was kept as .failed for diagnosis"
else
  fail "nothing was kept for diagnosis"
fi

# --------------------------------------------------------- restore roundtrip
echo "=== test_prune_removes_old ==="
# backup.sh deletes *_zammad_*.gz* older than HOLD_DAYS on every cycle. A
# file dated 2020 placed beside the real ones has to be gone after the next
# cycle, and the real ones have to stay: a prune that is only intended
# fills the disk, a prune that takes everything is a backup that is not
# there on the day. Neither was tested here until 2026-09-25.
fake="$BACKUP_DIR_IN_CONTAINER/20200101-000000_zammad_db.psql.gz"
in_backup "echo fake > '$fake' && touch -t 202001010000 '$fake'"
kept_before="$(in_backup "find '$BACKUP_DIR_IN_CONTAINER' -maxdepth 1 -name '*_zammad_*.gz' -mtime -1 | grep -c ." )"
run_cycle zammad-backup-once >/dev/null 2>&1 || true
if in_backup "test -f '$fake'"; then
  fail "a file dated 2020 survived a backup cycle: HOLD_DAYS is not pruning"
else
  pass "a file dated 2020 was pruned on the next cycle"
fi
kept_after="$(in_backup "find '$BACKUP_DIR_IN_CONTAINER' -maxdepth 1 -name '*_zammad_*.gz' -mtime -1 | grep -c ." )"
if [ "${kept_after:-0}" -ge "${kept_before:-1}" ] && [ "${kept_after:-0}" -gt 0 ]; then
  pass "and the recent backups stayed ($kept_after of them)"
else
  fail "the prune took recent backups with it ($kept_before before, ${kept_after:-0} after)"
fi

echo "=== test_restore_roundtrip ==="
# Into a throwaway database of the SAME image, never the live one. A dump only
# loads into a server at least as new as the client that wrote it, so matching
# the image is what makes this a rehearsal rather than a demonstration.
IMAGE="$(docker inspect "$DB_CONTAINER" --format '{{.Config.Image}}')"
TMP="zammad-e2e-restore-$$"
docker rm -f "$TMP" >/dev/null 2>&1
docker run -d --name "$TMP" -e POSTGRES_DB="$DB_NAME" -e POSTGRES_USER="$DB_USER" \
  -e POSTGRES_PASSWORD=e2erestorepassword "$IMAGE" >/dev/null 2>&1
ready=false
for _ in $(seq 1 60); do
  if docker exec "$TMP" psql -tAq -U "$DB_USER" -d "$DB_NAME" -c 'select 1' 2>/dev/null | grep -q '^1$'; then ready=true; break; fi
  sleep 2
done
if [ "$ready" != true ]; then
  fail "the throwaway database never accepted an authenticated query"
else
  in_backup "gunzip -c '$DB_FILE'" > "$WORK/dump.sql"
  errors="$(docker exec -i "$TMP" psql -v ON_ERROR_STOP=0 -U "$DB_USER" -d "$DB_NAME" < "$WORK/dump.sql" 2>&1 | grep -c '^ERROR:')"
  tables="$(docker exec "$TMP" psql -tAq -U "$DB_USER" -d "$DB_NAME" \
      -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');" 2>/dev/null)"
  if [ "${errors:-1}" -eq 0 ]; then
    pass "the dump restored with no SQL errors"
  else
    fail "$errors SQL errors while restoring"
  fi
  # THE LIVE DATABASE IS THE REFERENCE, NOT A NUMBER PICKED HERE. "More than
  # ten tables" passes for a dump that restored a fifth of the schema, and
  # keeps passing when the application grows. Asking the running stack what it
  # has means the comparison stays true as the schema changes — and when it
  # stops being true, this fails instead of going on blessing whatever the
  # dump happened to contain.
  live_tables="$(docker exec "$DB_CONTAINER" psql -tAq -U "$DB_USER" -d "$DB_NAME" \
      -c "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$live_tables" ] || [ "$live_tables" -eq 0 ] 2>/dev/null; then
    fail "could not read the live schema to compare against — this check cannot pass by failing to look"
  elif [ "${tables:-0}" -eq "$live_tables" ]; then
    pass "and produced the same schema the live database has ($tables tables)"
  else
    missing="$(docker exec "$DB_CONTAINER" psql -tAq -U "$DB_USER" -d "$DB_NAME" \
        -c "select table_name from information_schema.tables where table_schema not in ('pg_catalog','information_schema') order by 1;" 2>/dev/null \
      | grep -Fxv -f <(docker exec "$TMP" psql -tAq -U "$DB_USER" -d "$DB_NAME" \
        -c "select table_name from information_schema.tables where table_schema not in ('pg_catalog','information_schema') order by 1;" 2>/dev/null) 2>/dev/null | head -8 | tr '\n' ' ')"
    fail "restored ${tables:-0} tables where the live database has $live_tables${missing:+ — missing: $missing}"
  fi
fi
docker rm -f "$TMP" >/dev/null 2>&1

echo
echo "passed: $PASSED   failed: $FAILED"
[ "$FAILED" -eq 0 ]
