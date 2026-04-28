# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-04-22

### Added
- `dma-newrelic-export.sh` — Bash export script (Linux/macOS/WSL)
- `dma-newrelic-export.ps1` — PowerShell export script (Windows/cross-platform)
- Exports: dashboards, alert policies, NRQL conditions, notification channels
- Exports: synthetic monitors, workloads, service level indicators
- Optional exports: RBAC (users/groups), usage analytics
- Manifest generation (`manifest.json`) with per-account statistics
- Summary generation (`dma-env-summary.md`) with migration mapping reference
- Anonymized archive support (`--anonymize`) via SHA-256 field masking
- jq-based JSON processing (consistent with DMA DataDog export tooling)
- CRLF auto-detection and fix (Windows line ending safety)
- Pre-flight checklist in script header
- NerdGraph two-phase GUID discovery + batch entity fetch pattern
- Support for US and EU API regions
- Auto-discover accounts when `--accounts` is omitted
- Retry with exponential backoff (3 attempts, 2s/4s delays)
- 50ms inter-page delay to respect NerdGraph rate limits

### Notes
- Supersedes `dynabridge-for-newrelic` — same NerdGraph API coverage, DMA naming conventions
- Archive name changed to `dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz`
- JSON processing migrated from `python3` inline scripts to `jq` (no Python dependency)
- Service levels now use the `actor.account.serviceLevel.indicators` query (more efficient than entity scan)
