#!/usr/bin/env bash
# update.sh — host-side auto-updater for the Nextcloud appliance.
#
# Same idea as openclaw-vm's updater: the VM converges to whatever THIS REPO says, never to
# whatever the registry drifted to. Images here are pinned by digest, so an update happens
# only when we bump a pin and push. Triggered by nextcloud-update.timer (there is no panel on
# this product, so nothing else would ever press the button).
#
# WHY THE TWO GUARDS BELOW EXIST. An auto-updater on a machine with no operator is a loaded
# gun: one bad commit reaches every customer at once. Two upgrades are unrecoverable, so this
# script refuses them and keeps running the old version instead:
#
#   1. Nextcloud majors cannot be skipped. 33 -> 34 -> 35, one at a time; `occ upgrade`
#      refuses a jump and the instance is then stuck with a database it cannot migrate.
#   2. PostgreSQL majors cannot move at all. The official image does not run pg_upgrade: the
#      container simply refuses to start against a datadir from the previous major, and the
#      customer's files end up behind a database that will not open.
#
# Refusing is always safer than proceeding: a VM that stays on the old version still serves
# the customer's files. One that half-upgraded does not.

set -euo pipefail

REPO_DIR="/opt/nextcloud-vm"
COMPOSE_FILE="${REPO_DIR}/docker-compose.yml"
BRANCH="${UPDATE_BRANCH:-main}"
STAMP="${REPO_DIR}/.deploy-version.json"

log() { printf '[updater %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[updater ERROR] %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found"
command -v git    >/dev/null 2>&1 || die "git not found"
[ -d "${REPO_DIR}/.git" ] || die "no git checkout at ${REPO_DIR}"

git config --global --add safe.directory "${REPO_DIR}" 2>/dev/null || true

# Major version of an image pin in a compose file, e.g. "image: postgres:18@sha256:..." -> 18
img_major() { printf '%s' "$1" | grep -oE "image: ${2}:[0-9]+" | head -n1 | grep -oE '[0-9]+$' || true; }

log "Fetching origin/${BRANCH}"
git -C "${REPO_DIR}" fetch --quiet origin "${BRANCH}" || die "git fetch failed"

LOCAL="$(git -C "${REPO_DIR}" rev-parse HEAD)"
REMOTE="$(git -C "${REPO_DIR}" rev-parse "origin/${BRANCH}")"
if [ "${LOCAL}" = "${REMOTE}" ]; then
  log "Already at $(git -C "${REPO_DIR}" rev-parse --short HEAD); nothing to do."
  exit 0
fi

# Inspect the incoming compose BEFORE touching the checkout, so a refusal leaves the VM
# exactly as it was rather than reset to code we then decline to run.
CUR="$(cat "${COMPOSE_FILE}")"
NEW="$(git -C "${REPO_DIR}" show "origin/${BRANCH}:docker-compose.yml")" || die "cannot read incoming compose"

CUR_NC="$(img_major "${CUR}" nextcloud)"; NEW_NC="$(img_major "${NEW}" nextcloud)"
CUR_PG="$(img_major "${CUR}" postgres)";  NEW_PG="$(img_major "${NEW}" postgres)"
[ -n "${CUR_NC}" ] && [ -n "${NEW_NC}" ] && [ -n "${CUR_PG}" ] && [ -n "${NEW_PG}" ] \
  || die "could not read image majors from compose; refusing to update blind"

if [ "${NEW_PG}" != "${CUR_PG}" ]; then
  die "REFUSING: postgres major ${CUR_PG} -> ${NEW_PG}. The official image cannot pg_upgrade an existing datadir; this VM would never start again. Staying on ${CUR_PG}. A postgres major needs a deliberate dump/restore migration, not an auto-update."
fi
if [ "${NEW_NC}" -gt $((CUR_NC + 1)) ]; then
  die "REFUSING: nextcloud ${CUR_NC} -> ${NEW_NC} skips a major. Nextcloud upgrades one major at a time; staying on ${CUR_NC}. Ship the intermediate major first."
fi
[ "${NEW_NC}" -eq "${CUR_NC}" ] || log "Nextcloud major ${CUR_NC} -> ${NEW_NC} (single step, allowed)"

log "Updating $(git -C "${REPO_DIR}" rev-parse --short HEAD) -> $(git -C "${REPO_DIR}" rev-parse --short "origin/${BRANCH}")"
# .env and any runtime state are gitignored, so this cannot clobber the customer's secrets.
git -C "${REPO_DIR}" reset --hard "origin/${BRANCH}" || die "git reset failed"

log "Pulling images"
docker compose -f "${COMPOSE_FILE}" pull
log "Recreating containers"
# The nextcloud image runs `occ upgrade` itself on start when it finds an older installed
# version, which is why a single-major step is safe to do unattended.
docker compose -f "${COMPOSE_FILE}" up -d

printf '{"sha":"%s","at":"%s"}\n' "$(git -C "${REPO_DIR}" rev-parse HEAD)" "$(date -u +%FT%TZ)" > "${STAMP}"
log "Update complete (now at $(git -C "${REPO_DIR}" rev-parse --short HEAD))"
