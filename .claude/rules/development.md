# Development Rules

## Tech Stack

- **Bash 3.2+** — primary export script (Linux/macOS/WSL)
- **PowerShell 5.1+** — cross-platform script (Windows/macOS/Linux)
- **jq** — JSON processing in the Bash script (NOT python3 inline)
- **curl** — HTTP client in the Bash script

## Script Conventions (Bash)

- CRLF auto-fix header at the top of the script (from DMA DataDog pattern)
- `set -o pipefail` only — NOT `set -euo pipefail` (graceful error handling)
- Constants in `UPPER_SNAKE_CASE` declared `readonly` at top
- Functions grouped by concern: logging → helpers → exports → manifest → CLI → main
- All JSON read/write via `jq` — never `python3 -c "..."`
- NerdGraph payload: `jq -n --arg q "$query" '{"query": $q}'`
- Response parsing: `echo "$response" | jq '.data.actor...'`
- Array merge: use `json_merge_arrays` helper (jq -n --argjson approach)
- Log every export with counts: `log_ok "  Exported $count dashboards"`
- Use `log_debug` for paginated page counts (only shown with `--debug`)
- Retry HTTP failures: 3 attempts with exponential backoff (2s, 4s)
- 50ms sleep between paginated API calls (`sleep "$API_DELAY"`)

## Script Conventions (PowerShell)

- `[CmdletBinding()]` and typed parameters
- `Set-StrictMode -Version Latest`
- `Invoke-RestMethod` for HTTP (built-in)
- `Save-Json` helper for all file writes (handles array serialization edge cases)
- Match Bash flag names exactly (e.g., `-ApiKey`, `-Accounts`, `-All`, `-Region`)
- Produce structurally identical archive to Bash version
- Archive name: `dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz`

## NerdGraph API

- Endpoint US: `https://api.newrelic.com/graphql`
- Endpoint EU: `https://api.eu.newrelic.com/graphql`
- Auth header: `API-Key: <NRAK-...>`
- All queries: `POST` with `Content-Type: application/json`
- Body: `{"query": "<graphql query string>"}`
- Pagination field: `nextCursor` — loop until null
- Batch entity fetch: `actor.entities(guids: [...])` max 25 GUIDs per call (`$ENTITY_FETCH_BATCH`)

## Two-Phase Export Pattern

Most resource types follow this pattern:
1. **Phase 1** — `entitySearch(query: "type = 'TYPE' AND accountId = N")` to discover GUIDs (paginated via `nextCursor`)
2. **Phase 2** — `actor.entities(guids: [...])` batched in groups of 25 to fetch full details

For resources with direct account queries (alerts, service levels), use the account-scoped API directly and paginate with cursor.

## Adding a New Export Type

1. Add `export_<type>_for_account()` function (or global if cross-account)
2. Add flag constant and CLI argument (`--<type>`, `-Type`)
3. Call from `main()` with guard: `[[ "$EXPORT_TYPE" == "true" ]] && export_type_for_account "$account_id"`
4. Update `generate_manifest()` to count new resource
5. Update `generate_summary()` to include in per-account stats
6. Mirror in PowerShell script
7. Document in `CHANGELOG.md`

## Common Tasks

```bash
# Test single account export (dashboards only, debug output)
./newrelic-export/dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "$NR_ACCOUNT_ID" \
  --dashboards --debug

# Full export with all optional data
./newrelic-export/dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "$NR_ACCOUNT_ID" \
  --all --rbac --usage

# EU region
./newrelic-export/dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "$NR_ACCOUNT_ID" \
  --all --region EU
```
