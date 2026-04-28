# Phase 01 — Initial Export Scripts

Status: DONE

## Goal
Deliver production-ready Bash and PowerShell export scripts covering all core New Relic asset types.

## Tasks
- [x] Create `dma-newrelic-export.sh` (Bash) with jq-based JSON processing
- [x] Create `dma-newrelic-export.ps1` (PowerShell) with matching flag names
- [x] Exports: dashboards, alerts (policies + NRQL conditions + channels), synthetics, workloads, service levels
- [x] Optional exports: RBAC (users/groups), usage analytics
- [x] Manifest generation (`manifest.json`) with per-account statistics
- [x] Summary generation (`dma-env-summary.md`)
- [x] Anonymized archive support (`--anonymize`)
- [x] README.md in DMA DataDog export format
- [x] CHANGELOG.md
- [x] `.claude/` setup from VisualCode-AI-Template FOUNDATION

## Acceptance Criteria
- [x] Bash script passes shellcheck (basic syntax)
- [x] PowerShell script parameter block matches Bash flags exactly
- [x] Archive named `dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz`
- [x] Manifest includes `export_tool: "dma-newrelic-export"`
