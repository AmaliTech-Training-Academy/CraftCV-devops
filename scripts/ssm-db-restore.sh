#!/bin/bash
#
# Restore the CraftCV database from a dump in S3. Invoked through the
# craftcv-db-restore SSM document.
#
# This is destructive: --clean --if-exists drops the existing objects before
# recreating them. It exists for the case the instance was terminated and
# rebuilt, where the database is empty and there is nothing to lose.
#
# Exit codes: 0 restored, anything else is a genuine failure.

set -euo pipefail

APP_DIR='{{AppDir}}'
BUCKET='{{BackupBucket}}'
KEY='{{Key}}'
AWS_REGION='{{AwsRegion}}'
CONFIRM='{{Confirm}}'

log()  { printf '[restore %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[restore FAILED] %s\n' "$*" >&2; exit 1; }

# A restore over a populated database destroys data. Requiring the word
# makes that a decision rather than a typo.
[ "$CONFIRM" = "RESTORE" ] || fail "Confirm must be the word RESTORE - refusing"

command -v aws >/dev/null || fail "aws CLI is not installed on this instance"
cd "${APP_DIR}" || fail "no ${APP_DIR}"

DB_NAME=$(grep -E '^DB_NAME=' .env | cut -d= -f2-)
DB_USER=$(grep -E '^DB_USER=' .env | cut -d= -f2-)
[ -n "${DB_NAME}" ] && [ -n "${DB_USER}" ] || fail "DB_NAME or DB_USER missing from .env"

TMP=$(mktemp /tmp/craftcv-restore.XXXXXX)
trap 'rm -f "$TMP"' EXIT

log "fetching s3://${BUCKET}/${KEY}"
aws s3 cp "s3://${BUCKET}/${KEY}" "$TMP" --region "$AWS_REGION" --only-show-errors \
  || fail "could not download ${KEY}"

head -c 5 "$TMP" | grep -q "PGDMP" || fail "${KEY} is not a pg_dump archive"

docker compose up -d db >/dev/null 2>&1 || fail "could not start the database"
for i in $(seq 1 30); do
  docker compose ps db 2>/dev/null | grep -q "healthy" && break
  [ "$i" -eq 30 ] && fail "database never became healthy"
  sleep 1
done

log "restoring into ${DB_NAME}"
# pg_restore returns non-zero for benign "does not exist" notices when the
# target is empty, so its output is shown and the verification below is what
# actually decides success.
docker compose exec -T db pg_restore -U "${DB_USER}" -d "${DB_NAME}" \
  --clean --if-exists --no-owner < "$TMP" 2>&1 | tail -15 || true

COUNT=$(docker compose exec -T db psql -U "${DB_USER}" -d "${DB_NAME}" \
  -tAc "select count(*) from django_migrations" 2>/dev/null | tr -d '[:space:]')
[ -n "$COUNT" ] && [ "$COUNT" -gt 0 ] || fail "django_migrations is empty after restore"

log "restored - ${COUNT} migration rows present"
docker compose up -d --no-deps web >/dev/null 2>&1 || true
log "restore complete"
