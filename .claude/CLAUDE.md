# DMA New Relic Export Script

> **Version:** 1.0.0
> **Last Updated:** April 2026

## Project Summary

Bash and PowerShell scripts that extract dashboards, alert policies, NRQL conditions, synthetic monitors, workloads, and service level indicators from New Relic accounts via the NerdGraph GraphQL API. Produces a structured `.tar.gz` archive consumed by the **DMA New Relic App** (`dma-newrelic-app`) and **DMA New Relic Converter** (`dma-newrelic-converter`) for migration to Dynatrace Gen3.

This project supersedes `dynabridge-for-newrelic`. Same API coverage, DMA naming conventions, jq-based JSON processing.

## Project Type

Shell scripting project (Bash + PowerShell). No application runtime. Deliverable: a pair of self-contained export scripts.

## Architecture

```
newrelic-to-dynatrace/
├── newrelic-export/
│   ├── dma-newrelic-export.sh    # Bash (Linux/macOS/WSL)
│   └── dma-newrelic-export.ps1   # PowerShell (Windows/cross-platform)
├── .claude/
│   ├── CLAUDE.md                 # This file
│   ├── DECISIONS.md
│   ├── settings.json
│   ├── phases/
│   └── rules/
├── README.md
└── CHANGELOG.md
```

## Key Constraints

- Scripts must be **self-contained single files** — no external dependencies beyond `curl`, `jq`, `tar` (Bash) or built-in cmdlets (PowerShell)
- All JSON processing uses `jq` in the Bash script — NOT python3 inline
- New Relic API: NerdGraph GraphQL at `https://api.newrelic.com/graphql` (US) or `https://api.eu.newrelic.com/graphql` (EU)
- Authentication: `API-Key: <NRAK-...>` header
- Pagination: cursor-based (`nextCursor` field)
- Rate limiting: 50ms delay between paginated requests; 3 retries with exponential backoff (2s, 4s)
- Archive name: `dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz`

## Rules

@.claude/rules/core.md
@.claude/rules/development.md

## Reflection Protocol

When a task is complete: 1. Log decisions to `.claude/DECISIONS.md`. 2. Update the active phase file. 3. Do this automatically before summarizing.
