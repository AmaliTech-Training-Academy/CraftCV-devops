#!/bin/bash
#
# Publish CraftCV-frontend onto the app instance. Runs as root, invoked only
# through the craftcv-deploy-frontend SSM document - never over SSH.
#
# The instance does not build anything. CodeBuild generates the site while
# running the build gate and uploads it; this syncs down the 220KB result.
# That keeps node, node_modules and an npm cache off a box with 7.6GB of
# disk, and means the bytes tested in CI are the bytes served.
#
# nginx still serves these files from the same origin as the API, so no
# server address is baked into the bundle and the two halves need no CORS.
#
# The {{...}} placeholders are substituted by SSM before this reaches bash.
#
# Exit codes: 0 deployed, 75 another deploy held the lock, anything else is a
# genuine failure.

set -euo pipefail

COMMIT_SHA='{{CommitSha}}'
ARTIFACT_BUCKET='{{ArtifactBucket}}'
WEB_ROOT='{{WebRoot}}'
AWS_REGION='{{AwsRegion}}'
LOCK_WAIT='{{LockWaitSeconds}}'

LOCK_FILE=/var/lock/craftcv-deploy-frontend.lock
SOURCE="s3://${ARTIFACT_BUCKET}/builds/${COMMIT_SHA}/"

log() { printf '[frontend %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[frontend FAILED] %s\n' "$*" >&2; exit 1; }

# --- Lock -----------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT" -x 9; then
  log "another frontend deployment held the lock for more than ${LOCK_WAIT}s"
  exit 75
fi
log "lock acquired (pid $$)"

command -v aws >/dev/null || fail "aws CLI is not installed on this instance"

# --- Fetch the built site -------------------------------------------------
# Confirm the artifact exists before disturbing anything that is serving.
log "looking for ${SOURCE}"
aws s3 ls "${SOURCE}index.html" --region "$AWS_REGION" >/dev/null 2>&1 \
  || fail "no index.html under ${SOURCE} - did the build upload it?"

STAGING="${WEB_ROOT}.new"
rm -rf "$STAGING"
mkdir -p "$STAGING"

log "syncing the built site"
aws s3 sync "$SOURCE" "$STAGING" --region "$AWS_REGION" --only-show-errors \
  || fail "s3 sync failed"

[ -f "${STAGING}/index.html" ] || fail "index.html missing after sync"

# --- Publish --------------------------------------------------------------
# Swap the directory into place rather than writing into the live root, so a
# visitor mid-request never sees a half-copied site.
log "publishing to ${WEB_ROOT}"
if [ -d "$WEB_ROOT" ]; then
  rm -rf "${WEB_ROOT}.old"
  mv "$WEB_ROOT" "${WEB_ROOT}.old"
fi
mv "$STAGING" "$WEB_ROOT"
chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null || true

# --- Verify ---------------------------------------------------------------
nginx -t >/dev/null 2>&1 || fail "nginx configuration is invalid"
systemctl reload nginx || fail "could not reload nginx"

ok=0
code=000
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ || echo "000")
  if [ "$code" = "200" ]; then
    log "frontend responded HTTP 200 after $((i * 2))s"
    ok=1
    break
  fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  # Put the previous site back rather than leaving the box serving nothing.
  if [ -d "${WEB_ROOT}.old" ]; then
    log "rolling back to the previous site"
    rm -rf "$WEB_ROOT"
    mv "${WEB_ROOT}.old" "$WEB_ROOT"
    systemctl reload nginx || true
  fi
  fail "frontend did not return 200 within 30s (last code ${code}) - rolled back"
fi

# The API must still answer through the same nginx, or we have published a
# frontend that cannot talk to anything.
api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/api/docs/schema/ || echo "000")
log "api through nginx: HTTP ${api}"
[ "$api" != "000" ] && [ "$api" -lt 500 ] || fail "the API is not reachable through nginx (${api})"

rm -rf "${WEB_ROOT}.old"
df -h / | tail -1 | sed 's/^/[frontend] disk: /'
log "published ${COMMIT_SHA} successfully"
