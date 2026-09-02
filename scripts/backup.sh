#!/bin/bash

# A failed pg_dump must never leave a small .gz that looks like a backup:
# pipefail makes the dump's exit status the pipeline's, and every cycle
# logs OK or FAILED so monitoring has a line to grep.
set -eo pipefail

: "${ZAMMAD_DIR:=/opt/zammad/storage}"
: "${BACKUP_DIR:=/var/tmp/zammad}"
: "${BACKUP_TIME:=03:00}"
: "${HOLD_DAYS:=10}"
: "${ZAMMAD_RAILSSERVER_HOST:=railsserver}"
: "${ZAMMAD_RAILSSERVER_PORT:=3000}"
: "${POSTGRESQL_DB:=zammaddb}"
: "${POSTGRESQL_HOST:=postgres}"
: "${POSTGRESQL_PORT:=5432}"
: "${POSTGRESQL_USER:=zammaddbuser}"
: "${POSTGRESQL_PASS:?POSTGRESQL_PASS must be provided via the container environment}"


function check_railsserver_available {
  until (echo > "/dev/tcp/$ZAMMAD_RAILSSERVER_HOST/$ZAMMAD_RAILSSERVER_PORT") &> /dev/null; do
    echo "waiting for railsserver to be ready..."
    sleep 60
  done
}

function zammad_backup {
  TIMESTAMP="$(date +'%Y%m%d%H%M%S')"

  echo "${TIMESTAMP} - backing up zammad..."

  # delete old backups
  if [ -d "${BACKUP_DIR}" ] && [ -n "$(ls "${BACKUP_DIR}")" ]; then
    find "${BACKUP_DIR}"/*_zammad_*.gz -type f -mtime +"${HOLD_DAYS}" -delete
  fi

  if [ "${NO_FILE_BACKUP}" != "yes" ]; then
    # tar files; GNU tar exits 1 when a live file changed mid-read, which is
    # still a complete archive - only exit 2 is a real failure
    DATA_FILE="${BACKUP_DIR}/${TIMESTAMP}_zammad_files.tar.gz"
    tar -czf "${DATA_FILE}" "${ZAMMAD_DIR}" && RC=0 || RC=$?
    if [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; then
      echo "[$(date -Iseconds)] Data backup OK: ${DATA_FILE} ($(stat -c %s "${DATA_FILE}") bytes)"
    else
      echo "[$(date -Iseconds)] Data backup FAILED - partial file kept as ${DATA_FILE}.failed for diagnosis" >&2
      mv "${DATA_FILE}" "${DATA_FILE}.failed" 2>/dev/null || true
    fi
  fi
  #db backup
  DB_FILE="${BACKUP_DIR}/${TIMESTAMP}_zammad_db.psql.gz"
  if pg_dump --dbname=postgresql://"${POSTGRESQL_USER}:${POSTGRESQL_PASS}@${POSTGRESQL_HOST}:${POSTGRESQL_PORT}/${POSTGRESQL_DB}" | gzip > "${DB_FILE}"; then
    echo "[$(date -Iseconds)] Database backup OK: ${DB_FILE} ($(stat -c %s "${DB_FILE}") bytes)"
  else
    echo "[$(date -Iseconds)] Database backup FAILED - partial file kept as ${DB_FILE}.failed for diagnosis" >&2
    mv "${DB_FILE}" "${DB_FILE}.failed" 2>/dev/null || true
  fi
  echo "backup finished :)"
}

if [ "$1" = 'zammad-backup' ]; then

  check_railsserver_available

  while true; do
    NOW_TIMESTAMP=$(date +%s)
    TOMORROW_DATE=$(date -d@"$((NOW_TIMESTAMP + 24*60*60))" +%Y-%m-%d)

    zammad_backup

    NEXT_TIMESTAMP=$(date -d "$TOMORROW_DATE $BACKUP_TIME" +%s)
    NOW_TIMESTAMP=$(date +%s)

    sleep $((NEXT_TIMESTAMP - NOW_TIMESTAMP))
  done

elif [ "$1" = 'zammad-backup-once' ]; then
  check_railsserver_available

  zammad_backup

elif [ "$1" = 'zammad-backup-db' ]; then
  NO_FILE_BACKUP="yes"

  zammad_backup

else
  exec "$@"
fi