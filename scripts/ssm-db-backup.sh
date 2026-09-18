#!/bin/bash
#
# Dump the CraftCV database to S3. Invoked only through the craftcv-db-backup
# SSM document, on a schedule set just before the instance's nightly stop.
#
# The dump is pg_custom format, which pg_restore reads and which is already
# compressed. Two copies are written: a timestamped one for history, and
# latest.dump so a restore does not have to know what the newest key is.
#
# Exit codes: 0 backed up, anything else is a genuine failure.

set -euo pipefail

APP_DIR='{{AppDir}}'
BUCKET='{{BackupBucket}}'
AWS_REGION='{{AwsRegion}}'

log()  { printf '[backup %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[backup FAILED] %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || fail "aws CLI is not installed on this instance"
[ -f "${APP_DIR}/.env" ] || fail "no .env at ${APP_DIR}"
cd "${APP_DIR}"

# Read the credentials the running app uses, rather than assuming them.
DB_NAME=$(grep -E '^DB_NAME=' .env | cut -d= -f2-)
DB_USER=$(grep -E '^DB_USER=' .env | cut -d= -f2-)
[ -n "${DB_NAME}" ] && [ -n "${DB_USER}" ] || fail "DB_NAME or DB_USER missing from .env"

docker compose ps db 2>/dev/null | grep -q "healthy" || fail "the database container is not healthy"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
TMP=$(mktemp /tmp/craftcv-db.XXXXXX)
trap 'rm -f "$TMP"' EXIT

log "dumping ${DB_NAME}"
# -Fc: custom format, compressed, restorable with pg_restore.
# --no-owner: the dump can be restored by whatever role exists on the target.
docker compose exec -T db pg_dump -U "${DB_USER}" -d "${DB_NAME}" -Fc --no-owner > "$TMP" \
  || fail "pg_dump failed"

SIZE=$(stat -c %s "$TMP")
# A pg_custom dump always starts with the magic bytes "PGDMP". Checking it
# here means a truncated or empty file never silently replaces latest.dump.
[ "$SIZE" -gt 1000 ] || fail "dump is only ${SIZE} bytes - refusing to upload"
head -c 5 "$TMP" | grep -q "PGDMP" || fail "dump does not look like a pg_dump archive"
log "dump is ${SIZE} bytes and well-formed"

log "uploading db/${STAMP}.dump"
aws s3 cp "$TMP" "s3://${BUCKET}/db/${STAMP}.dump" --region "$AWS_REGION" --only-show-errors \
  || fail "upload failed"

# Written second and only after the timestamped copy succeeded, so latest
# never points at a failed run.
aws s3 cp "$TMP" "s3://${BUCKET}/db/latest.dump" --region "$AWS_REGION" --only-show-errors \
  || fail "could not update latest.dump"

log "backed up ${SIZE} bytes to s3://${BUCKET}/db/${STAMP}.dump"
