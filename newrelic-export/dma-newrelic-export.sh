#!/bin/bash
# LINE ENDING FIX: Auto-detect and fix Windows CRLF line endings
# If you see "$'\r': command not found" errors, this block will auto-fix and re-run
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && grep -q $'\r' "$0" 2>/dev/null; then
    echo "Detected Windows line endings (CRLF). Converting to Unix (LF)..."
    sed -i.bak 's/\r$//' "$0" && rm -f "$0.bak"
    exec bash "$0" "$@"
fi

################################################################################
#
#  DMA New Relic Export Script
#
#  Version: v1.3.8            Released: 2026-11-07
#
#  (This line and the SCRIPT_VERSION constant are checked against each other at
#   startup — if they ever disagree the script says so on stderr. The banner
#   silently drifted once, showing v1.3.3 while the script actually ran v1.3.4.)
#
#  NerdGraph GraphQL Data Collection for New Relic to Dynatrace Migration
#
#  This script collects dashboards, alert policies, NRQL conditions, synthetic
#  monitors, workloads, service level indicators, and usage analytics from your
#  New Relic accounts via the NerdGraph GraphQL API to enable migration planning
#  and execution using the DMA (Dynatrace Migration Assistant) application.
#
#  As of v1.2.0 it also captures 8 supplemental object types (formerly in
#  nr-supplemental-export.sh, now folded in): AI workflows, AI notification
#  destinations, alert muting rules, NRQL drop rules, log parsing rules,
#  lookup tables, events-to-metrics rules, and entity tags. These land in
#  account_<id>/supplemental/ inside the same single tarball + manifest.
#
################################################################################
#
#  ╔═══════════════════════════════════════════════════════════════════════════╗
#  ║                    PRE-FLIGHT CHECKLIST (NEW RELIC)                        ║
#  ╠═══════════════════════════════════════════════════════════════════════════╣
#  ║                                                                           ║
#  ║  BEFORE RUNNING THIS SCRIPT, VERIFY THE FOLLOWING:                        ║
#  ║                                                                           ║
#  ║  □ 1. SYSTEM REQUIREMENTS (your local machine)                            ║
#  ║     □ bash 3.2+        Run: bash --version (works on macOS default bash) ║
#  ║     □ curl installed   Run: curl --version                                ║
#  ║     □ jq installed     Run: jq --version (for JSON processing)            ║
#  ║       └─ Install: brew install jq (macOS) or apt-get install jq (Linux)  ║
#  ║     □ tar installed    Run: tar --version                                 ║
#  ║     □ Internet access to NerdGraph API endpoint                           ║
#  ║                                                                           ║
#  ║  □ 2. NEW RELIC API KEY                                                   ║
#  ║     □ User API Key (NRAK-...)                                             ║
#  ║       └─ Generate at: Account Settings → API keys → Create a key         ║
#  ║       └─ Key type: User key (NOT Ingest - License key)                   ║
#  ║       └─ Role: Full Platform Access or Admin                              ║
#  ║                                                                           ║
#  ║  □ 3. NEW RELIC REGION                                                    ║
#  ║     Choose your New Relic data center:                                    ║
#  ║     □ US (default)     api.newrelic.com/graphql                           ║
#  ║     □ EU               api.eu.newrelic.com/graphql                        ║
#  ║                                                                           ║
#  ║  □ 4. ACCOUNT IDs                                                         ║
#  ║     □ One or more New Relic account IDs (e.g. 1234567)                   ║
#  ║       └─ Find at: Account Settings → Account ID                           ║
#  ║       └─ Or omit --accounts to auto-discover all accessible accounts     ║
#  ║                                                                           ║
#  ║  □ 5. NETWORK CONNECTIVITY TEST                                           ║
#  ║     Run this command to verify connectivity and key validity:             ║
#  ║                                                                           ║
#  ║     curl -s -X POST https://api.newrelic.com/graphql \                   ║
#  ║       -H "Content-Type: application/json" \                               ║
#  ║       -H "API-Key: NRAK-your-key-here" \                                  ║
#  ║       -d '{"query":"{ actor { user { name email } } }"}' | jq .          ║
#  ║                                                                           ║
#  ║     Expected: JSON response with your user name and email                 ║
#  ║     If you get errors: Check API key type and permissions                 ║
#  ║                                                                           ║
#  ║  □ 6. NEW RELIC RATE LIMITS (be aware)                                    ║
#  ║     □ NerdGraph: ~25 concurrent requests, ~3000/min per IP               ║
#  ║     □ Script uses 50ms delay between paginated calls                     ║
#  ║     □ Automatic retry with exponential backoff on failures               ║
#  ║     □ Large accounts with many dashboards may take 5-20 minutes          ║
#  ║                                                                           ║
#  ╚═══════════════════════════════════════════════════════════════════════════╝
#
#  QUICK START:
#    ./dma-newrelic-export.sh \
#      --api-key "NRAK-XXXXXXXXXXXXXXXXXXXX" \
#      --accounts "1234567" \
#      --all
#
#  NON-INTERACTIVE (automation):
#    ./dma-newrelic-export.sh \
#      --api-key "$NR_API_KEY" \
#      --accounts "$NR_ACCOUNT_IDS" \
#      --all --output-dir /path/to/export
#
################################################################################

set -o pipefail  # Fail on pipe errors (not set -e — we handle errors gracefully)

# =============================================================================
# SCRIPT CONFIGURATION
# =============================================================================

readonly SCRIPT_VERSION="1.3.8"

# Banner/constant drift guard. The header comment is what a human reads when
# they open this file, so it must not silently disagree with what actually runs
# (it did: the banner said v1.3.3 for the whole v1.3.4 release). Non-fatal by
# design — a version mismatch must never block a customer's export.
if [[ -r "${BASH_SOURCE[0]}" ]]; then
    _banner_version=$(grep -m1 -E '^#[[:space:]]+Version:[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+' "${BASH_SOURCE[0]}" 2>/dev/null \
        | sed -E 's/.*[Vv]ersion:[[:space:]]*v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
    if [[ -n "$_banner_version" && "$_banner_version" != "$SCRIPT_VERSION" ]]; then
        echo "WARNING: header banner says v${_banner_version} but this script runs v${SCRIPT_VERSION}." >&2
        echo "         The banner is stale — update it. Exports are unaffected." >&2
    fi
    unset _banner_version
fi
readonly SCHEMA_VERSION="1.0"
readonly SCRIPT_NAME="DMA New Relic Export"
readonly SCRIPT_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
readonly SCRIPT_START_EPOCH="$(date +%s)"

readonly API_ENDPOINT_US="https://api.newrelic.com/graphql"
readonly API_ENDPOINT_EU="https://api.eu.newrelic.com/graphql"
readonly API_RETRY_COUNT=3
readonly API_DELAY="0.05"
# NerdGraph actor.entities(guids:) accepts up to 25 GUIDs per call
readonly ENTITY_FETCH_BATCH=25

# =============================================================================
# ANSI COLOR CODES
# =============================================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
GRAY=$'\033[0;90m'
NC=$'\033[0m'
BOLD=$'\033[1m'

BOX_TL="╔"; BOX_TR="╗"; BOX_BL="╚"; BOX_BR="╝"
BOX_H="═"; BOX_V="║"; BOX_T="╠"; BOX_B="╣"

# =============================================================================
# GLOBAL STATE
# =============================================================================

API_KEY=""
ACCOUNT_IDS=()
REGION="US"
REGION_EXPLICIT=false
GRAPHQL_ENDPOINT="$API_ENDPOINT_US"
OUTPUT_DIR=""
LOG_FILE="/dev/null"

EXPORT_DASHBOARDS=false
EXPORT_ALERTS=false
EXPORT_SYNTHETICS=false
EXPORT_WORKLOADS=false
EXPORT_SERVICE_LEVELS=false
INCLUDE_RBAC=false
INCLUDE_USAGE=false
ANONYMIZE=false
DEBUG=false

# Supplemental object-type toggles (folded in from nr-supplemental-export.sh
# v0.2.0 in v1.2.0). Default FALSE — opt in exactly like the core types:
# `--all` enables them along with everything else, `--supplemental` enables the
# whole group, or `--<type>` enables one. (`--no-<type>` / `--no-supplemental`
# subtract from `--all`.) The data lands in account_<id>/supplemental/ and is
# included in the single tarball.
EXPORT_AI_WORKFLOWS=false
EXPORT_AI_DESTINATIONS=false
EXPORT_MUTING_RULES=false
EXPORT_DROP_RULES=false
EXPORT_LOG_CONFIGS=false
EXPORT_LOOKUP_TABLES=false
EXPORT_EVENTS_TO_METRICS=false
EXPORT_ENTITY_TAGS=false

# entitySearch tag filter for export_entity_tags (ported from supplemental).
ENTITY_TAG_KEY="team"
ENTITY_TAG_VALUE="migration"

# =============================================================================
# LOGGING
# =============================================================================

load_env_file_if_present() {
  local script_dir repo_env cwd_env dotenv_file=""
  local had_user_api=false had_account_id=false had_region=false
  local old_user_api="" old_account_id="" old_region=""

  if [[ -n "${NEW_RELIC_USER_API_KEY+x}" ]]; then
        had_user_api=true
        old_user_api="$NEW_RELIC_USER_API_KEY"
  fi
  if [[ -n "${NEW_RELIC_ACCOUNT_ID+x}" ]]; then
        had_account_id=true
        old_account_id="$NEW_RELIC_ACCOUNT_ID"
  fi
  if [[ -n "${NEW_RELIC_REGION+x}" ]]; then
        had_region=true
        old_region="$NEW_RELIC_REGION"
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_env="$script_dir/../.env"
  cwd_env="$PWD/.env"

  if [[ -f "$cwd_env" ]]; then
        dotenv_file="$cwd_env"
  elif [[ -f "$repo_env" ]]; then
        dotenv_file="$repo_env"
  fi

  if [[ -n "$dotenv_file" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$dotenv_file"
        set +a

        # Preserve caller-provided env values over .env defaults.
        if [[ "$had_user_api" == "true" ]]; then
            export NEW_RELIC_USER_API_KEY="$old_user_api"
        fi
        if [[ "$had_account_id" == "true" ]]; then
            export NEW_RELIC_ACCOUNT_ID="$old_account_id"
        fi
        if [[ "$had_region" == "true" ]]; then
            export NEW_RELIC_REGION="$old_region"
        fi
  fi
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

print_color() {
    local color=$1; shift
    echo -e "${color}$*${NC}"
}

print_header() {
    local text="$1"
    local width=78
    local padding=$(( (width - ${#text} - 2) / 2 ))
    echo ""
    echo -e "${CYAN}${BOX_TL}$(printf '%*s' $width '' | tr ' ' "${BOX_H}")${BOX_TR}${NC}"
    printf "${CYAN}${BOX_V}${NC}%*s${BOLD}${WHITE}%s${NC}%*s${CYAN}${BOX_V}${NC}\n" \
           $padding "" "$text" $padding ""
    echo -e "${CYAN}${BOX_BL}$(printf '%*s' $width '' | tr ' ' "${BOX_H}")${BOX_BR}${NC}"
    echo ""
}

# All log_* functions write screen output to stderr so that helper
# functions like nerdgraph_query (called via $()) don't have log lines
# captured into the JSON payload returned to the caller.
log_info()  {
    local msg="[$(date -u +"%H:%M:%S")] [INFO]  $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    print_color "$BLUE" "  ℹ $*" >&2
}
log_ok()    {
    local msg="[$(date -u +"%H:%M:%S")] [OK]    $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    print_color "$GREEN" "  ✓ $*" >&2
}
log_warn()  {
    local msg="[$(date -u +"%H:%M:%S")] [WARN]  $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    print_color "$YELLOW" "  ⚠ $*" >&2
}
log_error() {
    local msg="[$(date -u +"%H:%M:%S")] [ERROR] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    print_color "$RED" "  ✗ $*" >&2
}
log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        local msg="[$(date -u +"%H:%M:%S")] [DEBUG] $*"
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
        print_color "$GRAY" "    [DEBUG] $*" >&2
    fi
}

# =============================================================================
# PREREQUISITE CHECK
# =============================================================================

check_prerequisites() {
    local missing=()
    for cmd in curl jq tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo ""
        echo "  Install jq:"
        echo "    macOS:  brew install jq"
        echo "    Linux:  sudo apt-get install jq   OR   sudo yum install jq"
        exit 1
    fi
}

# =============================================================================
# API HELPERS
# =============================================================================

# Execute a NerdGraph query with retry logic. Prints JSON response body to stdout.
nerdgraph_query() {
    local query="$1"
    local attempt=0

    local payload
    payload=$(jq -n --arg q "$query" '{"query": $q}')

    while [[ $attempt -lt $API_RETRY_COUNT ]]; do
        local response http_code body

        response=$(curl -s \
            --write-out "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "API-Key: $API_KEY" \
            --data "$payload" \
            "$GRAPHQL_ENDPOINT" 2>>"$LOG_FILE") || true

        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        case "$http_code" in
            200)
                local has_errors
                has_errors=$(echo "$body" | jq 'if .errors and (.errors | length > 0) then "true" else "false" end' -r 2>/dev/null || echo "true")
                if [[ "$has_errors" == "false" ]]; then
                    echo "$body"
                    return 0
                fi
                log_warn "GraphQL errors (attempt $((attempt+1))/$API_RETRY_COUNT)"
                log_debug "Response: $body"
                ;;
            401)
                log_error "Authentication failed (HTTP 401). Verify your --api-key."
                echo "{}"; return 1 ;;
            403)
                log_error "Permission denied (HTTP 403). Ensure the API key has Full Platform Access."
                echo "{}"; return 1 ;;
            000)
                log_warn "Network error — could not reach $GRAPHQL_ENDPOINT (attempt $((attempt+1))/$API_RETRY_COUNT)"
                ;;
            *)
                log_warn "HTTP $http_code (attempt $((attempt+1))/$API_RETRY_COUNT)"
                ;;
        esac

        attempt=$((attempt + 1))
        if [[ $attempt -lt $API_RETRY_COUNT ]]; then
            local sleep_secs=$((2 ** attempt))
            log_warn "Retrying in ${sleep_secs}s..."
            sleep "$sleep_secs"
        fi
    done

    log_error "API request failed after $API_RETRY_COUNT attempts"
    echo "{}"
    return 1
}

# Execute a NerdGraph query that takes GraphQL variables. This is the
# variables-capable sibling of nerdgraph_query() above — ported from
# nr-supplemental-export.sh v0.2.0 so the 8 supplemental extractors can pass
# parameterized queries (e.g. `query ($id: Int!){...}`). It reuses the
# primary's endpoint ($GRAPHQL_ENDPOINT), constants, and logging. The primary's
# original single-arg nerdgraph_query() is intentionally left untouched (it is
# the live export path). Prints the JSON response body to stdout.
nerdgraph_query_vars() {
    local query="$1"
    local variables="$2"
    # bash parameter-expansion default of `{}` collides with brace expansion;
    # use an explicit check instead.
    [[ -z "$variables" ]] && variables='{}'

    local payload
    payload=$(jq -nc --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')

    local attempt=0
    while [[ $attempt -lt $API_RETRY_COUNT ]]; do
        local response http_code body

        response=$(curl -s \
            --write-out "\n%{http_code}" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "API-Key: $API_KEY" \
            --data "$payload" \
            "$GRAPHQL_ENDPOINT" 2>>"$LOG_FILE") || true

        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        case "$http_code" in
            200)
                local has_errors
                has_errors=$(echo "$body" | jq 'if .errors and (.errors | length > 0) then "true" else "false" end' -r 2>/dev/null || echo "true")
                if [[ "$has_errors" == "false" ]]; then
                    echo "$body"
                    return 0
                fi
                log_warn "GraphQL errors (attempt $((attempt+1))/$API_RETRY_COUNT)"
                log_debug "Response: $body"
                # On the final attempt, emit the body (callers may log it for
                # diagnosis) but return 1 so hard failures are never silent.
                if [[ $((attempt + 1)) -ge $API_RETRY_COUNT ]]; then
                    echo "$body"
                    return 1
                fi
                ;;
            401)
                log_error "Authentication failed (HTTP 401). Verify your --api-key."
                echo "{}"; return 1 ;;
            403)
                log_error "Permission denied (HTTP 403). Ensure the API key has Full Platform Access."
                echo "{}"; return 1 ;;
            000)
                log_warn "Network error — could not reach $GRAPHQL_ENDPOINT (attempt $((attempt+1))/$API_RETRY_COUNT)"
                ;;
            *)
                log_warn "HTTP $http_code (attempt $((attempt+1))/$API_RETRY_COUNT)"
                ;;
        esac

        attempt=$((attempt + 1))
        if [[ $attempt -lt $API_RETRY_COUNT ]]; then
            local sleep_secs=$((2 ** attempt))
            log_warn "Retrying in ${sleep_secs}s..."
            sleep "$sleep_secs"
        fi
    done

    log_error "API request failed after $API_RETRY_COUNT attempts"
    echo "{}"
    return 1
}

# Wraps `actor.account(id: $id) { ... }` around a body — saves repeating the
# scaffolding for the parameterized supplemental queries. Pure string builder
# (the account_id arg is accepted for call-site symmetry but the value is
# bound at request time via the GraphQL $id variable). Ported verbatim from
# nr-supplemental-export.sh.
account_scoped_query() {
    local account_id="$1"
    local body="$2"
    echo "query (\$id: Int!) { actor { account(id: \$id) { $body } } }"
}

# Merge a JSON array ($2) into an existing array ($1) and print the result
json_merge_arrays() {
    # `--argjson` passes values via command-line argv, which is bounded
    # by ARG_MAX (~256KB on Linux, ~1MB on macOS). Real-world dashboard
    # exports can return per-batch payloads of several MB once
    # widget rawConfiguration is included, blowing past ARG_MAX. The
    # original implementation silently fell through to `echo "$1"` —
    # producing empty exports for accounts with non-trivial dashboards.
    # Pipe both arrays via stdin (jq -s slurps consecutive JSON values
    # into an array, then `add` concatenates) — no command-line size
    # limit. Same fallback semantics: return arg1 unchanged on jq error.
    printf '%s\n%s\n' "$1" "$2" | jq -s 'add' 2>/dev/null || echo "$1"
}

# Count elements in a JSON array stored in a file
count_json_array_file() {
    jq 'length' "$1" 2>/dev/null || echo 0
}

# =============================================================================
# ACCOUNT DISCOVERY
# =============================================================================

export_accounts() {
    log_info "Exporting account information..."
    mkdir -p "$OUTPUT_DIR/_systeminfo"

    local response
    response=$(nerdgraph_query '{ actor { accounts { id name } } }')

    echo "$response" | jq '.data.actor.accounts // []' > "$OUTPUT_DIR/_systeminfo/accounts.json" 2>/dev/null \
        || echo "[]" > "$OUTPUT_DIR/_systeminfo/accounts.json"

    local count
    count=$(count_json_array_file "$OUTPUT_DIR/_systeminfo/accounts.json")
    log_ok "Exported $count accounts"
}

discover_account_ids() {
    log_info "Discovering accessible accounts..."
    local response
    response=$(nerdgraph_query '{ actor { accounts { id name } } }')

    local ids_str
    ids_str=$(echo "$response" | jq -r '[.data.actor.accounts[].id] | @sh' 2>/dev/null | tr -d "'")

    if [[ -z "$ids_str" ]]; then
        log_error "Could not discover accounts. Verify your API key has account access."
        exit 1
    fi

    read -ra ACCOUNT_IDS <<< "$ids_str"
    log_info "  Discovered accounts: ${ACCOUNT_IDS[*]}"
}

# =============================================================================
# DASHBOARDS
# =============================================================================

export_dashboards_for_account() {
    local account_id="$1"
    local out_dir="$OUTPUT_DIR/account_${account_id}/dashboards"
    mkdir -p "$out_dir"

    log_info "  [Account $account_id] Exporting dashboards..."

    # Phase 1 — discover GUIDs via entitySearch (Outline types)
    local cursor="null"
    local all_guids="[]"
    local page=1

    while true; do
        # NerdGraph takes the pagination cursor on the nested `results` field,
        # NOT on `entitySearch(...)`. Passing it to entitySearch is silently
        # ineffective: page 2 is never fetched and the export truncates at one
        # page (200 entities) with no error. See CHANGELOG v1.3.5.
        local cursor_arg=""
        [[ "$cursor" != "null" ]] && cursor_arg="(cursor: $cursor)"

        local query
        query=$(cat <<GRAPHQL
{
  actor {
    entitySearch(query: "type = 'DASHBOARD' AND accountId = ${account_id}") {
      results${cursor_arg} {
        entities {
          ... on DashboardEntityOutline { guid }
        }
        nextCursor
      }
    }
  }
}
GRAPHQL
)
        local response
        if ! response=$(nerdgraph_query "$query"); then
            log_error "  [Account $account_id] Dashboard entitySearch failed after retries (page $page) — export is INCOMPLETE"
            break
        fi

        local page_guids next_cursor
        page_guids=$(echo "$response" | jq '[.data.actor.entitySearch.results.entities[].guid // empty]' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.actor.entitySearch.results.nextCursor' 2>/dev/null || echo "null")

        local page_count
        page_count=$(echo "$page_guids" | jq 'length' 2>/dev/null || echo 0)
        log_debug "    Page $page: $page_count dashboard GUIDs"

        all_guids=$(json_merge_arrays "$all_guids" "$page_guids")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        page=$((page + 1))
        sleep "$API_DELAY"
    done

    # Phase 2 — batch-fetch full entity details
    local guid_count
    guid_count=$(echo "$all_guids" | jq 'length' 2>/dev/null || echo 0)
    log_debug "    Phase 1 complete: $guid_count dashboard GUIDs"

    local all_entities="[]"
    local start=0 batch_num=1
    while [[ $start -lt $guid_count ]]; do
        local guids_literal
        guids_literal=$(echo "$all_guids" | jq ".[${start}:$((start + ENTITY_FETCH_BATCH))]" 2>/dev/null || echo "[]")

        local detail_query
        detail_query=$(cat <<GRAPHQL
{
  actor {
    entities(guids: ${guids_literal}) {
      ... on DashboardEntity {
        guid name description accountId createdAt updatedAt permissions
        owner { email userId }
        variables {
          name title type isMultiSelection replacementStrategy
          defaultValues { value { string } }
          items { title value }
          nrqlQuery { accountIds query }
          options { excluded hiddenOnVariablesBar ignoreTimeRange showApplyAction }
        }
        pages {
          guid name description
          widgets {
            id title
            layout { row column height width }
            visualization { id }
            rawConfiguration
          }
        }
        tags { key values }
      }
    }
  }
}
GRAPHQL
)
        local detail_response
        detail_response=$(nerdgraph_query "$detail_query")

        local batch_entities
        batch_entities=$(echo "$detail_response" | jq '[.data.actor.entities[] | select(. != null and .guid != null)]' 2>/dev/null || echo "[]")
        local batch_count
        batch_count=$(echo "$batch_entities" | jq 'length' 2>/dev/null || echo 0)
        log_debug "    Batch $batch_num: fetched $batch_count dashboard details"

        all_entities=$(json_merge_arrays "$all_entities" "$batch_entities")

        start=$((start + ENTITY_FETCH_BATCH))
        batch_num=$((batch_num + 1))
        sleep "$API_DELAY"
    done

    echo "$all_entities" | jq '.' > "$out_dir/dashboards.json" 2>/dev/null || echo "[]" > "$out_dir/dashboards.json"

    local total
    total=$(count_json_array_file "$out_dir/dashboards.json")
    log_ok "  [Account $account_id] Exported $total dashboards"
}

# =============================================================================
# ALERTS
# =============================================================================

export_alerts_for_account() {
    local account_id="$1"
    local out_dir="$OUTPUT_DIR/account_${account_id}/alerts"
    mkdir -p "$out_dir"

    log_info "  [Account $account_id] Exporting alert policies..."

    # --- Policies ---
    local cursor="null"
    local all_policies="[]"

    while true; do
        local search_args=""
        [[ "$cursor" != "null" ]] && search_args="(cursor: $cursor)"

        local query
        query=$(cat <<GRAPHQL
{
  actor {
    account(id: ${account_id}) {
      alerts {
        policiesSearch${search_args} {
          policies { id name incidentPreference }
          nextCursor
        }
      }
    }
  }
}
GRAPHQL
)
        local response
        response=$(nerdgraph_query "$query")

        local page_items next_cursor
        page_items=$(echo "$response" | jq '.data.actor.account.alerts.policiesSearch.policies // []' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.actor.account.alerts.policiesSearch.nextCursor' 2>/dev/null || echo "null")

        all_policies=$(json_merge_arrays "$all_policies" "$page_items")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        sleep "$API_DELAY"
    done

    echo "$all_policies" | jq '.' > "$out_dir/policies.json" 2>/dev/null || echo "[]" > "$out_dir/policies.json"
    local policy_count
    policy_count=$(count_json_array_file "$out_dir/policies.json")
    log_ok "  [Account $account_id] Exported $policy_count alert policies"

    # --- NRQL Conditions ---
    log_info "  [Account $account_id] Exporting NRQL alert conditions..."
    cursor="null"
    local all_conditions="[]"

    while true; do
        local search_args=""
        [[ "$cursor" != "null" ]] && search_args="(cursor: $cursor)"

        local query
        query=$(cat <<GRAPHQL
{
  actor {
    account(id: ${account_id}) {
      alerts {
        nrqlConditionsSearch${search_args} {
          nrqlConditions {
            id name description enabled entityGuid policyId
            type runbookUrl violationTimeLimitSeconds
            nrql { query }
            terms { threshold thresholdDuration thresholdOccurrences operator priority }
            signal {
              aggregationWindow aggregationMethod aggregationDelay aggregationTimer
              fillOption fillValue slideBy evaluationDelay
            }
            expiration {
              closeViolationsOnExpiration
              expirationDuration
              openViolationOnExpiration
            }
            ... on AlertsNrqlBaselineCondition { baselineDirection }
            ... on AlertsNrqlOutlierCondition { expectedGroups openViolationOnGroupOverlap }
          }
          nextCursor
        }
      }
    }
  }
}
GRAPHQL
)
        local response
        response=$(nerdgraph_query "$query")

        local page_items next_cursor
        page_items=$(echo "$response" | jq '.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions // []' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.actor.account.alerts.nrqlConditionsSearch.nextCursor' 2>/dev/null || echo "null")

        all_conditions=$(json_merge_arrays "$all_conditions" "$page_items")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        sleep "$API_DELAY"
    done

    echo "$all_conditions" | jq '.' > "$out_dir/nrql_conditions.json" 2>/dev/null || echo "[]" > "$out_dir/nrql_conditions.json"
    local condition_count
    condition_count=$(count_json_array_file "$out_dir/nrql_conditions.json")
    log_ok "  [Account $account_id] Exported $condition_count NRQL alert conditions"

    # --- Notification Channels ---
    log_info "  [Account $account_id] Exporting notification channels..."

    local query
    query=$(cat <<GRAPHQL
{
  actor {
    account(id: ${account_id}) {
      aiNotifications {
        destinations {
          entities { id name type status isUserAuthenticated
            properties { key value }
          }
        }
        channels {
          entities { id name type destinationId product status }
        }
      }
    }
  }
}
GRAPHQL
)
    local response
    response=$(nerdgraph_query "$query")

    echo "$response" | jq '{
      destinations: (.data.actor.account.aiNotifications.destinations.entities // []),
      channels:     (.data.actor.account.aiNotifications.channels.entities // [])
    }' > "$out_dir/notification_channels.json" 2>/dev/null \
        || echo '{"destinations":[],"channels":[]}' > "$out_dir/notification_channels.json"

    local dest_count channel_count
    dest_count=$(jq '.destinations | length' "$out_dir/notification_channels.json" 2>/dev/null || echo 0)
    channel_count=$(jq '.channels | length' "$out_dir/notification_channels.json" 2>/dev/null || echo 0)
    log_ok "  [Account $account_id] Exported $dest_count destinations, $channel_count channels"
}

# =============================================================================
# SYNTHETIC MONITORS
# =============================================================================

export_synthetics_for_account() {
    local account_id="$1"
    local out_dir="$OUTPUT_DIR/account_${account_id}/synthetics"
    mkdir -p "$out_dir"

    log_info "  [Account $account_id] Exporting synthetic monitors..."

    # Phase 1 — discover GUIDs
    local cursor="null"
    local all_guids="[]"
    local page=1

    while true; do
        # Cursor belongs on `results`, not on `entitySearch` — see the dashboard
        # collector above and CHANGELOG v1.3.5.
        local cursor_arg=""
        [[ "$cursor" != "null" ]] && cursor_arg="(cursor: $cursor)"

        local query
        query=$(cat <<GRAPHQL
{
  actor {
    entitySearch(query: "type = 'MONITOR' AND accountId = ${account_id}") {
      results${cursor_arg} {
        entities {
          ... on SyntheticMonitorEntityOutline { guid }
        }
        nextCursor
      }
    }
  }
}
GRAPHQL
)
        local response
        if ! response=$(nerdgraph_query "$query"); then
            log_error "  [Account $account_id] Synthetic monitor entitySearch failed after retries (page $page) — export is INCOMPLETE"
            break
        fi

        local page_guids next_cursor
        page_guids=$(echo "$response" | jq '[.data.actor.entitySearch.results.entities[].guid // empty]' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.actor.entitySearch.results.nextCursor' 2>/dev/null || echo "null")

        log_debug "    Page $page: $(echo "$page_guids" | jq 'length' 2>/dev/null || echo 0) monitor GUIDs"

        all_guids=$(json_merge_arrays "$all_guids" "$page_guids")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        page=$((page + 1))
        sleep "$API_DELAY"
    done

    # Phase 2 — batch-fetch full details
    local guid_count
    guid_count=$(echo "$all_guids" | jq 'length' 2>/dev/null || echo 0)
    log_debug "    Phase 1 complete: $guid_count monitor GUIDs"

    local all_monitors="[]"
    local start=0 batch_num=1
    while [[ $start -lt $guid_count ]]; do
        local guids_literal
        guids_literal=$(echo "$all_guids" | jq ".[${start}:$((start + ENTITY_FETCH_BATCH))]" 2>/dev/null || echo "[]")

        local detail_query
        detail_query=$(cat <<GRAPHQL
{
  actor {
    entities(guids: ${guids_literal}) {
      ... on SyntheticMonitorEntity {
        guid name accountId monitorType period monitoredUrl
        monitorSummary { status locationsRunning locationsFailing successRate }
        tags { key values }
      }
    }
  }
}
GRAPHQL
)
        local detail_response
        detail_response=$(nerdgraph_query "$detail_query")

        local batch_items
        batch_items=$(echo "$detail_response" | jq '[.data.actor.entities[] | select(. != null and .guid != null)]' 2>/dev/null || echo "[]")
        local batch_count
        batch_count=$(echo "$batch_items" | jq 'length' 2>/dev/null || echo 0)
        log_debug "    Batch $batch_num: fetched $batch_count monitor details"

        all_monitors=$(json_merge_arrays "$all_monitors" "$batch_items")

        start=$((start + ENTITY_FETCH_BATCH))
        batch_num=$((batch_num + 1))
        sleep "$API_DELAY"
    done

    # NerdGraph's SyntheticMonitorEntity has no dedicated locations field — a
    # monitor's run locations appear ONLY as tags, under two different keys:
    #   publicLocation  — NR-hosted, e.g. "Washington, DC, USA"
    #   privateLocation — customer-hosted minion, e.g. "USFOODS Prod"
    # Lift BOTH into a `locations: [{label, type}, ...]` array so the converter's
    # `monitor.locations.map(l => l.label)` (see dma-newrelic-converter's
    # SyntheticConverter.ts:50) has something to read.
    #
    # v1.3.4 read publicLocation only, which looked correct on test accounts but
    # missed 537 of 616 monitors on real customer data — every one of them was
    # private-location-only. Public first, then private (a monitor can carry
    # both; one real example does).
    #
    # `type` is additive and exists because the two are NOT interchangeable
    # downstream: a public label can be remapped to a Dynatrace public location
    # at publish time (SyntheticApiMapper.ts), but a private NR location names a
    # customer-hosted minion with no Dynatrace public equivalent — it has to be
    # mapped to a DT private synthetic location the customer selects. Existing
    # consumers that only read `.label` are unaffected.
    echo "$all_monitors" | jq '
        map(. + {
            locations: (
                  [(.tags // [])[] | select(.key == "publicLocation")  | .values[]? | {label: ., type: "public"}]
                + [(.tags // [])[] | select(.key == "privateLocation") | .values[]? | {label: ., type: "private"}]
            )
        })
    ' > "$out_dir/monitors.json" 2>/dev/null || echo "[]" > "$out_dir/monitors.json"
    local total
    total=$(count_json_array_file "$out_dir/monitors.json")
    log_ok "  [Account $account_id] Exported $total synthetic monitors"
}

# =============================================================================
# WORKLOADS
# =============================================================================

export_workloads_for_account() {
    local account_id="$1"
    local out_dir="$OUTPUT_DIR/account_${account_id}/workloads"
    mkdir -p "$out_dir"

    log_info "  [Account $account_id] Exporting workloads..."

    # Phase 1 — discover GUIDs
    local cursor="null"
    local all_guids="[]"
    local page=1

    while true; do
        # Cursor belongs on `results`, not on `entitySearch` — see the dashboard
        # collector above and CHANGELOG v1.3.5.
        local cursor_arg=""
        [[ "$cursor" != "null" ]] && cursor_arg="(cursor: $cursor)"

        local query
        query=$(cat <<GRAPHQL
{
  actor {
    entitySearch(query: "type = 'WORKLOAD' AND accountId = ${account_id}") {
      results${cursor_arg} {
        entities {
          ... on WorkloadEntityOutline { guid }
        }
        nextCursor
      }
    }
  }
}
GRAPHQL
)
        local response
        if ! response=$(nerdgraph_query "$query"); then
            log_error "  [Account $account_id] Workload entitySearch failed after retries (page $page) — export is INCOMPLETE"
            break
        fi

        local page_guids next_cursor
        page_guids=$(echo "$response" | jq '[.data.actor.entitySearch.results.entities[].guid // empty]' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.actor.entitySearch.results.nextCursor' 2>/dev/null || echo "null")

        log_debug "    Page $page: $(echo "$page_guids" | jq 'length' 2>/dev/null || echo 0) workload GUIDs"

        all_guids=$(json_merge_arrays "$all_guids" "$page_guids")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        page=$((page + 1))
        sleep "$API_DELAY"
    done

    # Phase 2 — batch-fetch full details
    local guid_count
    guid_count=$(echo "$all_guids" | jq 'length' 2>/dev/null || echo 0)
    log_debug "    Phase 1 complete: $guid_count workload GUIDs"

    local all_workloads="[]"
    local start=0 batch_num=1
    while [[ $start -lt $guid_count ]]; do
        local guids_literal
        guids_literal=$(echo "$all_guids" | jq ".[${start}:$((start + ENTITY_FETCH_BATCH))]" 2>/dev/null || echo "[]")

        local detail_query
        detail_query=$(cat <<GRAPHQL
{
  actor {
    entities(guids: ${guids_literal}) {
      ... on WorkloadEntity {
        guid name accountId createdAt updatedAt permalink
        tags { key values }
      }
    }
  }
}
GRAPHQL
)
        local detail_response
        detail_response=$(nerdgraph_query "$detail_query")

        local batch_items
        batch_items=$(echo "$detail_response" | jq '[.data.actor.entities[] | select(. != null and .guid != null)]' 2>/dev/null || echo "[]")
        local batch_count
        batch_count=$(echo "$batch_items" | jq 'length' 2>/dev/null || echo 0)
        log_debug "    Batch $batch_num: fetched $batch_count workload details"

        all_workloads=$(json_merge_arrays "$all_workloads" "$batch_items")

        start=$((start + ENTITY_FETCH_BATCH))
        batch_num=$((batch_num + 1))
        sleep "$API_DELAY"
    done

    # Phase 3 — workload definitions. WorkloadEntity carries only metadata; the
    # definition (entity queries, static members, status rules) lives on the
    # account's WorkloadCollection. Merged by guid into the converter's shape:
    # entitySearchQueries [{query}], entityGuids [guid], plus description,
    # scopeAccounts and statusConfig.
    if [[ "$guid_count" -gt 0 ]]; then
        local collections_query
        collections_query=$(cat <<GRAPHQL
{
  actor {
    account(id: ${account_id}) {
      workload {
        collections {
          guid description
          entitySearchQueries { query }
          entities { guid }
          scopeAccounts { accountIds }
          statusConfig {
            automatic {
              enabled
              remainingEntitiesRule { rollup { strategy thresholdType thresholdValue } }
              rules {
                entitySearchQueries { query }
                entities { guid }
                rollup { strategy thresholdType thresholdValue }
              }
            }
            static { description enabled status summary }
          }
        }
      }
    }
  }
}
GRAPHQL
)
        local collections_response collections
        if collections_response=$(nerdgraph_query "$collections_query") \
            && collections=$(echo "$collections_response" | jq -e '.data.actor.account.workload.collections | arrays' 2>/dev/null); then
            all_workloads=$(jq -n --argjson w "$all_workloads" --argjson c "$collections" '
                ($c | map({key: .guid, value: .}) | from_entries) as $byGuid
                | $w | map(. as $e | ($byGuid[$e.guid] // null) as $col
                    | if $col == null then $e else $e + {
                        description: $col.description,
                        entitySearchQueries: ($col.entitySearchQueries // []),
                        entityGuids: [($col.entities // [])[].guid],
                        scopeAccounts: $col.scopeAccounts,
                        statusConfig: $col.statusConfig
                      } end)' 2>/dev/null || echo "$all_workloads")
        else
            log_warn "  [Account $account_id] Workload definitions query failed — workloads exported WITHOUT entity queries or status rules"
        fi
    fi

    echo "$all_workloads" | jq '.' > "$out_dir/workloads.json" 2>/dev/null || echo "[]" > "$out_dir/workloads.json"
    local total
    total=$(count_json_array_file "$out_dir/workloads.json")
    log_ok "  [Account $account_id] Exported $total workloads"
}

# =============================================================================
# SERVICE LEVELS
# =============================================================================

export_service_levels_for_account() {
    local account_id="$1"
    local out_dir="$OUTPUT_DIR/account_${account_id}/service_levels"
    mkdir -p "$out_dir"

    log_info "  [Account $account_id] Exporting service level indicators..."

    # Service levels are entities (type = 'SERVICE_LEVEL', domain 'EXT') — the
    # entity itself IS the SLI. There is no Account.serviceLevel field; the
    # real path is entity.serviceLevel (ServiceLevelDefinition) → indicators
    # (a list of ServiceLevelIndicator, confirmed via NerdGraph introspection
    # 2026-07-06). Two-phase pattern matches dashboards/synthetics/workloads.

    # Phase 1 — discover GUIDs via entitySearch
    local cursor="null"
    local all_guids="[]"
    local page=1
    local query_failed=false

    while true; do
        # Cursor belongs on `results`, not on `entitySearch` — see the dashboard
        # collector above and CHANGELOG v1.3.5.
        local cursor_arg=""
        [[ "$cursor" != "null" ]] && cursor_arg="(cursor: $cursor)"

        local query
        query=$(cat <<GRAPHQL
{
  actor {
    entitySearch(query: "type = 'SERVICE_LEVEL' AND accountId = ${account_id}") {
      results${cursor_arg} {
        entities {
          ... on ExternalEntityOutline { guid }
        }
        nextCursor
      }
    }
  }
}
GRAPHQL
)
        local response
        if ! response=$(nerdgraph_query "$query"); then
            log_error "  [Account $account_id] Service level entitySearch failed after retries (page $page)"
            query_failed=true
            break
        fi

        local page_guids next_cursor
        page_guids=$(echo "$response" | jq '[.data.actor.entitySearch.results.entities[].guid // empty]' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.actor.entitySearch.results.nextCursor' 2>/dev/null || echo "null")

        log_debug "    Page $page: $(echo "$page_guids" | jq 'length' 2>/dev/null || echo 0) SLI GUIDs"

        all_guids=$(json_merge_arrays "$all_guids" "$page_guids")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        page=$((page + 1))
        sleep "$API_DELAY"
    done

    # Phase 2 — batch-fetch full indicator details
    local guid_count
    guid_count=$(echo "$all_guids" | jq 'length' 2>/dev/null || echo 0)
    log_debug "    Phase 1 complete: $guid_count SLI GUIDs"

    local all_indicators="[]"
    local start=0 batch_num=1
    while [[ "$query_failed" != "true" && $start -lt $guid_count ]]; do
        local guids_literal
        guids_literal=$(echo "$all_guids" | jq ".[${start}:$((start + ENTITY_FETCH_BATCH))]" 2>/dev/null || echo "[]")

        local detail_query
        detail_query=$(cat <<GRAPHQL
{
  actor {
    entities(guids: ${guids_literal}) {
      ... on ExternalEntity {
        guid
        serviceLevel {
          indicators {
            id name description guid entityGuid createdAt updatedAt
            events {
              validEvents { from where }
              goodEvents  { from where }
              badEvents   { from where }
            }
            objectives {
              name description target
              timeWindow { rolling { count unit } }
            }
          }
        }
      }
    }
  }
}
GRAPHQL
)
        local detail_response
        if ! detail_response=$(nerdgraph_query "$detail_query"); then
            log_error "  [Account $account_id] Service level indicator detail fetch failed after retries (batch $batch_num)"
            query_failed=true
            break
        fi

        local batch_items
        batch_items=$(echo "$detail_response" | jq '[.data.actor.entities[]? | select(. != null) | (.serviceLevel.indicators // [])[]]' 2>/dev/null || echo "[]")
        local batch_count
        batch_count=$(echo "$batch_items" | jq 'length' 2>/dev/null || echo 0)
        log_debug "    Batch $batch_num: fetched $batch_count SLI details"

        all_indicators=$(json_merge_arrays "$all_indicators" "$batch_items")

        start=$((start + ENTITY_FETCH_BATCH))
        batch_num=$((batch_num + 1))
        sleep "$API_DELAY"
    done

    echo "$all_indicators" | jq '.' > "$out_dir/indicators.json" 2>/dev/null || echo "[]" > "$out_dir/indicators.json"
    local total
    total=$(count_json_array_file "$out_dir/indicators.json")
    if [[ "$query_failed" == "true" ]]; then
        log_error "  [Account $account_id] Exported $total service level indicators (INCOMPLETE — query failed)"
        return 1
    fi
    log_ok "  [Account $account_id] Exported $total service level indicators"
}

# =============================================================================
# SUPPLEMENTAL OBJECT TYPES
# Folded in from nr-supplemental-export.sh v0.2.0 (v1.2.0). These 8 extractors
# capture the NR object types the core export above does not. Each keeps its
# original (account_id, outdir) signature and writes JSON into the supplemental
# directory; the only change from the standalone script is that they call
# nerdgraph_query_vars (variables-capable) instead of the standalone's
# nerdgraph_query. Each echoes its element count on stdout (logs go to stderr)
# so the account loop can collect counts for the manifest.
# =============================================================================

export_ai_workflows() {
    local account_id="$1" outdir="$2"
    log_info "  → aiWorkflows"
    local query
    query=$(account_scoped_query "$account_id" '
        aiWorkflows {
            workflows(filters: {}) {
                entities {
                    id
                    name
                    mutingRulesHandling
                    workflowEnabled
                    destinationsEnabled
                    issuesFilter {
                        id
                        name
                        type
                        predicates {
                            attribute
                            operator
                            values
                        }
                    }
                    destinationConfigurations {
                        channelId
                        name
                        type
                    }
                    enrichments {
                        id
                        name
                        configurations {
                            ... on AiWorkflowsNrqlConfiguration { query }
                        }
                    }
                    createdAt
                    updatedAt
                }
                nextCursor
                totalCount
            }
        }
    ')
    local vars
    vars=$(jq -nc --argjson id "$account_id" '{id: $id}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.account.aiWorkflows.workflows' \
        > "$outdir/aiWorkflows.json"
    local count
    count=$(jq '.totalCount // (.entities | length) // 0' "$outdir/aiWorkflows.json")
    log_ok "    aiWorkflows: ${count} workflows"
    echo "$count"
}

export_ai_destinations() {
    local account_id="$1" outdir="$2"
    log_info "  → aiNotificationsDestinations"
    local query
    query=$(account_scoped_query "$account_id" '
        aiNotifications {
            destinations(filters: {}) {
                entities {
                    id
                    name
                    type
                    active
                    status
                    properties {
                        key
                        value
                        label
                        displayValue
                    }
                    createdAt
                    updatedAt
                }
                nextCursor
                totalCount
            }
        }
    ')
    local vars
    vars=$(jq -nc --argjson id "$account_id" '{id: $id}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.account.aiNotifications.destinations' \
        > "$outdir/aiNotificationsDestinations.json"
    local count
    count=$(jq '.totalCount // (.entities | length) // 0' "$outdir/aiNotificationsDestinations.json")
    log_ok "    destinations: ${count}"
    echo "$count"
}

export_muting_rules() {
    local account_id="$1" outdir="$2"
    log_info "  → alertsMutingRules"
    local query
    query=$(account_scoped_query "$account_id" '
        alerts {
            mutingRules {
                id
                name
                enabled
                description
                condition {
                    operator
                    conditions {
                        attribute
                        operator
                        values
                    }
                }
                schedule {
                    startTime
                    endTime
                    timeZone
                    repeat
                    repeatCount
                    weeklyRepeatDays
                    nextStartTime
                    nextEndTime
                }
                status
                createdAt
                updatedAt
            }
        }
    ')
    local vars
    vars=$(jq -nc --argjson id "$account_id" '{id: $id}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.account.alerts.mutingRules' \
        > "$outdir/alertsMutingRules.json"
    local count
    count=$(jq 'length' "$outdir/alertsMutingRules.json" 2>/dev/null || echo 0)
    log_ok "    muting rules: ${count}"
    echo "$count"
}

export_drop_rules() {
    local account_id="$1" outdir="$2"
    log_info "  → nrqlDropRules"
    local query
    query=$(account_scoped_query "$account_id" '
        nrqlDropRules {
            list {
                rules {
                    id
                    accountId
                    action
                    description
                    nrql
                    createdBy
                    createdAt
                }
                error {
                    description
                    reason
                }
            }
        }
    ')
    local vars
    vars=$(jq -nc --argjson id "$account_id" '{id: $id}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.account.nrqlDropRules.list' \
        > "$outdir/nrqlDropRules.json"
    local count
    count=$(jq '.rules | length' "$outdir/nrqlDropRules.json" 2>/dev/null || echo 0)
    log_ok "    drop rules: ${count}"
    echo "$count"
}

export_log_configs() {
    local account_id="$1" outdir="$2"
    log_info "  → logConfigurations.parsingRules"
    local query
    query=$(account_scoped_query "$account_id" '
        logConfigurations {
            parsingRules {
                id
                description
                enabled
                grok
                lucene
                nrql
                attribute
                deleted
                createdBy { email }
                updatedAt
            }
        }
    ')
    local vars
    vars=$(jq -nc --argjson id "$account_id" '{id: $id}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.account.logConfigurations.parsingRules' \
        > "$outdir/logConfigurations.json"
    local count
    count=$(jq 'length' "$outdir/logConfigurations.json" 2>/dev/null || echo 0)
    log_ok "    parsing rules: ${count}"
    echo "$count"
}

export_lookup_tables() {
    local account_id="$1" outdir="$2"
    log_info "  → lookupTables (best-effort; NerdGraph schema varies)"
    # NR's lookup-tables NerdGraph surface is in flux. `Account.nrqlLookups`
    # is the correct field name (replaces the older `lookupTables` name), but
    # its inner fields are not introspectable on all account tiers and the
    # public schema has been in flux. For the migration corpus we write a
    # placeholder pointing at the source CSVs (which are committed in
    # test-NewRelic-setup/terraform/newrelic/lookup-tables/data/). If/when NR
    # stabilizes the schema, replace this with a real query.
    cat > "$outdir/lookupTables.json" <<JSON
{
  "_note": "Lookup tables are not extractable via NerdGraph on this account tier — the schema fields under Account.nrqlLookups are not publicly introspectable. Source-of-truth CSVs live in test-NewRelic-setup/terraform/newrelic/lookup-tables/data/. Upload via test-NewRelic-setup/terraform/newrelic/lookup-tables/upload.sh.",
  "schema_status": "fields_not_introspectable_on_tier",
  "source_repo": "test-NewRelic-setup",
  "source_path": "terraform/newrelic/lookup-tables/data/",
  "lookups": []
}
JSON
    log_warn "    lookup tables: schema fields not introspectable; placeholder pointing at source CSVs"
    echo "0"
}

export_events_to_metrics() {
    local account_id="$1" outdir="$2"
    log_info "  → eventsToMetricsRules (DMA gap)"
    local query
    query=$(account_scoped_query "$account_id" '
        eventsToMetrics {
            allRules {
                rules {
                    id
                    accountId
                    name
                    description
                    enabled
                    nrql
                    createdAt
                    updatedAt
                }
            }
        }
    ')
    local vars
    vars=$(jq -nc --argjson id "$account_id" '{id: $id}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.account.eventsToMetrics.allRules' \
        > "$outdir/eventsToMetricsRules.json"
    local count
    count=$(jq '.rules | length' "$outdir/eventsToMetricsRules.json" 2>/dev/null || echo 0)
    log_ok "    E2M rules: ${count}"
    echo "$count"
}

export_entity_tags() {
    local account_id="$1" outdir="$2"
    log_info "  → entityTags (entities with tag ${ENTITY_TAG_KEY}=${ENTITY_TAG_VALUE})"
    # entitySearch uses a query string. Two clauses: accountId scope + tag match.
    local search_query="tags.${ENTITY_TAG_KEY} = '${ENTITY_TAG_VALUE}' AND accountId = ${account_id}"
    local query='
        query ($searchQuery: String!) {
            actor {
                entitySearch(query: $searchQuery) {
                    results {
                        entities {
                            guid
                            name
                            domain
                            type
                            accountId
                            tags {
                                key
                                values
                            }
                        }
                        nextCursor
                    }
                    count
                }
            }
        }
    '
    local vars
    vars=$(jq -nc --arg sq "$search_query" '{searchQuery: $sq}')
    nerdgraph_query_vars "$query" "$vars" \
        | jq '.data.actor.entitySearch' \
        > "$outdir/entityTags.json"
    local count
    count=$(jq '.count // (.results.entities | length) // 0' "$outdir/entityTags.json" 2>/dev/null || echo 0)
    log_ok "    tagged entities: ${count}"
    echo "$count"
}

# =============================================================================
# RBAC (Users & Groups)
# =============================================================================

export_users() {
    log_info "Exporting users and groups (RBAC)..."
    mkdir -p "$OUTPUT_DIR/_rbac"

    # Get organization ID
    local org_response
    org_response=$(nerdgraph_query '{ actor { organization { id name } } }')
    local org_id
    org_id=$(echo "$org_response" | jq -r '.data.actor.organization.id // empty' 2>/dev/null || echo "")

    if [[ -z "$org_id" ]]; then
        log_warn "Could not discover organization ID — skipping RBAC export"
        echo "[]" > "$OUTPUT_DIR/_rbac/users.json"
        echo "[]" > "$OUTPUT_DIR/_rbac/groups.json"
        return
    fi
    log_debug "  Organization ID: $org_id"

    # --- Auth domains ---
    local domains_query
    domains_query=$(cat <<GRAPHQL
{
  customerAdministration {
    authenticationDomains(filter: { organizationId: { eq: "${org_id}" } }) {
      items { id name }
    }
  }
}
GRAPHQL
)
    local domains_response
    domains_response=$(nerdgraph_query "$domains_query")
    local domain_ids
    domain_ids=$(echo "$domains_response" | jq -r '[.data.customerAdministration.authenticationDomains.items[].id // empty]' 2>/dev/null || echo "[]")
    local domain_count
    domain_count=$(echo "$domain_ids" | jq 'length' 2>/dev/null || echo 0)
    log_debug "  Found $domain_count authentication domain(s)"

    # --- Users (per domain, paginated) ---
    local all_users="[]"
    for domain_id in $(echo "$domain_ids" | jq -r '.[]' 2>/dev/null); do
        local cursor="null"
        while true; do
            local cursor_arg=""
            [[ "$cursor" != "null" ]] && cursor_arg=", cursor: $cursor"

            local query
            query=$(cat <<GRAPHQL
{
  customerAdministration {
    users(filter: { authenticationDomainId: { eq: "${domain_id}" } }${cursor_arg}) {
      items { id name email timeZone authenticationDomainId }
      nextCursor
    }
  }
}
GRAPHQL
)
            local response
            response=$(nerdgraph_query "$query")

            local page_items next_cursor
            page_items=$(echo "$response" | jq '.data.customerAdministration.users.items // []' 2>/dev/null || echo "[]")
            next_cursor=$(echo "$response" | jq '.data.customerAdministration.users.nextCursor' 2>/dev/null || echo "null")

            all_users=$(json_merge_arrays "$all_users" "$page_items")

            cursor="$next_cursor"
            [[ "$cursor" == "null" ]] && break
            sleep "$API_DELAY"
        done
    done

    echo "$all_users" | jq '.' > "$OUTPUT_DIR/_rbac/users.json" 2>/dev/null || echo "[]" > "$OUTPUT_DIR/_rbac/users.json"
    local user_count
    user_count=$(count_json_array_file "$OUTPUT_DIR/_rbac/users.json")
    log_ok "  Exported $user_count users"

    # --- Groups ---
    log_info "  Exporting user groups..."
    local cursor="null"
    local all_groups="[]"
    while true; do
        local cursor_arg=""
        [[ "$cursor" != "null" ]] && cursor_arg=", cursor: $cursor"

        local query
        query=$(cat <<GRAPHQL
{
  customerAdministration {
    groups(filter: { organizationId: { eq: "${org_id}" } }${cursor_arg}) {
      items { id name authenticationDomainId }
      nextCursor
    }
  }
}
GRAPHQL
)
        local response
        response=$(nerdgraph_query "$query")

        local page_items next_cursor
        page_items=$(echo "$response" | jq '.data.customerAdministration.groups.items // []' 2>/dev/null || echo "[]")
        next_cursor=$(echo "$response" | jq '.data.customerAdministration.groups.nextCursor' 2>/dev/null || echo "null")

        all_groups=$(json_merge_arrays "$all_groups" "$page_items")

        cursor="$next_cursor"
        [[ "$cursor" == "null" ]] && break
        sleep "$API_DELAY"
    done

    echo "$all_groups" | jq '.' > "$OUTPUT_DIR/_rbac/groups.json" 2>/dev/null || echo "[]" > "$OUTPUT_DIR/_rbac/groups.json"
    local group_count
    group_count=$(count_json_array_file "$OUTPUT_DIR/_rbac/groups.json")
    log_ok "  Exported $group_count groups"
}

# =============================================================================
# USAGE ANALYTICS
# =============================================================================

run_nrql() {
    local account_id="$1"
    local nrql_query="$2"
    local output_file="$3"

    local query
    query=$(cat <<GRAPHQL
{
  actor {
    account(id: ${account_id}) {
      nrql(query: "${nrql_query}") {
        results
      }
    }
  }
}
GRAPHQL
)
    local response
    response=$(nerdgraph_query "$query")
    echo "$response" | jq '.data.actor.account.nrql.results // []' > "$output_file" 2>/dev/null \
        || echo "[]" > "$output_file"
}

generate_analytics_for_account() {
    local account_id="$1"
    local out_dir="$OUTPUT_DIR/account_${account_id}/_usage_analytics"
    mkdir -p "$out_dir"

    log_info "  [Account $account_id] Generating usage analytics..."

    run_nrql "$account_id" \
        "SELECT count(*) AS 'views', latest(timestamp) AS 'lastViewed' FROM NrAuditEvent WHERE actionIdentifier = 'dashboard.view' FACET targetId LIMIT MAX SINCE 90 days ago" \
        "$out_dir/dashboard_views.json"

    # Sort by views descending, keep top 100
    local sorted
    sorted=$(jq 'sort_by(-.views) | .[0:100]' "$out_dir/dashboard_views.json" 2>/dev/null || cat "$out_dir/dashboard_views.json")
    echo "$sorted" > "$out_dir/dashboard_views.json"

    run_nrql "$account_id" \
        "SELECT count(*) AS 'fired' FROM NrAiIncident FACET conditionName LIMIT MAX SINCE 90 days ago" \
        "$out_dir/alerts_most_fired.json"

    run_nrql "$account_id" \
        "SELECT count(*) AS 'actions' FROM NrAuditEvent FACET actorEmail LIMIT 50 SINCE 90 days ago" \
        "$out_dir/users_most_active.json"

    run_nrql "$account_id" \
        "SELECT bytecountestimate() / 1e9 AS 'daily_gb' FROM NrConsumption WHERE usageMetric = 'EventsBytes' FACET metric SINCE 30 days ago LIMIT MAX" \
        "$out_dir/ingest_by_data_type.json"

    log_ok "  [Account $account_id] Generated 4 usage analytics files"
}

# =============================================================================
# MANIFEST & SUMMARY
# =============================================================================

generate_manifest() {
    log_info "Generating manifest..."

    local export_end_time
    export_end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local end_epoch
    end_epoch=$(date +%s)
    local duration=$(( end_epoch - SCRIPT_START_EPOCH ))

    local account_ids_json
    account_ids_json=$(printf '%s\n' "${ACCOUNT_IDS[@]}" | jq -R . | jq -s '.')

    # Build per-account stats
    local account_stats="{}"
    for aid in "${ACCOUNT_IDS[@]}"; do
        local d="$OUTPUT_DIR/account_${aid}"
        local dashboards alerts_policies nrql_conds synthetics workloads slis
        dashboards=$(jq 'length' "$d/dashboards/dashboards.json" 2>/dev/null || echo 0)
        alerts_policies=$(jq 'length' "$d/alerts/policies.json" 2>/dev/null || echo 0)
        nrql_conds=$(jq 'length' "$d/alerts/nrql_conditions.json" 2>/dev/null || echo 0)
        synthetics=$(jq 'length' "$d/synthetics/monitors.json" 2>/dev/null || echo 0)
        workloads=$(jq 'length' "$d/workloads/workloads.json" 2>/dev/null || echo 0)
        slis=$(jq 'length' "$d/service_levels/indicators.json" 2>/dev/null || echo 0)

        account_stats=$(echo "$account_stats" | jq \
            --arg aid "$aid" \
            --argjson dash "$dashboards" \
            --argjson ap "$alerts_policies" \
            --argjson nc "$nrql_conds" \
            --argjson syn "$synthetics" \
            --argjson wl "$workloads" \
            --argjson sli "$slis" \
            '. + {($aid): {
                dashboards: $dash,
                alert_policies: $ap,
                nrql_conditions: $nc,
                synthetic_monitors: $syn,
                workloads: $wl,
                service_level_indicators: $sli
            }}' 2>/dev/null || echo "$account_stats")
    done

    # Per-account supplemental stats (folded in from nr-supplemental-export.sh).
    # Counts are read back from the written files using the same accessors each
    # extractor uses, so a missing/empty file yields 0 rather than failing.
    local supplemental_stats="{}"
    for aid in "${ACCOUNT_IDS[@]}"; do
        local s="$OUTPUT_DIR/account_${aid}/supplemental"
        local ai_wf ai_dest muting drop logs lookup e2m tags
        ai_wf=$(jq '.totalCount // (.entities | length) // 0' "$s/aiWorkflows.json" 2>/dev/null || echo 0)
        ai_dest=$(jq '.totalCount // (.entities | length) // 0' "$s/aiNotificationsDestinations.json" 2>/dev/null || echo 0)
        muting=$(jq 'length' "$s/alertsMutingRules.json" 2>/dev/null || echo 0)
        drop=$(jq '.rules | length' "$s/nrqlDropRules.json" 2>/dev/null || echo 0)
        logs=$(jq 'length' "$s/logConfigurations.json" 2>/dev/null || echo 0)
        lookup=$(jq '.lookups | length' "$s/lookupTables.json" 2>/dev/null || echo 0)
        e2m=$(jq '.rules | length' "$s/eventsToMetricsRules.json" 2>/dev/null || echo 0)
        tags=$(jq '.count // (.results.entities | length) // 0' "$s/entityTags.json" 2>/dev/null || echo 0)
        # Guard against non-numeric/empty results (e.g. null) → 0
        for v in ai_wf ai_dest muting drop logs lookup e2m tags; do
            [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' 0
        done

        supplemental_stats=$(echo "$supplemental_stats" | jq \
            --arg aid "$aid" \
            --argjson ai_wf "$ai_wf" \
            --argjson ai_dest "$ai_dest" \
            --argjson muting "$muting" \
            --argjson drop "$drop" \
            --argjson logs "$logs" \
            --argjson lookup "$lookup" \
            --argjson e2m "$e2m" \
            --argjson tags "$tags" \
            '. + {($aid): {
                ai_workflows: $ai_wf,
                ai_notifications_destinations: $ai_dest,
                alerts_muting_rules: $muting,
                nrql_drop_rules: $drop,
                log_parsing_rules: $logs,
                lookup_tables: $lookup,
                events_to_metrics_rules: $e2m,
                entity_tags_matching_filter: $tags
            }}' 2>/dev/null || echo "$supplemental_stats")
    done

    local accounts_data
    accounts_data=$(cat "$OUTPUT_DIR/_systeminfo/accounts.json" 2>/dev/null || echo "[]")

    # Build files[] for converter consumers (relative paths under
    # OUTPUT_DIR; manifest.json itself excluded — it's about to be
    # written; export.log excluded — it's appended throughout the run
    # and is metadata, not migration content).
    local files_json
    files_json=$(cd "$OUTPUT_DIR" && find . -type f \
        -not -name 'manifest.json' \
        -not -name 'export.log' \
        2>/dev/null | sed 's|^\./||' | jq -R . | jq -s '.')

    # The DMA New Relic App's @dma/newrelic-converter ManifestParser
    # expects: version, exportedAt, accounts[].region, counts (flat),
    # files[]. The legacy fields (schema_version, export_timestamp,
    # statistics, etc.) are kept so any consumer of the v1.0.1 schema
    # still works — this manifest is a strict superset.
    jq -n \
        --arg schema_version "$SCHEMA_VERSION" \
        --arg tool_version "$SCRIPT_VERSION" \
        --arg export_tool "dma-newrelic-export" \
        --arg export_timestamp "$SCRIPT_START_TIME" \
        --arg export_end_timestamp "$export_end_time" \
        --argjson duration "$duration" \
        --arg region "$REGION" \
        --argjson account_ids "$account_ids_json" \
        --argjson export_dashboards "$([[ $EXPORT_DASHBOARDS == true ]] && echo true || echo false)" \
        --argjson export_alerts "$([[ $EXPORT_ALERTS == true ]] && echo true || echo false)" \
        --argjson export_synthetics "$([[ $EXPORT_SYNTHETICS == true ]] && echo true || echo false)" \
        --argjson export_workloads "$([[ $EXPORT_WORKLOADS == true ]] && echo true || echo false)" \
        --argjson export_service_levels "$([[ $EXPORT_SERVICE_LEVELS == true ]] && echo true || echo false)" \
        --argjson include_rbac "$([[ $INCLUDE_RBAC == true ]] && echo true || echo false)" \
        --argjson include_usage "$([[ $INCLUDE_USAGE == true ]] && echo true || echo false)" \
        --argjson export_ai_workflows "$([[ $EXPORT_AI_WORKFLOWS == true ]] && echo true || echo false)" \
        --argjson export_ai_destinations "$([[ $EXPORT_AI_DESTINATIONS == true ]] && echo true || echo false)" \
        --argjson export_muting_rules "$([[ $EXPORT_MUTING_RULES == true ]] && echo true || echo false)" \
        --argjson export_drop_rules "$([[ $EXPORT_DROP_RULES == true ]] && echo true || echo false)" \
        --argjson export_log_configs "$([[ $EXPORT_LOG_CONFIGS == true ]] && echo true || echo false)" \
        --argjson export_lookup_tables "$([[ $EXPORT_LOOKUP_TABLES == true ]] && echo true || echo false)" \
        --argjson export_events_to_metrics "$([[ $EXPORT_EVENTS_TO_METRICS == true ]] && echo true || echo false)" \
        --argjson export_entity_tags "$([[ $EXPORT_ENTITY_TAGS == true ]] && echo true || echo false)" \
        --arg entity_tag_key "$ENTITY_TAG_KEY" \
        --arg entity_tag_value "$ENTITY_TAG_VALUE" \
        --argjson supplemental_stats "$supplemental_stats" \
        --argjson account_stats "$account_stats" \
        --argjson accounts "$accounts_data" \
        --argjson files "$files_json" \
        '{
            schema_version: $schema_version,
            version: $schema_version,
            export_tool_version: $tool_version,
            export_tool: $export_tool,
            export_timestamp: $export_timestamp,
            exportedAt: $export_timestamp,
            export_end_timestamp: $export_end_timestamp,
            export_duration_seconds: $duration,
            source_system: {
                platform: "New Relic",
                region: $region,
                account_ids: $account_ids
            },
            export_options: {
                dashboards: $export_dashboards,
                alerts: $export_alerts,
                synthetics: $export_synthetics,
                workloads: $export_workloads,
                service_levels: $export_service_levels,
                rbac: $include_rbac,
                usage_analytics: $include_usage
            },
            statistics: $account_stats,
            counts: ($account_stats | to_entries | map(.value) | reduce .[] as $a ({}; . + $a)),
            accounts: ($accounts | map(. + {region: $region})),
            files: $files,
            supplemental: {
                options: {
                    ai_workflows: $export_ai_workflows,
                    ai_notifications_destinations: $export_ai_destinations,
                    alerts_muting_rules: $export_muting_rules,
                    nrql_drop_rules: $export_drop_rules,
                    log_parsing_rules: $export_log_configs,
                    lookup_tables: $export_lookup_tables,
                    events_to_metrics_rules: $export_events_to_metrics,
                    entity_tags: $export_entity_tags
                },
                entity_tag_filter: { key: $entity_tag_key, value: $entity_tag_value },
                statistics: $supplemental_stats,
                counts: ($supplemental_stats | to_entries | map(.value) | reduce .[] as $a ({}; . + $a))
            }
        }' > "$OUTPUT_DIR/manifest.json" 2>/dev/null

    log_ok "Manifest generated"
}

generate_summary() {
    log_info "Generating export summary..."

    local export_end_time
    export_end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local summary_lines
    summary_lines="# DMA New Relic Export — Summary

**Export Started:** ${SCRIPT_START_TIME}
**Export Completed:** ${export_end_time}
**Tool Version:** ${SCRIPT_VERSION}
**Region:** ${REGION}

## Accounts Exported

"
    local accounts_data
    accounts_data=$(cat "$OUTPUT_DIR/_systeminfo/accounts.json" 2>/dev/null || echo "[]")

    for aid in "${ACCOUNT_IDS[@]}"; do
        local name
        name=$(echo "$accounts_data" | jq -r --argjson id "$aid" '.[] | select(.id == $id) | .name' 2>/dev/null || echo "Unknown")
        summary_lines+="- **${aid}** — ${name}
"
    done

    summary_lines+="
## Export Statistics

"
    for aid in "${ACCOUNT_IDS[@]}"; do
        local name
        name=$(echo "$accounts_data" | jq -r --argjson id "$aid" '.[] | select(.id == $id) | .name' 2>/dev/null || echo "Unknown")
        local d="$OUTPUT_DIR/account_${aid}"
        local dashboards alerts_policies nrql_conds synthetics workloads slis
        dashboards=$(jq 'length' "$d/dashboards/dashboards.json" 2>/dev/null || echo 0)
        alerts_policies=$(jq 'length' "$d/alerts/policies.json" 2>/dev/null || echo 0)
        nrql_conds=$(jq 'length' "$d/alerts/nrql_conditions.json" 2>/dev/null || echo 0)
        synthetics=$(jq 'length' "$d/synthetics/monitors.json" 2>/dev/null || echo 0)
        workloads=$(jq 'length' "$d/workloads/workloads.json" 2>/dev/null || echo 0)
        slis=$(jq 'length' "$d/service_levels/indicators.json" 2>/dev/null || echo 0)

        summary_lines+="### Account ${aid} — ${name}

- **Dashboards:** ${dashboards}
- **Alert Policies:** ${alerts_policies}
- **NRQL Conditions:** ${nrql_conds}
- **Synthetic Monitors:** ${synthetics}
- **Workloads:** ${workloads}
- **Service Level Indicators:** ${slis}

"
    done

    summary_lines+="## Next Steps

1. Upload this archive to the DMA New Relic App in your Dynatrace tenant
2. Use the Dashboard Workspace to preview and translate NRQL queries to DQL
3. Review alert conditions in the Alerts Workspace for Dynatrace equivalents
4. Map New Relic workloads to Dynatrace Management Zones
5. Review synthetic monitors in the Synthetics Workspace

## Migration Mapping Reference

| New Relic | Dynatrace Gen3 |
|---|---|
| Dashboard (NRQL widgets) | Dashboard (DQL tiles) |
| NRQL query | DQL query |
| Alert policy + NRQL condition | Metric event alert or DQL-based alert |
| Synthetic monitor | Browser/HTTP monitor |
| Workload | Management Zone |
| Service level indicator | SLO |
| Notification destination | Notification integration |
"

    echo "$summary_lines" > "$OUTPUT_DIR/dma-env-summary.md"
    log_ok "Summary generated"
}

# =============================================================================
# ANONYMIZATION
# =============================================================================

anonymize_archive() {
    local source_archive="$1"
    local masked_archive="${source_archive%.tar.gz}_masked.tar.gz"
    local masked_dir="${source_archive%.tar.gz}_masked"

    log_info "Creating anonymized archive: $masked_archive"
    mkdir -p "$masked_dir"

    tar -xzf "$source_archive" -C "$masked_dir" --strip-components=1 2>/dev/null || {
        log_warn "Anonymization skipped: could not extract source archive"
        return 0
    }

    # SHA-256 mask PII fields using jq
    find "$masked_dir" -name "*.json" | while read -r fpath; do
        local masked
        masked=$(jq 'walk(
            if type == "object" then
                with_entries(
                    if .key == "email" and (.value | type == "string") and (.value | contains("@"))
                    then .value = ((.value | explode | map(. * 31) | add | tostring) + "@masked.example")
                    elif .key == "name" and (.value | type == "string") and (.value | length > 3)
                    then .value = ("entity_" + (.value | ascii_downcase | gsub("[^a-z0-9]"; "_") | .[0:12]))
                    else .
                    end
                )
            else .
            end
        )' "$fpath" 2>/dev/null) || continue
        echo "$masked" > "$fpath"
    done

    tar -czf "$masked_archive" -C "$(dirname "$masked_dir")" "$(basename "$masked_dir")"
    rm -rf "$masked_dir"
    log_ok "Anonymized archive created: $masked_archive"
}

# =============================================================================
# ARCHIVE
# =============================================================================

create_archive() {
    log_info "Creating export archive..."

    local timestamp
    timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
    local archive_name="dma_export_newrelic_${timestamp}.tar.gz"

    tar -czf "$archive_name" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>>"$LOG_FILE"

    local archive_size
    archive_size=$(du -sh "$archive_name" 2>/dev/null | cut -f1 || echo "unknown")
    log_ok "Archive created: $archive_name ($archive_size)"

    if [[ "$ANONYMIZE" == "true" ]]; then
        anonymize_archive "$archive_name"
    fi

    echo "$archive_name"
}

# Package ONE account into its own self-contained tarball. The DMA model treats a
# New Relic account as a Dynatrace-tenant-equivalent: one account → one migration
# scope/target → one DMA project. So the exporter emits one archive PER account
# (each imports as its own project) rather than one combined multi-account archive.
#
# The per-account manifest is sliced from the combined manifest for this account,
# with `counts` set to this account's own statistics (so each archive's counts are
# exact — and it sidesteps the multi-account aggregate). Shared/global content
# (_systeminfo, RBAC users, summary, log) is copied into each archive so it stands
# alone. Each archive contains exactly one `account_<id>/` tree, which the
# downstream @dma/newrelic-converter parses unchanged.
create_account_archive() {
    local account_id="$1"
    local timestamp="$2"
    local parent stage_name stage entry base files_json archive_name
    parent="$(dirname "$OUTPUT_DIR")"
    stage_name="dma_newrelic_export_${account_id}_${timestamp}"
    stage="$parent/$stage_name"
    rm -rf "$stage"
    mkdir -p "$stage"

    # This account's asset tree.
    cp -R "$OUTPUT_DIR/account_${account_id}" "$stage/" 2>>"$LOG_FILE"

    # Shared/global content (anything that isn't another account dir or the
    # combined manifest) so the per-account archive is self-contained.
    for entry in "$OUTPUT_DIR"/*; do
        base="$(basename "$entry")"
        [[ "$base" == account_* ]] && continue
        [[ "$base" == manifest.json ]] && continue
        cp -R "$entry" "$stage/" 2>>"$LOG_FILE"
    done

    # Per-account manifest: slice the combined manifest for this account; make
    # counts exact (= this account's statistics). files[] re-globbed for the slice.
    files_json=$(cd "$stage" && find . -type f \
        -not -name 'manifest.json' -not -name 'export.log' 2>/dev/null \
        | sed 's|^\./||' | jq -R . | jq -s '.')
    jq --arg aid "$account_id" --argjson files "$files_json" '
        (.statistics[$aid] // {}) as $st
        | (.supplemental.statistics[$aid] // {}) as $sst
        | .statistics = { ($aid): $st }
        | .counts = $st
        | .source_system.account_ids = [$aid]
        | .accounts = ((.accounts // []) | map(select((.id | tostring) == $aid)))
        | .files = $files
        | .supplemental.statistics = { ($aid): $sst }
        | .supplemental.counts = $sst
    ' "$OUTPUT_DIR/manifest.json" > "$stage/manifest.json" 2>>"$LOG_FILE"

    archive_name="dma_export_newrelic_${account_id}_${timestamp}.tar.gz"
    tar -czf "$archive_name" -C "$parent" "$stage_name" 2>>"$LOG_FILE"
    rm -rf "$stage"

    if [[ "$ANONYMIZE" == "true" ]]; then
        anonymize_archive "$archive_name"
    fi

    echo "$archive_name"
}

# =============================================================================
# CLI
# =============================================================================

usage() {
    cat <<EOF
${BOLD}DMA New Relic Export Script v${SCRIPT_VERSION}${NC}

${BOLD}USAGE:${NC}
  $0 [OPTIONS]

${BOLD}AUTHENTICATION:${NC}
  --api-key KEY           New Relic User API Key (NRAK-...) [required]
  --region REGION         US (default) or EU

${BOLD}TARGETING:${NC}
  --accounts IDS          Comma-separated account IDs (auto-discovers if omitted)

${BOLD}EXPORT OPTIONS:${NC}
  --all                   Export EVERYTHING — the 5 core types below + the 8
                          supplemental types (the full migration corpus)
  --dashboards            Export dashboards and NRQL widget queries
  --alerts                Export alert policies and NRQL conditions
  --synthetics            Export synthetic monitor configurations
  --workloads             Export workload configurations
  --service-levels        Export service level indicators (SLOs)
  --rbac                  Export users and groups (contains PII — opt-in)
  --usage                 Generate usage analytics via NRQL audit queries (opt-in)

${BOLD}SUPPLEMENTAL OBJECT TYPES (opt in; all included by --all):${NC}
  --supplemental          Enable all 8 supplemental types below (without core)
  --ai-workflows          AI/incident workflows
  --ai-destinations       AI notification destinations
  --muting-rules          Alert muting rules
  --drop-rules            NRQL drop rules
  --log-configs           Log parsing (Grok) rules
  --lookup-tables         Lookup tables (placeholder)
  --events-to-metrics     Events-to-metrics rules
  --entity-tags           Entity tag export
  --no-<type>             Subtract one of the above from --all/--supplemental
  --no-supplemental       Subtract all 8 supplemental types from --all
  --tag-key KEY           entity-tag filter key   (default: team)
  --tag-value VALUE       entity-tag filter value (default: migration)

${BOLD}OTHER:${NC}
  --anonymize             Also produce a SHA-256 masked archive (for sharing)
  --output-dir DIR        Custom working directory (default: system temp)
  --debug                 Verbose logging
  --help, -h              Show this help

${BOLD}EXAMPLES:${NC}
  # Export everything for one account
  $0 --api-key "NRAK-XXX" --accounts "1234567" --all

  # Dashboards and alerts only, multiple accounts
  $0 --api-key "NRAK-XXX" --accounts "1234567,8901234" --dashboards --alerts

  # Full export with RBAC and usage analytics
  $0 --api-key "NRAK-XXX" --accounts "1234567" --all --rbac --usage

  # EU region with anonymized archive
  $0 --api-key "NRAK-XXX" --accounts "1234567" --all --region EU --anonymize

${BOLD}REQUIREMENTS:${NC}
  bash 3.2+, curl, jq, tar
  Network access to https://api.newrelic.com/graphql (US) or https://api.eu.newrelic.com/graphql (EU)

${BOLD}OUTPUT:${NC}
  Produces: dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz
  Upload this archive to the DMA New Relic App in your Dynatrace tenant.
EOF
}

parse_args() {
  [[ $# -eq 0 ]] && { usage; exit 1; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-key)        API_KEY="$2"; shift 2 ;;
            --region)         REGION="$(to_upper "$2")"; REGION_EXPLICIT=true; shift 2 ;;
            --accounts)       IFS=',' read -ra ACCOUNT_IDS <<< "$2"; shift 2 ;;
            --all)            EXPORT_DASHBOARDS=true; EXPORT_ALERTS=true;
                              EXPORT_SYNTHETICS=true; EXPORT_WORKLOADS=true;
                              EXPORT_SERVICE_LEVELS=true;
                              EXPORT_AI_WORKFLOWS=true; EXPORT_AI_DESTINATIONS=true;
                              EXPORT_MUTING_RULES=true; EXPORT_DROP_RULES=true;
                              EXPORT_LOG_CONFIGS=true; EXPORT_LOOKUP_TABLES=true;
                              EXPORT_EVENTS_TO_METRICS=true; EXPORT_ENTITY_TAGS=true; shift ;;
            --dashboards)     EXPORT_DASHBOARDS=true; shift ;;
            --alerts)         EXPORT_ALERTS=true; shift ;;
            --synthetics)     EXPORT_SYNTHETICS=true; shift ;;
            --workloads)      EXPORT_WORKLOADS=true; shift ;;
            --service-levels) EXPORT_SERVICE_LEVELS=true; shift ;;
            --rbac)           INCLUDE_RBAC=true; shift ;;
            --usage)          INCLUDE_USAGE=true; shift ;;
            # Supplemental object types — opt in (parallel to the core per-type flags).
            # `--supplemental` enables the whole group; `--<type>` enables one.
            --supplemental)         EXPORT_AI_WORKFLOWS=true; EXPORT_AI_DESTINATIONS=true;
                                    EXPORT_MUTING_RULES=true; EXPORT_DROP_RULES=true;
                                    EXPORT_LOG_CONFIGS=true; EXPORT_LOOKUP_TABLES=true;
                                    EXPORT_EVENTS_TO_METRICS=true; EXPORT_ENTITY_TAGS=true; shift ;;
            --ai-workflows)         EXPORT_AI_WORKFLOWS=true; shift ;;
            --ai-destinations)      EXPORT_AI_DESTINATIONS=true; shift ;;
            --muting-rules)         EXPORT_MUTING_RULES=true; shift ;;
            --drop-rules)           EXPORT_DROP_RULES=true; shift ;;
            --log-configs)          EXPORT_LOG_CONFIGS=true; shift ;;
            --lookup-tables)        EXPORT_LOOKUP_TABLES=true; shift ;;
            --events-to-metrics)    EXPORT_EVENTS_TO_METRICS=true; shift ;;
            --entity-tags)          EXPORT_ENTITY_TAGS=true; shift ;;
            # ...and opt out individually (subtract from --all / --supplemental).
            --no-ai-workflows)      EXPORT_AI_WORKFLOWS=false; shift ;;
            --no-ai-destinations)   EXPORT_AI_DESTINATIONS=false; shift ;;
            --no-muting-rules)      EXPORT_MUTING_RULES=false; shift ;;
            --no-drop-rules)        EXPORT_DROP_RULES=false; shift ;;
            --no-log-configs)       EXPORT_LOG_CONFIGS=false; shift ;;
            --no-lookup-tables)     EXPORT_LOOKUP_TABLES=false; shift ;;
            --no-events-to-metrics) EXPORT_EVENTS_TO_METRICS=false; shift ;;
            --no-entity-tags)       EXPORT_ENTITY_TAGS=false; shift ;;
            --no-supplemental)      EXPORT_AI_WORKFLOWS=false; EXPORT_AI_DESTINATIONS=false;
                                    EXPORT_MUTING_RULES=false; EXPORT_DROP_RULES=false;
                                    EXPORT_LOG_CONFIGS=false; EXPORT_LOOKUP_TABLES=false;
                                    EXPORT_EVENTS_TO_METRICS=false; EXPORT_ENTITY_TAGS=false; shift ;;
            --tag-key)        ENTITY_TAG_KEY="$2"; shift 2 ;;
            --tag-value)      ENTITY_TAG_VALUE="$2"; shift 2 ;;
            --anonymize)      ANONYMIZE=true; shift ;;
            --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
            --debug)          DEBUG=true; shift ;;
            --help|-h)        usage; exit 0 ;;
            *)                log_error "Unknown argument: $1"; echo ""; usage; exit 1 ;;
        esac
    done
}

validate_args() {
    [[ -z "$API_KEY" ]] && API_KEY="${NEW_RELIC_USER_API_KEY:-}"

  if [[ ${#ACCOUNT_IDS[@]} -eq 0 && -n "${NEW_RELIC_ACCOUNT_ID:-}" ]]; then
        IFS=',' read -ra ACCOUNT_IDS <<< "$NEW_RELIC_ACCOUNT_ID"
  fi

  if [[ "$REGION_EXPLICIT" != "true" && -n "${NEW_RELIC_REGION:-}" ]]; then
        REGION="$(to_upper "$NEW_RELIC_REGION")"
  fi

    if [[ -z "$API_KEY" ]]; then
        print_color "$RED" "ERROR: --api-key is required (or set NEW_RELIC_USER_API_KEY)"
        echo "  Get a User API Key at: Account Settings → API keys → Create a key"
        exit 1
    fi

    if [[ "$REGION" == "EU" ]]; then
        GRAPHQL_ENDPOINT="$API_ENDPOINT_EU"
    elif [[ "$REGION" != "US" ]]; then
        print_color "$RED" "ERROR: --region must be US or EU (got: $REGION)"
        exit 1
    fi

    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="/tmp/dma_newrelic_export_$(date +%s)"
    fi

    mkdir -p "$OUTPUT_DIR/_systeminfo"
    LOG_FILE="$OUTPUT_DIR/export.log"
    touch "$LOG_FILE"
}

# =============================================================================
# ENVIRONMENT INFO
# =============================================================================

write_environment_info() {
    local os_name os_version hostname_val
    os_name=$(uname -s 2>/dev/null || echo "Unknown")
    os_version=$(uname -r 2>/dev/null || echo "Unknown")
    hostname_val=$(hostname 2>/dev/null || echo "Unknown")

    jq -n \
        --arg export_timestamp "$SCRIPT_START_TIME" \
        --arg export_tool "dma-newrelic-export" \
        --arg export_tool_version "$SCRIPT_VERSION" \
        --arg os "$os_name" \
        --arg os_version "$os_version" \
        --arg hostname "$hostname_val" \
        '{
            export_timestamp: $export_timestamp,
            export_tool: $export_tool,
            export_tool_version: $export_tool_version,
            host: {
                os: $os,
                os_version: $os_version,
                hostname: $hostname
            }
        }' > "$OUTPUT_DIR/_systeminfo/environment.json" 2>/dev/null || true
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  load_env_file_if_present
    parse_args "$@"
    check_prerequisites
    validate_args

    print_header "$SCRIPT_NAME v${SCRIPT_VERSION}"

    log_info "Region:   $REGION"
    log_info "Endpoint: $GRAPHQL_ENDPOINT"
    log_info "Output:   $OUTPUT_DIR"
    log_info "Accounts: ${ACCOUNT_IDS[*]:-auto-discover}"
    echo ""

    write_environment_info

    # Account setup
    [[ ${#ACCOUNT_IDS[@]} -eq 0 ]] && discover_account_ids
    export_accounts
    echo ""

    # Per-account exports
    for account_id in "${ACCOUNT_IDS[@]}"; do
        print_color "$CYAN" "  Processing account: ${BOLD}$account_id${NC}"
        mkdir -p "$OUTPUT_DIR/account_${account_id}"
        [[ "$EXPORT_DASHBOARDS"     == "true" ]] && export_dashboards_for_account     "$account_id"
        [[ "$EXPORT_ALERTS"         == "true" ]] && export_alerts_for_account         "$account_id"
        [[ "$EXPORT_SYNTHETICS"     == "true" ]] && export_synthetics_for_account     "$account_id"
        [[ "$EXPORT_WORKLOADS"      == "true" ]] && export_workloads_for_account      "$account_id"
        [[ "$EXPORT_SERVICE_LEVELS" == "true" ]] && export_service_levels_for_account "$account_id"

        # Supplemental object types (folded in from nr-supplemental-export.sh).
        # All write to account_<id>/supplemental/ and are included in the tarball.
        local supp_dir="$OUTPUT_DIR/account_${account_id}/supplemental"
        mkdir -p "$supp_dir"
        [[ "$EXPORT_AI_WORKFLOWS"      == "true" ]] && export_ai_workflows      "$account_id" "$supp_dir"
        [[ "$EXPORT_AI_DESTINATIONS"   == "true" ]] && export_ai_destinations   "$account_id" "$supp_dir"
        [[ "$EXPORT_MUTING_RULES"      == "true" ]] && export_muting_rules      "$account_id" "$supp_dir"
        [[ "$EXPORT_DROP_RULES"        == "true" ]] && export_drop_rules        "$account_id" "$supp_dir"
        [[ "$EXPORT_LOG_CONFIGS"       == "true" ]] && export_log_configs       "$account_id" "$supp_dir"
        [[ "$EXPORT_LOOKUP_TABLES"     == "true" ]] && export_lookup_tables     "$account_id" "$supp_dir"
        [[ "$EXPORT_EVENTS_TO_METRICS" == "true" ]] && export_events_to_metrics "$account_id" "$supp_dir"
        [[ "$EXPORT_ENTITY_TAGS"       == "true" ]] && export_entity_tags       "$account_id" "$supp_dir"

        [[ "$INCLUDE_USAGE"         == "true" ]] && generate_analytics_for_account    "$account_id"
        echo ""
    done

    # Global exports
    [[ "$INCLUDE_RBAC" == "true" ]] && { export_users; echo ""; }

    # Finalize — ONE ARCHIVE PER ACCOUNT (one NR account → one migration
    # scope/target → one DMA project). generate_manifest builds the combined
    # manifest first; each per-account archive is sliced from it.
    generate_manifest
    generate_summary
    local pkg_timestamp account_archives=() account_id acct_archive a
    pkg_timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
    for account_id in "${ACCOUNT_IDS[@]}"; do
        acct_archive=$(create_account_archive "$account_id" "$pkg_timestamp")
        account_archives+=("$acct_archive")
    done

    echo ""
    print_color "$GREEN" "${BOLD}Export complete!${NC}"
    print_color "$WHITE" "  ${#account_archives[@]} per-account archive(s) — one per New Relic account; import EACH as its own DMA project:"
    for a in "${account_archives[@]}"; do
        print_color "$WHITE" "    • $a"
    done
    print_color "$WHITE" "  Log:      $LOG_FILE"
    echo ""
    print_color "$BLUE" "  Next step: Upload each archive to the DMA New Relic App as a separate project."
    echo ""

    # Clean up staging directory after all output is complete
    rm -rf "$OUTPUT_DIR"
}

main "$@"
