#!/bin/bash
#
# Deploy CraftCV-frontend onto the app instance. Runs as root, invoked only
# through the craftcv-deploy-frontend SSM document - never over SSH.
#
# The frontend is generated to static files and served by nginx from the same
# origin as the API, so nothing here knows or cares what the instance's public
# IP is. That is deliberate: the sandbox stops overnight and comes back on a
# different address.
#
# The {{...}} placeholders are substituted by SSM before this reaches bash.
#
# Exit codes: 0 deployed, 75 another deploy held the lock, anything else is a
# genuine failure.

set -euo pipefail

COMMIT_SHA='{{CommitSha}}'
APP_DIR='{{AppDir}}'
REPO_URL='{{RepoUrl}}'
WEB_ROOT='{{WebRoot}}'
LOCK_WAIT='{{LockWaitSeconds}}'

LOCK_FILE=/var/lock/craftcv-deploy-frontend.lock
GIT="git -c safe.directory=${APP_DIR} -C ${APP_DIR}"

log() { printf '[frontend %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[frontend FAILED] %s\n' "$*" >&2; exit 1; }

# --- Lock -----------------------------------------------------------------
exec 9>"$LOCK_FILE"
if ! flock -w "$LOCK_WAIT" -x 9; then
  log "another frontend deployment held the lock for more than ${LOCK_WAIT}s"
  exit 75
fi
log "lock acquired (pid $$)"

command -v node >/dev/null || fail "node is not installed on this instance"
command -v npm  >/dev/null || fail "npm is not installed on this instance"
[ -d "${APP_DIR}/.git" ] || fail "no git checkout at ${APP_DIR}"
cd "${APP_DIR}"

# --- Fetch and reset ------------------------------------------------------
$GIT remote set-url origin "${REPO_URL}"
log "fetching origin/develop"
$GIT fetch --prune --quiet origin develop || fail "git fetch failed"

if ! $GIT merge-base --is-ancestor "${COMMIT_SHA}" origin/develop; then
  fail "${COMMIT_SHA} is not an ancestor of origin/develop - refusing to deploy"
fi

log "moving $($GIT rev-parse --short HEAD) -> ${COMMIT_SHA}"
$GIT reset --hard --quiet "${COMMIT_SHA}" || fail "git reset failed"
$GIT --no-pager log --oneline -1

# --- Build ----------------------------------------------------------------
# npm ci, not install: it installs exactly the lockfile and fails if
# package.json and package-lock.json disagree.
log "installing dependencies"
npm ci --no-audit --no-fund >/tmp/craftcv-npm-ci.log 2>&1 \
  || { tail -25 /tmp/craftcv-npm-ci.log >&2; fail "npm ci failed"; }

# The box has under 1GB of RAM. Capping the heap below that makes V8 collect
# garbage and spill to swap instead of being killed by the OOM reaper.
log "generating static site"
NODE_OPTIONS=--max-old-space-size=1024 npx nuxt generate >/tmp/craftcv-generate.log 2>&1 \
  || { tail -25 /tmp/craftcv-generate.log >&2; fail "nuxt generate failed"; }

[ -f .output/public/index.html ] || fail "no index.html in .output/public"

# --- Publish --------------------------------------------------------------
# Swap the directory into place rather than writing into the live root, so a
# visitor mid-request never sees a half-copied site.
log "publishing to ${WEB_ROOT}"
STAGING="${WEB_ROOT}.new"
rm -rf "$STAGING"
cp -a .output/public "$STAGING"
if [ -d "$WEB_ROOT" ]; then
  rm -rf "${WEB_ROOT}.old"
  mv "$WEB_ROOT" "${WEB_ROOT}.old"
fi
mv "$STAGING" "$WEB_ROOT"
rm -rf "${WEB_ROOT}.old"
chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null || true

# --- Verify ---------------------------------------------------------------
log "checking nginx serves the site"
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
[ "$ok" -eq 1 ] || fail "frontend did not return 200 within 30s (last code ${code})"

# The API must still answer through the same nginx, or we have published a
# frontend that cannot talk to anything.
api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/api/docs/schema/ || echo "000")
log "api through nginx: HTTP ${api}"
[ "$api" != "000" ] && [ "$api" -lt 500 ] || fail "the API is not reachable through nginx (${api})"

# node_modules is the biggest thing on this small disk after a build.
du -sh node_modules 2>/dev/null | sed 's/^/[frontend] node_modules: /' || true
df -h / | tail -1 | sed 's/^/[frontend] disk: /'

log "deployed ${COMMIT_SHA} successfully"
