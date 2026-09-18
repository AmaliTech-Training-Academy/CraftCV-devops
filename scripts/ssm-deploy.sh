#!/bin/bash
#
# Deploy CraftCV-backend onto the app instance. Runs as root, invoked only
# through the craftcv-deploy SSM document - never over SSH. Going through SSM
# is what leaves an audit trail in CloudTrail and keeps port 22 closed.
#
# The {{...}} placeholders are substituted by SSM before this reaches bash.
#
# Exit codes: 0 deployed, 75 another deploy held the lock, anything else is a
# genuine failure. CodeBuild surfaces all of them.

set -euo pipefail

COMMIT_SHA='{{CommitSha}}'
APP_DIR='{{AppDir}}'
REPO_URL='{{RepoUrl}}'
LOCK_WAIT='{{LockWaitSeconds}}'

LOCK_FILE=/var/lock/craftcv-deploy.lock
# The checkout is owned by ssm-user but this runs as root, and git refuses to
# touch a directory it does not consider trusted.
GIT="git -c safe.directory=${APP_DIR} -C ${APP_DIR}"

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[deploy FAILED] %s\n' "$*" >&2; exit 1; }

# --- Deployment lock ------------------------------------------------------
# Two merges landing together would otherwise run git reset and compose up
# over each other. The lock is held on fd 9 for the life of this process, so
# it is released even if we exit early or get killed.
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT" -x 9; then
  log "another deployment held the lock for more than ${LOCK_WAIT}s - giving up"
  exit 75
fi
log "lock acquired (pid $$)"

[ -d "${APP_DIR}/.git" ] || fail "no git checkout at ${APP_DIR}"
cd "${APP_DIR}"

# --- Fetch and reset to the intended revision -----------------------------
# set-url is idempotent and deliberate: it also scrubs any credential that a
# previous setup embedded in the remote URL.
$GIT remote set-url origin "${REPO_URL}"

log "fetching origin/develop"
$GIT fetch --prune --quiet origin develop || fail "git fetch failed"

# Refuse to deploy a commit that is not on develop. Without this, anything
# able to call the document could pin the box to an arbitrary revision.
if ! $GIT merge-base --is-ancestor "${COMMIT_SHA}" origin/develop; then
  fail "${COMMIT_SHA} is not an ancestor of origin/develop - refusing to deploy"
fi

PREVIOUS=$($GIT rev-parse --short HEAD)
log "moving ${PREVIOUS} -> ${COMMIT_SHA}"
# reset --hard, never `git clean`: .env lives here untracked and holds the
# database credentials. Cleaning would wipe it and take the stack down.
$GIT reset --hard --quiet "${COMMIT_SHA}" || fail "git reset failed"
$GIT --no-pager log --oneline -1

[ -f compose.yaml ] || fail "no compose.yaml at ${APP_DIR}"
[ -f .env ] || fail "no .env at ${APP_DIR} - refusing to start with no configuration"

# --- Build ----------------------------------------------------------------
log "building web image"
docker compose build web || fail "docker compose build failed"

# --- Database up, then migrate, then serve --------------------------------
# Order matters: migrations must finish before the new code serves traffic.
log "starting database"
docker compose up -d db || fail "could not start db"

log "waiting for database to become healthy"
healthy=0
for i in $(seq 1 30); do
  if docker compose ps db 2>/dev/null | grep -q "healthy"; then
    log "database healthy after ${i}s"
    healthy=1
    break
  fi
  sleep 1
done
[ "$healthy" -eq 1 ] || fail "database never became healthy"

log "running migrations"
docker compose run --rm web python manage.py migrate --noinput || fail "migrations failed"

log "recreating web with the new image"
docker compose up -d --no-deps web || fail "could not start web"

# --- Verify ---------------------------------------------------------------
# Any HTTP response proves gunicorn and Django are alive; a 404 on / is
# expected because nothing is routed there. Only a 5xx, or no answer at all,
# counts as a failure.
log "checking the application responds"
ok=0
code=000
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8000/ || echo "000")
  if [ "$code" != "000" ] && [ "$code" -lt 500 ]; then
    log "application responded HTTP ${code} after $((i * 2))s"
    ok=1
    break
  fi
  sleep 2
done
[ "$ok" -eq 1 ] || fail "application did not respond within 60s (last code ${code})"

# Reclaim space from superseded images. The box has only a few GB free, and a
# failure here must not fail an otherwise good deploy.
docker image prune -f >/dev/null 2>&1 || true

log "deployed ${COMMIT_SHA} successfully"
