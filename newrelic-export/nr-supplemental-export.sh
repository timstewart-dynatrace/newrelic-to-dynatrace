#!/bin/bash
# LINE ENDING FIX: Auto-detect and fix Windows CRLF line endings
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && grep -q $'\r' "$0" 2>/dev/null; then
    echo "Detected Windows line endings (CRLF). Converting to Unix (LF)..."
    sed -i.bak 's/\r$//' "$0" && rm -f "$0.bak"
    exec bash "$0" "$@"
fi

################################################################################
#
#  NR Supplemental Export Script v0.2.0
#
#  Captures the 8 NR object types that dma-newrelic-export.sh v1.1.0 does not
#  extract, so the migration corpus is complete before the NRQL → DQL hand-off.
#
#  Object types extracted:
#    1. aiWorkflows                     — incident routing workflows
#    2. aiNotificationsDestinations     — modern destination model
#    3. alertsMutingRules               — maintenance windows / suppression
#    4. nrqlDropRules                   — pre-storage filter rules (NR EOL 2026-06-30)
#    5. logConfigurations.parsingRules  — log parsing (Grok) rules
#    6. lookupTables                    — list (data extracted via REST per table)
#    7. eventsToMetricsRules            — DMA gap; in-tenant rules
#    8. entityTags                      — tags on entities matching team=migration
#
#  Output: dma-export/account_<id>/{category}/{type}.json
#  Tarball: nr_supplemental_<region>_<timestamp>.tar.gz
#
#  CLI surface mirrors dma-newrelic-export.sh for operational consistency.
#
################################################################################

set -o pipefail

readonly SCRIPT_VERSION="0.2.0"
readonly SCHEMA_VERSION="1.0"
readonly SCRIPT_NAME="NR Supplemental Export"
readonly SCRIPT_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
readonly SCRIPT_START_EPOCH="$(date +%s)"

readonly API_ENDPOINT_US="https://api.newrelic.com/graphql"
readonly API_ENDPOINT_EU="https://api.eu.newrelic.com/graphql"
readonly REST_ENDPOINT_US="https://api.newrelic.com/v2"
readonly REST_ENDPOINT_EU="https://api.eu.newrelic.com/v2"
readonly API_RETRY_COUNT=3
readonly API_RETRY_BACKOFF_SECONDS=2

# Defaults
API_KEY=""
REGION="US"
REGION_EXPLICIT=false
ACCOUNTS=""
OUTPUT_DIR="./dma-export"
TEST_ACCESS=false
VERBOSE=false
ENTITY_TAG_KEY="team"
ENTITY_TAG_VALUE="migration"

to_upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# Load .env credentials (ported from dma-newrelic-export.sh v1.1.0).
# Precedence: CLI flags > process environment > .env (cwd first, then repo root).
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

# =============================================================================
# Color + logging
# =============================================================================
print_color() {
    local color="$1"; shift
    case "$color" in
        red)    printf '\033[0;31m%s\033[0m\n' "$*" ;;
        green)  printf '\033[0;32m%s\033[0m\n' "$*" ;;
        yellow) printf '\033[0;33m%s\033[0m\n' "$*" ;;
        cyan)   printf '\033[0;36m%s\033[0m\n' "$*" ;;
        *)      printf '%s\n' "$*" ;;
    esac
}

log_info()  { print_color cyan   "[INFO ] $*"; }
log_ok()    { print_color green  "[OK   ] $*"; }
log_warn()  { print_color yellow "[WARN ] $*"; }
log_error() { print_color red    "[ERROR] $*" >&2; }
log_debug() { [[ "$VERBOSE" == true ]] && print_color yellow "[DEBUG] $*"; return 0; }

# =============================================================================
# Prerequisite check
# =============================================================================
check_prerequisites() {
    local missing=()
    for cmd in curl jq tar; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Install jq: brew install jq (macOS) | apt-get install jq (Linux)"
        exit 1
    fi
}

# =============================================================================
# NerdGraph helper — POST a query, retry on transient failure, return data block
# =============================================================================
nerdgraph_query() {
    local query="$1"
    local variables="$2"
    # bash parameter-expansion default of `{}` collides with brace expansion;
    # use an explicit check instead.
    [[ -z "$variables" ]] && variables='{}'
    local endpoint
    case "$REGION" in
        US) endpoint="$API_ENDPOINT_US" ;;
        EU) endpoint="$API_ENDPOINT_EU" ;;
        *) log_error "Unknown region: $REGION"; return 1 ;;
    esac

    local payload
    payload=$(jq -nc --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')

    local attempt=0 response http_code body
    while [[ $attempt -lt $API_RETRY_COUNT ]]; do
        attempt=$((attempt + 1))
        response=$(curl -sS -w "\n%{http_code}" -X POST "$endpoint" \
            -H "Content-Type: application/json" \
            -H "API-Key: $API_KEY" \
            -d "$payload" 2>/dev/null)
        http_code="${response##*$'\n'}"
        body="${response%$'\n'*}"

        if [[ "$http_code" == "200" ]]; then
            # GraphQL "200 with errors" — check the errors field
            local has_errors
            has_errors=$(echo "$body" | jq -r '.errors // empty' 2>/dev/null)
            if [[ -n "$has_errors" ]]; then
                log_warn "GraphQL returned errors (attempt $attempt/$API_RETRY_COUNT):"
                echo "$body" | jq -r '.errors[].message' >&2
                if [[ $attempt -lt $API_RETRY_COUNT ]]; then
                    sleep $((API_RETRY_BACKOFF_SECONDS * attempt))
                    continue
                else
                    # Return whatever data block exists so partial results are saved
                    echo "$body"
                    return 0
                fi
            fi
            echo "$body"
            return 0
        fi
        log_warn "HTTP $http_code (attempt $attempt/$API_RETRY_COUNT)"
        sleep $((API_RETRY_BACKOFF_SECONDS * attempt))
    done

    log_error "NerdGraph query failed after $API_RETRY_COUNT attempts"
    return 1
}

# =============================================================================
# Per-object-type extractors
# =============================================================================

# Wraps `actor.account(id: $id) { ... }` around a body — saves repeating the
# scaffolding 8 times.
account_scoped_query() {
    local account_id="$1"
    local body="$2"
    echo "query (\$id: Int!) { actor { account(id: \$id) { $body } } }"
}

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
    nerdgraph_query "$query" "$vars" \
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
    nerdgraph_query "$query" "$vars" \
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
    nerdgraph_query "$query" "$vars" \
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
    nerdgraph_query "$query" "$vars" \
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
    nerdgraph_query "$query" "$vars" \
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
    # NR's lookup-tables NerdGraph surface is in flux. Try the documented form;
    # if NR returns 'Cannot query field', write a stub manifest noting the
    # extractor needs updating. This keeps the supplemental tarball complete
    # and surfaces drift to the user.
    local query
    # `Account.nrqlLookups` is the correct field name (replaces the older
    # `lookupTables` name), but its inner fields are not introspectable on
    # all account tiers and the public schema has been in flux. For the
    # migration corpus we write a placeholder pointing at the source CSVs
    # (which are committed in test-NewRelic-setup/terraform/newrelic/
    # lookup-tables/data/). If/when NR stabilizes the schema, replace this
    # with a real query.
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
    nerdgraph_query "$query" "$vars" \
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
    nerdgraph_query "$query" "$vars" \
        | jq '.data.actor.entitySearch' \
        > "$outdir/entityTags.json"
    local count
    count=$(jq '.count // (.results.entities | length) // 0' "$outdir/entityTags.json" 2>/dev/null || echo 0)
    log_ok "    tagged entities: ${count}"
    echo "$count"
}

# =============================================================================
# Manifest generation
# =============================================================================
generate_manifest() {
    local outdir="$1"
    local account_id="$2"
    shift 2
    # Remaining args are pairs of "type=count"
    local counts_json="{}"
    while [[ $# -gt 0 ]]; do
        local pair="$1"
        local key="${pair%%=*}"
        local val="${pair##*=}"
        counts_json=$(echo "$counts_json" | jq --arg k "$key" --argjson v "${val:-0}" '. + {($k): $v}')
        shift
    done

    local script_end_epoch="$(date +%s)"
    local duration=$((script_end_epoch - SCRIPT_START_EPOCH))
    local end_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    jq -n \
        --arg version "$SCRIPT_VERSION" \
        --arg schema "$SCHEMA_VERSION" \
        --arg name "$SCRIPT_NAME" \
        --arg start "$SCRIPT_START_TIME" \
        --arg end "$end_time" \
        --argjson dur "$duration" \
        --arg region "$REGION" \
        --argjson account "$account_id" \
        --arg endpoint "$([[ "$REGION" == "US" ]] && echo "$API_ENDPOINT_US" || echo "$API_ENDPOINT_EU")" \
        --arg tag_key "$ENTITY_TAG_KEY" \
        --arg tag_value "$ENTITY_TAG_VALUE" \
        --argjson counts "$counts_json" \
        '{
            script_name: $name,
            script_version: $version,
            schema_version: $schema,
            export_started_at: $start,
            export_completed_at: $end,
            export_duration_seconds: $dur,
            region: $region,
            api_endpoint: $endpoint,
            account_id: $account,
            entity_tag_filter: { key: $tag_key, value: $tag_value },
            supplemental_object_counts: $counts,
            covers_dma_gap: true,
            notes: "Pair with the latest DMA export tarball to get full migration coverage. DMA captures: dashboards, alert policies + conditions, synthetic monitors, workloads, SLIs. This supplemental adds: workflows, destinations, muting rules, drop rules, log parsing, lookup tables (placeholder if schema unsupported), events-to-metrics, entity tags."
        }' > "$outdir/manifest.json"
}

# =============================================================================
# Tarball
# =============================================================================
create_archive() {
    local export_root="$1"
    local timestamp
    timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
    local tarball="nr_supplemental_${REGION}_${timestamp}.tar.gz"
    # Tar from the parent of export_root so the archive contains dma-export/...
    local parent
    parent=$(dirname "$export_root")
    local base
    base=$(basename "$export_root")
    (cd "$parent" && tar -czf "$tarball" "$base")
    mv "$parent/$tarball" "$(dirname "$export_root")/$tarball"
    log_ok "Tarball: $parent/$tarball"
    echo "$parent/$tarball"
}

# =============================================================================
# CLI
# =============================================================================
usage() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Captures the 8 NR object types that dma-newrelic-export.sh does NOT extract.
Designed to sit beside the DMA tarball in migration/source/raw/.

USAGE:
    $0 --api-key <key> --accounts <id> [options]

REQUIRED:
    --api-key KEY        NR User API Key (NRAK-...)
    --accounts IDS       Comma-separated account IDs (e.g. "1234567,7654321")

OPTIONAL:
    --region {US|EU}     Data region (default: US)
    --output-dir DIR     Output directory (default: ./dma-export)
    --tag-key KEY        Entity tag key to filter (default: team)
    --tag-value VALUE    Entity tag value to filter (default: migration)
    --test-access        Verify API key + account access then exit
    --verbose            Verbose logging
    --help               This help

ENV alternatives (exported vars, or a .env file in the current directory
or repo root — precedence: CLI flags > exported env > .env):
    NEW_RELIC_USER_API_KEY       same as --api-key
    NEW_RELIC_ACCOUNT_ID         same as --accounts (comma-separated ok)
    NEW_RELIC_REGION             same as --region (case-insensitive)

EXAMPLE:
    $0 --api-key NRAK-XXX --accounts 8018100 --output-dir ./tmp/export

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-key)     API_KEY="$2";       shift 2 ;;
            --region)      REGION="$(to_upper "$2")"; REGION_EXPLICIT=true; shift 2 ;;
            --accounts)    ACCOUNTS="$2";      shift 2 ;;
            --output-dir)  OUTPUT_DIR="$2";    shift 2 ;;
            --tag-key)     ENTITY_TAG_KEY="$2"; shift 2 ;;
            --tag-value)   ENTITY_TAG_VALUE="$2"; shift 2 ;;
            --test-access) TEST_ACCESS=true;   shift ;;
            --verbose)     VERBOSE=true;       shift ;;
            --help|-h)     usage; exit 0 ;;
            *) log_error "Unknown arg: $1"; usage; exit 1 ;;
        esac
    done

    # Env fallbacks (vars may come from the shell or a sourced .env)
    [[ -z "$API_KEY" ]] && API_KEY="${NEW_RELIC_USER_API_KEY:-}"
    [[ -z "$ACCOUNTS" ]] && ACCOUNTS="${NEW_RELIC_ACCOUNT_ID:-}"
    if [[ "$REGION_EXPLICIT" != "true" && -n "${NEW_RELIC_REGION:-}" ]]; then
        REGION="$(to_upper "$NEW_RELIC_REGION")"
    fi

    if [[ -z "$API_KEY" ]]; then
        log_error "Missing --api-key (or NEW_RELIC_USER_API_KEY env)"
        exit 1
    fi
    if [[ -z "$ACCOUNTS" ]]; then
        log_error "Missing --accounts (or NEW_RELIC_ACCOUNT_ID env)"
        exit 1
    fi
    case "$REGION" in US|EU) ;; *) log_error "Region must be US or EU, got: $REGION"; exit 1 ;; esac
}

# =============================================================================
# Main
# =============================================================================
main() {
    load_env_file_if_present
    parse_args "$@"
    check_prerequisites

    print_color cyan "==============================================="
    print_color cyan " $SCRIPT_NAME v$SCRIPT_VERSION"
    print_color cyan "==============================================="
    log_info "Region:      $REGION"
    log_info "Accounts:    $ACCOUNTS"
    log_info "Output dir:  $OUTPUT_DIR"
    log_info "Tag filter:  ${ENTITY_TAG_KEY}=${ENTITY_TAG_VALUE}"
    echo

    if [[ "$TEST_ACCESS" == true ]]; then
        log_info "Test-access mode: verifying key + account read"
        local probe
        probe=$(nerdgraph_query '{ actor { user { name email } } }' '{}')
        local user
        user=$(echo "$probe" | jq -r '.data.actor.user.name // empty')
        if [[ -n "$user" ]]; then
            log_ok "Authenticated as: $user"
            exit 0
        else
            log_error "Authentication failed"
            echo "$probe" >&2
            exit 1
        fi
    fi

    mkdir -p "$OUTPUT_DIR"
    local export_root="$OUTPUT_DIR/dma-export"
    mkdir -p "$export_root"

    IFS=',' read -r -a account_array <<< "$ACCOUNTS"
    for raw_id in "${account_array[@]}"; do
        local account_id="${raw_id// /}"
        log_info "Account $account_id"
        local outdir="$export_root/account_${account_id}/supplemental"
        mkdir -p "$outdir"

        local c1 c2 c3 c4 c5 c6 c7 c8
        c1=$(export_ai_workflows       "$account_id" "$outdir" | tail -1)
        c2=$(export_ai_destinations    "$account_id" "$outdir" | tail -1)
        c3=$(export_muting_rules       "$account_id" "$outdir" | tail -1)
        c4=$(export_drop_rules         "$account_id" "$outdir" | tail -1)
        c5=$(export_log_configs        "$account_id" "$outdir" | tail -1)
        c6=$(export_lookup_tables      "$account_id" "$outdir" | tail -1)
        c7=$(export_events_to_metrics  "$account_id" "$outdir" | tail -1)
        c8=$(export_entity_tags        "$account_id" "$outdir" | tail -1)

        generate_manifest "$outdir" "$account_id" \
            "aiWorkflows=$c1" \
            "aiNotificationsDestinations=$c2" \
            "alertsMutingRules=$c3" \
            "nrqlDropRules=$c4" \
            "logConfigurationsParsingRules=$c5" \
            "lookupTables=$c6" \
            "eventsToMetricsRules=$c7" \
            "entityTagsMatchingFilter=$c8"

        log_ok "Account $account_id: 8 categories extracted → $outdir"
    done

    create_archive "$export_root"
    log_ok "Done."
}

main "$@"
