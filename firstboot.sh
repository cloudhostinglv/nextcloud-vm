#!/usr/bin/env bash
# firstboot.sh — one-shot first-real-boot provisioning for the Nextcloud per-client VM.
#
# Runs ONCE via nextcloud-firstboot.service (enabled by the Ubuntu autoinstall). Idempotent;
# disables itself at the end. Everything the customer would otherwise have to do by hand:
#
#   1. Generate the secrets the autoinstall does NOT ship (DB, Redis, Collabora admin).
#   2. Derive NC_DOMAIN from the primary IPv4 if blank.
#   3. docker compose pull && up -d.
#   4. Wait for Nextcloud to finish installing itself.
#   5. Turn the office on (install richdocuments, point it at our own /office) and clear the
#      warnings a fresh Nextcloud shows in the admin overview.
#   6. Disable this oneshot.
#
# The ONLY thing the autoinstall writes into .env is NC_ADMIN_PASSWORD. Everything else is
# generated here, on the customer's own machine, so no secret is ever in git or in a template.

set -euo pipefail

APP_DIR="/opt/nextcloud-vm"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }
occ()     { compose exec -T -u www-data app php occ "$@"; }

gen_secret() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40; }

# Append KEY=value to .env only if KEY is not already there. Never rewrites an existing
# value: on a re-run that would hand the app a new DB password the database does not have.
ensure_env() {
  local key="$1" val="$2"
  if ! grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
    log "Generated ${key}"
  fi
}

touch "${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

# --- 1. Secrets --------------------------------------------------------------------------
ensure_env DB_PASSWORD                "$(gen_secret)"
ensure_env REDIS_PASSWORD             "$(gen_secret)"
ensure_env COLLABORA_ADMIN_PASSWORD   "$(gen_secret)"

# Read .env WITHOUT sourcing it. `. .env` is shell EVALUATION, not dotenv parsing: an admin
# password containing a space or ';' aborts this script (and the VM boots with no stack at
# all), and one containing `$(...)` or a backtick would EXECUTE AS ROOT and silently mangle
# itself, so the customer would be emailed one password and Nextcloud installed with another.
# The value only ever needs reading, so read it.
env_get() { sed -n "s/^$1=//p" "${ENV_FILE}" | head -n1; }
NC_ADMIN_PASSWORD="$(env_get NC_ADMIN_PASSWORD)"
NC_ADMIN_USER="$(env_get NC_ADMIN_USER)"
NC_DOMAIN="$(env_get NC_DOMAIN)"

[ -n "${NC_ADMIN_PASSWORD:-}" ] || die "NC_ADMIN_PASSWORD missing from .env - the autoinstall should have written it"
# Fail loudly here rather than let a surprising character reach docker compose's own dotenv
# parser, which interpolates ${...} in unquoted values and would hand the container a
# different password than the one we emailed.
case "${NC_ADMIN_PASSWORD}" in
  *[!A-Za-z0-9]*) die "NC_ADMIN_PASSWORD must be [A-Za-z0-9]; the installer emitted something shell-special" ;;
esac

# --- 2. Domain ---------------------------------------------------------------------------
# Same convention as the OpenClaw appliance: vps-<3rd octet>-<4th octet>.cloudhosting.lv,
# which has an A record pointing back at this VM. That record is what lets Caddy pass the
# Let's Encrypt HTTP-01 challenge; without it there is no certificate and Nextcloud refuses
# to behave (it hard-requires https for the office iframe and for mobile clients).
if [ -z "${NC_DOMAIN:-}" ]; then
  # `|| true` is load-bearing. Under `set -euo pipefail`, if the route lookup prints nothing
  # (no default route yet on a slow-DHCP boot) grep exits 1, pipefail propagates, and set -e
  # kills the script AT THIS ASSIGNMENT: the fallback below and the die() never run, systemd
  # marks the unit failed, and the journal explains nothing. The guards exist for exactly the
  # case that used to skip them.
  # After=network-online.target does not promise an IPv4 default route, so wait for one
  # rather than failing the boot over a few seconds of DHCP.
  IP=""
  for _ in $(seq 1 30); do
    IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1 || true)"
    [ -n "${IP}" ] && break
    sleep 2
  done
  [ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [ -n "${IP}" ] || die "could not determine primary IPv4 to derive NC_DOMAIN after 60s"
  O3="$(printf '%s' "${IP}" | cut -d. -f3)"
  O4="$(printf '%s' "${IP}" | cut -d. -f4)"
  NC_DOMAIN="vps-${O3}-${O4}.cloudhosting.lv"
  log "Derived NC_DOMAIN=${NC_DOMAIN} from IP ${IP}"
  if grep -q '^NC_DOMAIN=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^NC_DOMAIN=.*|NC_DOMAIN=${NC_DOMAIN}|" "${ENV_FILE}"
  else
    printf 'NC_DOMAIN=%s\n' "${NC_DOMAIN}" >> "${ENV_FILE}"
  fi
  export NC_DOMAIN
else
  log "NC_DOMAIN already set: ${NC_DOMAIN}"
fi

# --- 3. Start ----------------------------------------------------------------------------
log "docker compose pull"
compose pull
log "docker compose up -d"
compose up -d

# --- 4. Wait for Nextcloud to install itself ---------------------------------------------
# The image installs on first start against the empty volume. occ is unusable until then and
# every command below would fail. 'status' reports installed:true when it is done.
log "Waiting for Nextcloud to finish installing (up to 10 min)"
for i in $(seq 1 120); do
  if occ status 2>/dev/null | grep -q 'installed: true'; then
    log "Nextcloud is installed (after ~$((i * 5))s)"
    break
  fi
  [ "${i}" -eq 120 ] && die "Nextcloud did not finish installing in 10 min; see: docker compose logs app"
  sleep 5
done

# --- 5. Office + first-run tidy ----------------------------------------------------------
# Nextcloud Office = the richdocuments app talking to our own Collabora over the SAME host,
# under /office. wopi_url is what richdocuments appends /hosting/discovery to.
log "Enabling Nextcloud Office (richdocuments) against https://${NC_DOMAIN}/office"
occ app:install richdocuments 2>/dev/null || occ app:enable richdocuments
occ config:app:set richdocuments wopi_url --value "https://${NC_DOMAIN}/office"
# Collabora calls back into Nextcloud for the file contents; allow it from the docker net.
occ config:app:set richdocuments wopi_allowlist --value "172.16.0.0/12"
# Ask Collabora for its capabilities now so the first customer to open a document does not
# wait for the discovery round-trip (and so a broken office shows up HERE, in our log).
occ richdocuments:activate-config 2>/dev/null || log "WARN: could not pre-fetch Collabora config; the office may need a minute"

# Warnings a fresh Nextcloud shows in the admin overview. Fixing them here means the customer
# never sees a red panel on a machine they just bought.
occ config:system:set default_phone_region --value "LV"
occ config:system:set maintenance_window_start --type=integer --value=1
occ db:add-missing-indices || true
occ maintenance:repair --include-expensive || true

# --- 6. Auto-updates ---------------------------------------------------------------------
# Nobody operates this VM, and Nextcloud ships security fixes. The timer converges it to
# whatever this repo says (images are digest-pinned there, so it never chases a moving tag).
# update.sh refuses the two upgrades that cannot be undone: a skipped Nextcloud major and any
# PostgreSQL major.
log "Enabling daily auto-update"
cp "${APP_DIR}/updater/nextcloud-update.service" /etc/systemd/system/
cp "${APP_DIR}/updater/nextcloud-update.timer"   /etc/systemd/system/
chmod 0755 "${APP_DIR}/updater/update.sh"
systemctl daemon-reload
systemctl enable --now nextcloud-update.timer

log "Provisioning complete. Nextcloud: https://${NC_DOMAIN}  (admin user: ${NC_ADMIN_USER:-admin})"

# --- 7. Disable this oneshot -------------------------------------------------------------
systemctl disable nextcloud-firstboot.service 2>/dev/null || true
