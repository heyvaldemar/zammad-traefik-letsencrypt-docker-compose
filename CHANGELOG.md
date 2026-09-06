# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.7.0] - 2026-09-05

### Fixed

- **A backup interrupted halfway no longer looks like a finished one.** The
  backup script writes the dump and the file archive under a `.partial` name
  and renames each only once its write has succeeded. It already renamed a
  failed file to `.failed`, but that branch only runs if the shell lives long
  enough to reach it — a container stopped mid-dump does not, and left a
  truncated file under exactly the name a restore would pick. The rest of the
  fleet was fixed for this on 4 September; this repository was missed, because
  its loop lives in `scripts/backup.sh` rather than in the compose file.
- **Pruning now removes `.partial` and `.failed` files too**, and no longer
  depends on a glob expanding.

### Added

- **Backup and restore tested end to end**, nine assertions against the live
  stack, driven through the script's own one-shot entrypoints rather than its
  daily schedule. The dump is a complete gzip containing real SQL, the file
  archive lists, no `.partial` survives a completed cycle, and the dump
  restores into a throwaway database built from the same image as the live one
  with zero SQL errors and a real schema.
- **The failure case is exercised, not assumed.** A dump pointed at an
  unreachable database must be reported as failed, must leave nothing under a
  name a restore would choose, and must keep the partial file as `.failed` for
  diagnosis.

## [1.6.0] - 2026-09-04

### Added

- **A shutdown grace period for PostgreSQL and Redis.** Docker stops a container with
  SIGTERM and ten seconds, then SIGKILL. That default is not always enough:
  PostgreSQL has a checkpoint to write, MariaDB has InnoDB to flush, and Redis
  saves its dataset on the way out. Killed halfway, the next start does crash
  recovery, and a Redis holding another application's file locks leaves them
  behind for a person to clear by hand. Sixty seconds now, overridable per
  service with `<PREFIX>_STOP_GRACE_PERIOD` in `.env`. The backup sidecar is
  deliberately left alone: its failure mode is a truncated dump file, which a
  longer grace period does not fix.

## [1.5.0] - 2026-09-03

### Added

- **Per-image version overrides.** Every pin in the `x-images` block is
  now `${<PREFIX>_IMAGE_TAG:-repo:${<PREFIX>_IMAGE_VERSION:-tag@sha256:digest}}`.
  Set `<PREFIX>_IMAGE_VERSION` in `.env` to run a different version of one
  image while every other pin stays as tested (Compose pulls that tag
  without a digest), or `<PREFIX>_IMAGE_TAG` to replace the whole
  reference as before. A deployment that sets neither is unchanged. The
  freshness job, the Trivy matrix and the fleet digest automation resolve
  the nested default before reading a pin. Needs Docker Compose v2.5 or
  newer (2022): v2.0 to v2.4 leave the inner `${...}` unexpanded and
  `docker compose up` fails with an invalid reference instead of
  deploying something unexpected.

## [1.4.0] - 2026-09-02

### Security

- **Container hardening.** Every service runs with
  `security_opt: no-new-privileges:true` (no privilege escalation via
  setuid binaries even if a process escapes its initial capability
  set). Infrastructure containers (the reverse proxy, databases,
  caches, backups) drop every Linux capability and add back only what
  their entrypoints need (bind :80/:443, chown a data directory, drop to
  the service user). Application containers keep the default capability
  set: upstream images assume it, and a wrong guess there is a boot loop
  in production, not a hardening win. CI boots the stack under these
  settings on every push.

## [1.3.0] - 2026-09-02

### Fixed

- **A failed database dump no longer produces a silent, corrupt backup.**
  `scripts/backup.sh` piped `pg_dump` into `gzip` under `set -e` without
  `pipefail`, so a dump that failed halfway still left a small `.gz`
  that looked like a backup. The script now runs with `pipefail`, logs
  `Database backup OK: <file> (<bytes> bytes)` / `Data backup OK` or
  `FAILED` per cycle, and keeps a failed dump as `<file>.failed` for
  diagnosis. A file changing while the storage archive is written (GNU
  `tar` exit 1) is not a failure.

### Added

- CI now waits for the first backup cycle and proves the produced dump
  and storage archive are readable.

## [1.2.0] - 2026-09-02

### Added

- **Resource limits on every service, as `.env`-overridable defaults.**
  Each service now carries memory and CPU limits plus reservations
  (`<SERVICE>_MEMORY_LIMIT`, `_CPU_LIMIT`, `_MEMORY_RESERVATION`,
  `_CPU_RESERVATION`, defaults listed in `.env.example`). Set any of
  them in `.env` and the override survives every `git pull`. The
  defaults are what CI boots the stack under, so they are known to be
  enough for a fresh install; raise a limit if a service is OOM-killed
  under your real load (`docker inspect` shows `OOMKilled=true`).

## [1.1.0] - 2026-09-02

### Added

- **`update.sh`**: unattended updates to the newest tagged release,
  and nothing else: a tag is cut only after CI has booted the pinned
  images and passed the smoke tests, so "update to the latest tag" means
  "update to a combination a machine has already run". It refuses to
  cross a major version on its own (`--allow-major` after reading the
  notes), refuses a checkout with local modifications, and supports
  `--dry-run`. Put it on a cron timer for hands-off minor/patch updates.

## [1.0.0] - 2026-09-01

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Fixed (the scheduled backup never ran)

- **The backup service was not on the `zammad-network`**: compose placed
  it on the project-default network, where the `postgres` hostname does
  not resolve, so every scheduled `pg_dump` failed on DNS. If you
  deployed an earlier revision, check that your backup volume actually
  has files.
- The backup script no longer carries a hardcoded database-password
  fallback; the password must come from the container environment.

### Changed (BREAKING for existing deployments)

- **Zammad 6.5 → 7.1.3** (a major upgrade: Zammad migrates its schema on
  first start; back up first and expect a longer initial boot),
  **Elasticsearch 8.17 → 8.19, Traefik 3.2 → 3.7** (3.2's Docker
  client cannot talk to Docker Engine 29); PostgreSQL 17 and the rest
  digest-pinned. All pins in the compose `x-images` block.
- Elasticsearch got a healthcheck and an explicit 512 MB heap.

### Security

- **Credentials untracked from git.** The tracked `.env` carried a
  generated-looking database password: rotate it if reused.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; Trivy
  scans of all six pinned images; weekly `check-pin-freshness`; and a
  deploy-and-test job that boots the full stack (init seeds the
  database) and requires the Zammad API to answer through Traefik.

[Unreleased]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
