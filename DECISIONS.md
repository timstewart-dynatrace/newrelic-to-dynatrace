# Decisions

Technical decisions made in this project.

---

## 2026-04-21 — NerdGraph GraphQL as sole API interface

**Chosen:** Use New Relic NerdGraph (GraphQL) API exclusively for all data extraction.

**Alternatives:**
- New Relic REST API v2 (legacy, maintenance-mode)
- New Relic Insights Query API (NRQL-only, no config access)

**Why:** NerdGraph is New Relic's primary, supported API surface for all modern resources — dashboards, alert conditions, users, workloads, service levels. The REST API v2 is in maintenance mode with no new features. A single endpoint (`/graphql`) simplifies authentication and retry logic.

**Trade-offs:** GraphQL cursor-based pagination requires iterative fetching. Some legacy notification channels only exist in REST API v2 and are documented as known gaps.

**Revisit if:** New Relic introduces a bulk export API or deprecates NerdGraph.

---

## 2026-04-21 — Single-file self-contained scripts (Bash + PowerShell)

**Chosen:** Deliver the export tool as two self-contained single-file scripts with no external dependencies beyond `curl`, `jq`, and `tar` (Bash) or built-in cmdlets (PowerShell).

**Alternatives:**
- Python package with `pip install` requirements
- Node.js script with npm dependencies
- Compiled binary (no runtime dependencies but harder to inspect)

**Why:** Mirrors the proven approach of DMA for Splunk and DMA for DataDog. Single files are easy to audit, copy to restricted environments, and require zero package manager setup. `curl` and `tar` ship with macOS/Linux by default; `jq` is a one-line install (`brew install jq` or `apt-get install jq`).

**Trade-offs:** JSON processing in bash + inline Python is verbose. Complexity grows with each new export type. Acceptable at current scale; a Python package would be warranted above ~500KB.

**Revisit if:** Script size or maintenance complexity makes single-file approach impractical.

---

## 2026-04-21 — Per-account directory structure in archive

**Chosen:** Organize exported data under `account_ACCOUNTID/` directories, with shared `_rbac/`, `_systeminfo/`, and `_usage_analytics/` at root.

**Alternatives:**
- Flat structure with account ID filename prefixes
- Separate archive per account

**Why:** New Relic organizations typically span multiple accounts. A flat structure creates naming conflicts and complicates per-account processing by downstream tooling. Separate archives complicate cross-account analysis.

**Trade-offs:** Slightly more complex archive traversal. Compensated by `manifest.json` providing a complete index of all accounts and their statistics.

**Revisit if:** Downstream tooling requires per-account archives.

---

## 2026-04-21 — RBAC and usage analytics disabled by default

**Chosen:** `--rbac` and `--usage` require explicit opt-in; `--all` does not enable them.

**Alternatives:**
- Include everything by default
- Interactive prompts for optional sections

**Why:** RBAC exports contain PII (user emails). Usage analytics run additional NRQL queries against `NrAuditEvent` and `NrConsumption`, significantly increasing runtime on large environments. Matches DMA for Splunk v4.2.4+ behavior.

**Trade-offs:** Users must remember the extra flags for complete exports. Mitigated by documentation and the help output listing them explicitly.

**Revisit if:** Field feedback shows users consistently miss these flags.

---

## 2026-04-22 — Two-phase entity fetch (GUIDs, then batched details)

**Chosen:** For all entity-backed resource types (dashboards, synthetic monitors, workloads, service-level indicators), enumerate GUIDs via `entitySearch` and then fetch full entity details in batches of 25 via `actor.entities(guids:)`.

**Alternatives:**
- Request full details directly in `entitySearch` (original v1.0.0 approach) — does not work because `entitySearch.results.entities` returns the `*EntityOutline` union, not the concrete entity types
- Fetch each GUID one at a time via `actor.entity(guid:)` — 40× more HTTP calls, hits rate limits
- Use the REST API v2 for entities — not viable; incomplete resource coverage

**Why:** Live API testing at v1.0.0 revealed the `entitySearch` inline-fragment spreads on `DashboardEntity`/`SyntheticMonitorEntity`/`WorkloadEntity` were silently matching nothing because the field actually returns `*EntityOutline` types. `actor.entities(guids:)` accepts up to 25 GUIDs per call and returns the concrete entity types, so two-phase is both correct and efficient.

**Trade-offs:** Doubles the number of HTTP round-trips per resource type (one cursor walk + one batched detail walk). At typical account sizes (hundreds of dashboards, tens of monitors) this is still under a few seconds. Adds a `ENTITY_FETCH_BATCH = 25` constant that both scripts must keep in sync.

**Revisit if:** NerdGraph adds full concrete-entity support inside `entitySearch`, or if the 25-GUID batch limit changes.

---

## 2026-04-22 — All log functions write to stderr

**Chosen:** `log_info`, `log_warn`, `log_error`, and `log_debug` all write to stderr; only the actual script output (JSON, archive paths, etc.) goes to stdout.

**Alternatives:**
- Keep `log_info` on stdout, only route errors/debug to stderr — original v1.0.0 behavior
- Strip all logging and rely on log file only

**Why:** Helper functions called inside `$(...)` command substitutions were capturing `log_info` output into variables, silently corrupting JSON payloads (e.g., a log line would appear inside a GraphQL query string). Routing all logs to stderr keeps `$(...)` captures clean while still letting the user see progress on the terminal.

**Trade-offs:** Users redirecting stdout to a file will no longer capture progress lines — but the script already writes a dedicated log file via `--log-file`, so this is the correct separation.

**Revisit if:** A downstream tool needs to parse structured progress events (then emit JSONL on a dedicated fd).

---

## 2026-04-22 — Bash portability target: macOS (BSD) and Linux (GNU)

**Chosen:** Avoid GNU-only flags anywhere the script runs. Replace `head -n -N` with `sed '$d'`; write date/sed/grep usage to the BSD-compatible intersection.

**Alternatives:**
- Declare Linux-only support and require GNU coreutils on macOS (`brew install coreutils`)
- Ship separate `*-linux.sh` and `*-macos.sh` scripts

**Why:** A significant share of users will run the export from a macOS laptop against a production New Relic org. Requiring `brew install coreutils` or a Docker wrapper creates friction that the user will not tolerate for a one-shot migration tool.

**Trade-offs:** Some GNU idioms (in-place `sed -i`, `readlink -f`, `date -d`) need workarounds. Accepted as cost of portability; workarounds are documented inline where non-obvious.

**Revisit if:** macOS support is dropped or GNU-only features become necessary (unlikely for this tool's scope).

---

## 2026-06-12 — Credential loading via .env with CLI-first precedence

**Chosen:** Load `NEW_RELIC_USER_API_KEY` / `NEW_RELIC_ACCOUNT_ID` / `NEW_RELIC_REGION` from a `.env` file (cwd first, then repo root), applied only as fallbacks: CLI flags > process environment > `.env`. Loader snapshots pre-existing env values and restores them after sourcing, so an exported variable always beats a `.env` line.

**Alternatives:**
- Flags-only (status quo) — forces the key onto the command line and into shell history on every run
- A `--config FILE` flag with a custom format — more code, nonstandard, no editor/tooling support
- Named profiles (AWS-style `~/.dma/credentials`) — overkill for a one-shot migration tool

**Why:** Repeat runs during a migration engagement re-enter the same key/account; `.env` is the established convention, already used by sibling DMA repos for DT tenant tokens. Keeping CLI flags as highest precedence preserves every existing invocation and the documented quick-start unchanged.

**Trade-offs:** Sourcing `.env` executes it as shell — a malformed or malicious file runs code. Acceptable: the file is user-authored, git-ignored, and the same trust model as direnv/dotenv tooling.

**Revisit if:** The PowerShell port needs parity (it currently has no `.env` support), or multi-tenant engagements need more than one credential set per checkout.
