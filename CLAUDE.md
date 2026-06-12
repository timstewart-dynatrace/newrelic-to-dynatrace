# CLAUDE.md — newrelic-to-dynatrace

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## This Repo

`newrelic-to-dynatrace` holds the **New Relic export scripts** — the first stage of the DMA New Relic pipeline. The scripts in [`newrelic-export/`](newrelic-export/) (`dma-newrelic-export.sh` / `.ps1`, plus `nr-supplemental-export.sh`) pull the customer's NR configuration via NerdGraph/REST and produce a **`dma_export_newrelic_<timestamp>.tar.gz`** archive (dashboards, alert policies + NRQL conditions, SLOs, synthetics, workloads + `manifest.json`). That archive is the input consumed downstream by `@dma/newrelic-converter`, `dma-newrelic-app`, and `dma-server`.

**Track context:** this repo implements step 1 of the GOAL in [`dma-workspace/DMA-NEWRELIC/CLAUDE.md`](../dma-workspace/DMA-NEWRELIC/CLAUDE.md) — read that first for the NR-track directives (knowledge persistence, parity mandate, conversion-quality cautions). The DMA platform rules in [`dma-workspace/CLAUDE.md`](../dma-workspace/CLAUDE.md) apply (never commit/push without explicit instruction; `dynatrace-dma`-adjacent security rules — note this repo lives under `timstewart-dynatrace`, not `dynatrace-dma`).

## Key paths

- **Export scripts**: `newrelic-export/dma-newrelic-export.sh` (canonical), `.ps1` (Windows port), `nr-supplemental-export.sh` (supplemental extractor, in flight on `feature/supplemental-extractor`)
- **Docs**: `newrelic-export/docs_markdown/` + `docs_html/` (built via `build-docs.sh`)
- **Decisions / history**: `DECISIONS.md`, `CHANGELOG.md`
- Sample archives (`dma_export_newrelic_*.tar.gz`) at the repo root are test fixtures for downstream converter work

## Conventions

- Credentials come from `.env` (NR account/API keys + DT tenant tokens) — **never commit it**; see `README.md` for the required keys
- Version lives in `README.md` header; update `CHANGELOG.md` with every script change
- Branch-per-feature (`feature/…`, `fix/…`); `main` is the stable export script customers receive
- Export shape changes ripple downstream: `@dma/newrelic-converter`'s `ArchiveParser`/fixtures and the NR app's import path must be checked against any new/renamed archive entry
