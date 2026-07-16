# nextcloud-vm

Turnkey single-tenant Nextcloud appliance for CloudHosting.lv. One customer, one VM, cloned
here by the Ubuntu autoinstall; a systemd oneshot brings it up on first real boot. The
customer opens `https://vps-<o3>-<o4>.cloudhosting.lv`, logs in, and everything works,
including Office.

## The stack

| service | image | why |
|---|---|---|
| `app` | `nextcloud:33-apache` | Nextcloud itself. The only thing the customer sees. |
| `cron` | same image, `/cron.sh` | background jobs. Without it Nextcloud nags forever and previews/scans never run. |
| `db` | `postgres:18` | Nextcloud's own recommended database. |
| `redis` | `redis:8-alpine` | file locking + cache. Without it concurrent edits corrupt. |
| `collabora` | `collabora/code:26.04.2.1.1` | Nextcloud Office. |
| `caddy` | `caddy:2.11-alpine` | TLS. The only internet-facing service. |

Only Caddy publishes ports (80 for ACME, 443 for everything). The database, Redis, Collabora
and Nextcloud itself are unreachable from off-box.

## Why 33 and not 34

Nextcloud 34.0.1 exists. Nextcloud's own `stable` **and** `production` channels still resolve
to 33.0.6 (checked 2026-07-16, five weeks after 34.0.0). This machine is handed to somebody
who will never run `docker` on it, so we ship what the vendor itself calls production.

## Why every image is pinned by digest

There is no operator on this VM. A moved tag is not an inconvenience here, it is a dead
machine nobody can repair. Two are outright dangerous to float:

* **postgres** — the official image does not run `pg_upgrade`. If the tag rolled 18 → 19 the
  container would refuse to start against the existing datadir, and the customer's files
  would be behind a database that will not open.
* **nextcloud** — Nextcloud refuses to skip a major on upgrade. A tag that jumped 33 → 35
  leaves an install with no supported path forward.

Re-bake by bumping the digest here. Never by floating the tag.

## One hostname, including the office

We get exactly one DNS record per VM and there is no wildcard on `cloudhosting.lv`, so the
office cannot have its own subdomain without hand-adding a second record per machine.
Collabora supports this properly: `net.service_root=/office` shifts every Collabora URL
under `/office`, and coolwsd strips the prefix off inbound requests itself and injects it
into the discovery document and the served assets. Caddy therefore uses `handle`, **not**
`handle_path` — stripping the prefix twice makes the editor 404 with no useful error.

Stated plainly: Collabora's and Nextcloud's docs both recommend a separate subdomain "for
security reason", the point being origin isolation between the editor and the app it edits.
This is one customer's own VM: same-origin means the editor shares an origin with that
customer's own data and nobody else's. If a second DNS name per VM ever becomes cheap,
splitting them is the stricter setup.

### The `domain` env var is dead — do not add it back

Every blog post about Collabora in Docker sets `domain=nextcloud\.example\.com` (an
escaped-dot regex). Current CODE **does not read it**. `coolwsd --use-env-vars` reads only
`aliasgroup1..N`, `username`, `password`, `server_name`, `dictionaries`, `remoteconfigurl`
and `content_security_policy`. Setting `domain` is silently ignored and leaves Collabora in
trust-on-first-use. We use `aliasgroup1`.

## Secrets

The autoinstall writes exactly one line into `.env`: `NC_ADMIN_PASSWORD`, the same password
the customer is emailed. `firstboot.sh` generates `DB_PASSWORD`, `REDIS_PASSWORD` and
`COLLABORA_ADMIN_PASSWORD` on the customer's own machine. None of them exist in this repo,
in a template, or on our side. `.env` is gitignored and `chmod 0600`.

`NEXTCLOUD_ADMIN_PASSWORD` is read **only** on the first start against an empty volume.
Changing it in `.env` later does nothing:

```
docker compose exec -u www-data app php occ user:resetpassword admin
```

## Operating it

```bash
cd /opt/nextcloud-vm
docker compose ps
docker compose logs -f app
journalctl -u nextcloud-firstboot.service   # what happened on the first boot

# occ, the Nextcloud admin CLI
docker compose exec -u www-data app php occ status
docker compose exec -u www-data app php occ app:list
```

The first boot pulls ~2 GB and waits for Nextcloud's own installer, so it takes minutes, not
seconds. That is why the unit sets `TimeoutStartSec=1800`; the systemd default of 90s would
kill it half-installed.

## Sizing

Collabora alone wants 2 GB of RAM and recommends 4. With Nextcloud, PostgreSQL, Redis and the
OS beside it, the Starter plan was raised from 2 GB to 4 GB when this appliance shipped. Do
not sell the full package on less.
