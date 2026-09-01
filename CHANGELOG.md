# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-09-01

First semver release. Brings this template to the fleet standard established
in [keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose)
v1.2.0.

### Fixed (the scheduled backup never ran)

- **The backup service was not on the `zammad-network`** — compose placed
  it on the project-default network, where the `postgres` hostname does
  not resolve, so every scheduled `pg_dump` failed on DNS. If you
  deployed an earlier revision, check that your backup volume actually
  has files.
- The backup script no longer carries a hardcoded database-password
  fallback; the password must come from the container environment.

### Changed (BREAKING for existing deployments)

- **Zammad 6.5 → 7.1.3** (a major upgrade — Zammad migrates its schema on
  first start; back up first and expect a longer initial boot),
  **Elasticsearch 8.17 → 8.19**, **Traefik 3.2 → 3.7** (3.2's Docker
  client cannot talk to Docker Engine 29); PostgreSQL 17 and the rest
  digest-pinned. All pins in the compose `x-images` block.
- Elasticsearch got a healthcheck and an explicit 512 MB heap.

### Security

- **Credentials untracked from git.** The tracked `.env` carried a
  generated-looking database password — rotate it if reused.

### Added

- **Deployment Verification workflow**: shellcheck + actionlint; Trivy
  scans of all six pinned images; weekly `check-pin-freshness`; and a
  deploy-and-test job that boots the full stack (init seeds the
  database) and requires the Zammad API to answer through Traefik.

[Unreleased]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/zammad-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
