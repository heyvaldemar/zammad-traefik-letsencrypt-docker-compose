# Zammad + Traefik + Let's Encrypt — Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys **Zammad** — an open-source helpdesk and ticketing system — behind **Traefik** with automatic **Let's Encrypt TLS**: nginx, rails server, scheduler, and websocket services from the official image, backed by **PostgreSQL 17**, **Elasticsearch**, **Redis**, and **memcached**, with a daily **backup** service (database + storage).

## Getting started

You need two DNS records pointing at this server: the app hostname and the websocket hostname.

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose
cd zammad-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create zammad-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: ZAMMAD_DB_PASSWORD, both hostnames, TRAEFIK_HOSTNAME,
#   TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.

# 4. Deploy
docker compose -f zammad-traefik-letsencrypt-docker-compose.yml -p zammad up -d
```

First start takes several minutes: the `init` service migrates and seeds the database. Then `https://${ZAMMAD_HOSTNAME}` serves the setup wizard — create the admin account right away.

### What success looks like

```bash
docker compose -f zammad-traefik-letsencrypt-docker-compose.yml -p zammad ps
curl -fsk "https://${ZAMMAD_HOSTNAME}/api/v1/getting_started"   # {"setup_done":...}
```

### Common first-deploy issues

- **502/404 in the first minutes.** Normal — init is still seeding the database. Watch `docker logs zammad-init-1`.
- **Cert issuance fails.** DNS hasn't propagated for one of the two hostnames, or port 80 isn't reachable.
- **Search doesn't find tickets.** Elasticsearch needs a minute to build its index after setup; check `docker logs zammad-elasticsearch-1`.
- **Networks not found.** Step 2 was skipped.

## Supply chain trust

Six images — [`traefik`](https://hub.docker.com/_/traefik), [`ghcr.io/zammad/zammad`](https://github.com/zammad/zammad), [`postgres`](https://hub.docker.com/_/postgres), [`elasticsearch`](https://hub.docker.com/_/elasticsearch), [`redis`](https://hub.docker.com/_/redis), [`memcached`](https://hub.docker.com/_/memcached) — pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block. `git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

The weekly `check-pin-freshness` CI job re-resolves each pin against its registry and compares the pinned Zammad and Traefik versions against the latest upstream releases. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Complete the setup wizard immediately after deploy** — it creates the admin account.
- [ ] **Strong database password**; regenerate the Traefik dashboard hash.
- [ ] **Size the host for Elasticsearch** — 4 GB+ RAM for the stack; the ES heap is capped at 512 MB by default, raise `ES_JAVA_OPTS` for real ticket volume.
- [ ] **Host-mount the backup volume** (`zammad-backup`) for disaster recovery — and verify backups actually appear after the first `BACKUP_TIME`.
- [ ] **Back up before upgrades** — Zammad migrates its schema on version jumps.

## Backups

The `backup` service runs Zammad's own backup loop daily at `BACKUP_TIME` (default 03:00): a `pg_dump` of the database plus a tarball of `/opt/zammad/storage`, kept for `HOLD_DAYS` (default 10). Both land in the `zammad-backup` volume. Each cycle logs `Database backup OK: <file> (<bytes> bytes)` and `Data backup OK` (or `FAILED`, keeping a failed dump as `<file>.failed`); grep the `backup` service log for `FAILED` from your monitoring.

Worth knowing: before v1.0.0 the backup service was not attached to the network where PostgreSQL lives, so the scheduled dump never succeeded. If you ran an earlier revision, check your backup volume for recent files.

## Unattended updates

Releases are the update channel: a tag is cut only after CI has built the pinned images, booted the full stack, and passed the smoke tests. `update.sh` moves a deployment to the newest tag and nothing else:

```bash
./update.sh --dry-run   # show what would be applied
./update.sh             # update within the current major and redeploy
```

Put it on a timer for hands-off minor/patch updates:

```bash
# crontab -e
17 5 * * *  /opt/zammad-traefik-letsencrypt-docker-compose/update.sh >> /var/log/zammad-update.log 2>&1
```

The script refuses to cross a MAJOR template version on its own — majors are breaking by definition and their release notes exist to be read. After reading them, `./update.sh --allow-major` performs the jump. It also refuses to touch a checkout with local modifications: your customization belongs in `.env`, which updates never overwrite.

This is deliberately a host-side script and not a container in the stack: an in-stack updater needs the Docker socket (root on the host) and turns "someone pushed to a repo" into "someone deployed to your machine" with no operator in the loop. A cron job under your own user updates only to tagged, CI-verified states and leaves the trust boundary where it was.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults — the same values CI boots the stack under. Override any of them in `.env` (the knobs and their defaults are listed in `.env.example`, e.g. `TRAEFIK_MEMORY_LIMIT=512m`) and the override survives every `git pull`. If a service is OOM-killed under real load, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so; raise its `_MEMORY_LIMIT` and recreate.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every Monday at 06:00 UTC: shellcheck + actionlint, Trivy scans of all six pinned images, the weekly freshness check, and a deploy-and-test job that boots the full stack with ephemeral credentials, waits out database seeding, and requires the Zammad API to answer through Traefik.

## Security Notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- **Pre-rotation advisory.** Releases before v1.0.0 (2026-09-01) shipped a tracked `.env` with a generated-looking database password (it also appeared as a fallback inside the backup script). Rotate it if your deployment reused it.
- PostgreSQL, Elasticsearch, Redis, and memcached listen only on the internal network; Elasticsearch runs with security disabled by design inside that isolated network.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** — Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
