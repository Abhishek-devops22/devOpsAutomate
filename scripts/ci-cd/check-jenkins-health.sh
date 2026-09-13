#!/usr/bin/env bash
#
# check-jenkins-health.sh — health check for a Jenkins CI/CD controller.
#
# Checks, in order:
#   1. HTTP reachability and response time
#   2. Authenticated API access (/api/json)
#   3. Quiet-down / shutdown-pending mode
#   4. Executor capacity and agent/node status (/computer/api/json)
#   5. Build queue depth, blocked/stuck items, oldest wait time
#   6. Per-node free disk / temp space and agent response time
#   7. Metrics plugin healthchecks, when JENKINS_METRICS_KEY is set
#
# Configuration — env vars, or a .env file beside this script or at the repo
# root (both are gitignored):
#   JENKINS_URL          required, e.g. https://jenkins.example.com
#   JENKINS_USER         username for API auth (recommended)
#   JENKINS_API_TOKEN    API token for that user (Jenkins > your user > Security)
#   JENKINS_METRICS_KEY  access key for the Metrics plugin healthcheck (optional)
#   JENKINS_INSECURE     "true" to skip TLS verification (self-signed certs)
#   QUEUE_WARN           queue length that triggers WARN (default 10)
#   QUEUE_CRIT           queue length that triggers CRIT (default 25)
#   QUEUE_AGE_WARN_MIN   oldest queued item age, in minutes, for WARN (default 30)
#   RESPONSE_WARN_MS     controller response time for WARN (default 3000)
#   DISK_WARN_GB         free disk on a node that triggers WARN (default 5)
#
# Usage:
#   ./scripts/ci-cd/check-jenkins-health.sh [options]
#
# Options:
#   -q, --quiet     Only print WARN/CRIT findings and the final summary.
#   -v, --verbose   Print every check result, including OK ones.
#       --no-log    Don't write to the log file (stdout only).
#   -h, --help      Show this help and exit.
#
# Exit codes: 0 = healthy, 1 = warnings, 2 = critical, 3 = config/usage error.
#
# Every run appends all check results to
# scripts/ci-cd/logs/jenkins-health-YYYY-MM-DD.log for later review.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." &>/dev/null && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/jenkins-health-$(date +%Y-%m-%d).log"

QUIET=false
VERBOSE=false
WRITE_LOG=true

usage() {
    sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q|--quiet) QUIET=true ;;
        -v|--verbose) VERBOSE=true ;;
        --no-log) WRITE_LOG=false ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 3 ;;
    esac
    shift
done

# Load .env if present (script dir takes precedence over repo root).
for candidate in "${REPO_ROOT}/.env" "${SCRIPT_DIR}/.env"; do
    if [[ -f "$candidate" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$candidate"
        set +a
    fi
done

JENKINS_URL="${JENKINS_URL:-}"
JENKINS_USER="${JENKINS_USER:-}"
JENKINS_API_TOKEN="${JENKINS_API_TOKEN:-}"
JENKINS_METRICS_KEY="${JENKINS_METRICS_KEY:-}"
JENKINS_INSECURE="${JENKINS_INSECURE:-false}"
QUEUE_WARN="${QUEUE_WARN:-10}"
QUEUE_CRIT="${QUEUE_CRIT:-25}"
QUEUE_AGE_WARN_MIN="${QUEUE_AGE_WARN_MIN:-30}"
RESPONSE_WARN_MS="${RESPONSE_WARN_MS:-3000}"
DISK_WARN_GB="${DISK_WARN_GB:-5}"

for tool in curl jq; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Required tool not found in PATH: $tool" >&2
        exit 3
    fi
done

if [[ -z "$JENKINS_URL" ]]; then
    cat >&2 <<'MSG'
JENKINS_URL is not set.

Set it in the environment, or create a .env file at the repo root:

    JENKINS_URL=https://jenkins.example.com
    JENKINS_USER=your-username
    JENKINS_API_TOKEN=your-api-token

Generate the token in Jenkins under: your user > Security > API Token.
MSG
    exit 3
fi

JENKINS_URL="${JENKINS_URL%/}"

mkdir -p "$LOG_DIR"

STATUS_OK=0
STATUS_WARN=1
STATUS_CRIT=2
# INFO is for context lines that shouldn't affect the verdict. It is
# deliberately negative so the numeric escalation guard in record() skips it.
STATUS_INFO=-1
OVERALL=$STATUS_OK

WARN_COUNT=0
CRIT_COUNT=0

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# record <level 0|1|2> <check-name> <detail>
# Prints per the verbosity flags, always appends to the log, and escalates
# the overall status.
record() {
    local level="$1" check="$2" detail="$3" label
    case "$level" in
        0) label="OK" ;;
        1) label="WARN"; ((WARN_COUNT++)) || true ;;
        2) label="CRIT"; ((CRIT_COUNT++)) || true ;;
        *) label="INFO" ;;
    esac

    if [[ "$level" =~ ^[0-9]+$ ]] && (( level > OVERALL )); then
        OVERALL=$level
    fi

    local line
    line="$(printf '%s | %-5s | %-16s | %s' "$(timestamp)" "$label" "$check" "$detail")"

    if [[ "$WRITE_LOG" == true ]]; then
        echo "$line" >> "$LOG_FILE"
    fi

    # INFO and OK are only printed in verbose mode; WARN/CRIT always print
    # unless we were asked for nothing at all.
    if [[ "$label" == "WARN" || "$label" == "CRIT" ]]; then
        echo "$line"
    elif [[ "$VERBOSE" == true ]]; then
        echo "$line"
    fi
}

log_only() {
    [[ "$WRITE_LOG" == true ]] && echo "$1" >> "$LOG_FILE"
    [[ "$QUIET" == false ]] && echo "$1"
    return 0
}

# Build the shared curl argument list once. --globoff is required: Jenkins
# tree= parameters contain [ and ], which curl would otherwise read as URL
# glob ranges and never send the request.
CURL_ARGS=(--silent --show-error --location --globoff --connect-timeout 5 --max-time 20)
if [[ "$JENKINS_INSECURE" == "true" ]]; then
    CURL_ARGS+=(--insecure)
fi
if [[ -n "$JENKINS_USER" && -n "$JENKINS_API_TOKEN" ]]; then
    CURL_ARGS+=(--user "${JENKINS_USER}:${JENKINS_API_TOKEN}")
fi

# jenkins_get <path> -> body on stdout; returns non-zero on transport failure
# or a non-2xx response. Callers read the status code with http_code, not a
# variable: jenkins_get is always run inside $(...), and an assignment made
# in that subshell would never reach the caller — so the code goes through a
# temp file instead.
HTTP_CODE_FILE="$(mktemp)"
trap 'rm -f "$HTTP_CODE_FILE"' EXIT

jenkins_get() {
    local path="$1" tmp code
    tmp="$(mktemp)"
    code="$(curl "${CURL_ARGS[@]}" \
        --output "$tmp" \
        --write-out '%{http_code}' \
        "${JENKINS_URL}${path}" 2>/dev/null || echo "000")"
    printf '%s' "$code" > "$HTTP_CODE_FILE"
    cat "$tmp"
    rm -f "$tmp"
    [[ "$code" =~ ^2 ]]
}

# HTTP status of the most recent jenkins_get.
http_code() {
    cat "$HTTP_CODE_FILE" 2>/dev/null || printf '000'
}

log_only ""
log_only "=== Jenkins health check $(timestamp) — ${JENKINS_URL} ==="

# ---------------------------------------------------------------------------
# 1. Reachability and response time
# ---------------------------------------------------------------------------
probe="$(curl "${CURL_ARGS[@]}" \
    --output /dev/null \
    --write-out '%{http_code} %{time_total}' \
    --head "${JENKINS_URL}/login" 2>/dev/null || echo "000 0")"
probe_code="${probe%% *}"
time_total="${probe##* }"
time_ms="$(awk -v t="$time_total" 'BEGIN { printf "%.0f", t * 1000 }')"

if [[ "$probe_code" == "000" ]]; then
    record $STATUS_CRIT "reachability" "cannot connect to ${JENKINS_URL} (DNS, network, TLS, or Jenkins is down)"
    log_only "=== Result: CRITICAL — Jenkins unreachable. ==="
    exit $STATUS_CRIT
elif [[ ! "$probe_code" =~ ^(2|3|4) ]]; then
    record $STATUS_CRIT "reachability" "HTTP ${probe_code} from ${JENKINS_URL}/login after ${time_ms}ms"
else
    record $STATUS_OK "reachability" "HTTP ${probe_code} in ${time_ms}ms"
fi

if (( time_ms > RESPONSE_WARN_MS )); then
    record $STATUS_WARN "response-time" "controller took ${time_ms}ms to respond (threshold ${RESPONSE_WARN_MS}ms)"
fi

# Jenkins advertises its version in a response header — handy in the log.
version="$(curl "${CURL_ARGS[@]}" --head --output /dev/null \
    --write-out '%header{x-jenkins}' "${JENKINS_URL}/login" 2>/dev/null || true)"
[[ -n "$version" ]] && record $STATUS_OK "version" "Jenkins ${version}"

# ---------------------------------------------------------------------------
# 2. Authenticated API access
# ---------------------------------------------------------------------------
if ! api_json="$(jenkins_get "/api/json?tree=mode,quietingDown,numExecutors,nodeName")"; then
    case "$(http_code)" in
        401|403)
            record $STATUS_CRIT "api-auth" "HTTP $(http_code) — credentials rejected or missing (set JENKINS_USER and JENKINS_API_TOKEN)"
            ;;
        *)
            record $STATUS_CRIT "api-auth" "HTTP $(http_code) from /api/json"
            ;;
    esac
    log_only "=== Result: CRITICAL — API not usable, skipping remaining checks. ==="
    exit $STATUS_CRIT
fi

if ! jq -e . >/dev/null 2>&1 <<<"$api_json"; then
    record $STATUS_CRIT "api-auth" "/api/json returned a non-JSON body (is a proxy or login page intercepting the request?)"
    log_only "=== Result: CRITICAL — API returned unexpected content. ==="
    exit $STATUS_CRIT
fi

record $STATUS_OK "api-auth" "/api/json reachable and authenticated"

# ---------------------------------------------------------------------------
# 3. Quiet-down mode
# ---------------------------------------------------------------------------
quieting="$(jq -r '.quietingDown // false' <<<"$api_json")"
if [[ "$quieting" == "true" ]]; then
    record $STATUS_WARN "quiet-down" "controller is in quiet-down mode — no new builds will start"
else
    record $STATUS_OK "quiet-down" "accepting builds"
fi

# ---------------------------------------------------------------------------
# 4. Executors and node/agent status
# ---------------------------------------------------------------------------
if computer_json="$(jenkins_get "/computer/api/json?tree=busyExecutors,totalExecutors,computer[displayName,offline,temporarilyOffline,offlineCauseReason,numExecutors,monitorData[*]]")"; then
    busy="$(jq -r '.busyExecutors // 0' <<<"$computer_json")"
    total="$(jq -r '.totalExecutors // 0' <<<"$computer_json")"

    if (( total == 0 )); then
        record $STATUS_CRIT "executors" "no executors online — nothing can build"
    else
        pct="$(awk -v b="$busy" -v t="$total" 'BEGIN { printf "%.0f", (b / t) * 100 }')"
        if (( pct >= 100 )); then
            record $STATUS_WARN "executors" "all ${total} executors busy (${busy}/${total}) — builds will queue"
        else
            record $STATUS_OK "executors" "${busy}/${total} executors busy (${pct}%)"
        fi
    fi

    node_total="$(jq -r '.computer | length' <<<"$computer_json")"
    offline_nodes="$(jq -r '[.computer[] | select(.offline == true)] | length' <<<"$computer_json")"

    if (( offline_nodes > 0 )); then
        while IFS=$'\t' read -r name temp_offline reason; do
            [[ -z "$name" ]] && continue
            if [[ "$temp_offline" == "true" ]]; then
                record $STATUS_WARN "node-offline" "'${name}' taken offline on purpose${reason:+ — ${reason}}"
            else
                record $STATUS_CRIT "node-offline" "'${name}' is offline unexpectedly${reason:+ — ${reason}}"
            fi
        done < <(jq -r '.computer[] | select(.offline == true)
                        | [.displayName, (.temporarilyOffline | tostring), (.offlineCauseReason // "")]
                        | @tsv' <<<"$computer_json")
        record $STATUS_INFO "nodes" "${offline_nodes}/${node_total} node(s) offline (detail above)"
    else
        record $STATUS_OK "nodes" "all ${node_total} node(s) online"
    fi

    # Per-node disk, temp space, and agent round-trip time, when the
    # node monitors are reporting.
    disk_warn_bytes=$(( DISK_WARN_GB * 1024 * 1024 * 1024 ))
    while IFS=$'\t' read -r name disk tmpspace resp; do
        [[ -z "$name" ]] && continue
        if [[ "$disk" =~ ^[0-9]+$ ]] && (( disk < disk_warn_bytes )); then
            gb="$(awk -v b="$disk" 'BEGIN { printf "%.1f", b / 1073741824 }')"
            record $STATUS_WARN "node-disk" "'${name}' has ${gb}GB free (threshold ${DISK_WARN_GB}GB)"
        fi
        if [[ "$tmpspace" =~ ^[0-9]+$ ]] && (( tmpspace < disk_warn_bytes )); then
            gb="$(awk -v b="$tmpspace" 'BEGIN { printf "%.1f", b / 1073741824 }')"
            record $STATUS_WARN "node-tmp" "'${name}' has ${gb}GB free temp space (threshold ${DISK_WARN_GB}GB)"
        fi
        if [[ "$resp" =~ ^[0-9]+$ ]] && (( resp > RESPONSE_WARN_MS )); then
            record $STATUS_WARN "node-latency" "'${name}' agent round-trip ${resp}ms (threshold ${RESPONSE_WARN_MS}ms)"
        fi
    done < <(jq -r '
        .computer[]
        | [ .displayName,
            (.monitorData["hudson.node_monitors.DiskSpaceMonitor"].size // "" | tostring),
            (.monitorData["hudson.node_monitors.TemporarySpaceMonitor"].size // "" | tostring),
            (.monitorData["hudson.node_monitors.ResponseTimeMonitor"].average // "" | tostring) ]
        | @tsv' <<<"$computer_json")
else
    record $STATUS_WARN "executors" "could not read /computer/api/json (HTTP $(http_code))"
fi

# ---------------------------------------------------------------------------
# 5. Build queue
# ---------------------------------------------------------------------------
if queue_json="$(jenkins_get "/queue/api/json?tree=items[stuck,blocked,buildable,inQueueSince,why,task[name]]")"; then
    queue_len="$(jq -r '.items | length' <<<"$queue_json")"

    if (( queue_len >= QUEUE_CRIT )); then
        record $STATUS_CRIT "queue-depth" "${queue_len} items queued (critical threshold ${QUEUE_CRIT})"
    elif (( queue_len >= QUEUE_WARN )); then
        record $STATUS_WARN "queue-depth" "${queue_len} items queued (warn threshold ${QUEUE_WARN})"
    else
        record $STATUS_OK "queue-depth" "${queue_len} item(s) queued"
    fi

    stuck="$(jq -r '[.items[] | select(.stuck == true)] | length' <<<"$queue_json")"
    if (( stuck > 0 )); then
        while IFS=$'\t' read -r jobname why; do
            [[ -z "$jobname" ]] && continue
            record $STATUS_WARN "queue-stuck" "'${jobname}' flagged stuck${why:+ — ${why}}"
        done < <(jq -r '.items[] | select(.stuck == true)
                        | [(.task.name // "unknown"), (.why // "")] | @tsv' <<<"$queue_json")
    fi

    # Oldest item still waiting — a long wait usually means no agent can
    # satisfy its label, or capacity is exhausted.
    if (( queue_len > 0 )); then
        oldest_ms="$(jq -r '[.items[].inQueueSince] | min // 0' <<<"$queue_json")"
        if [[ "$oldest_ms" =~ ^[0-9]+$ ]] && (( oldest_ms > 0 )); then
            now_ms=$(( $(date +%s) * 1000 ))
            age_min=$(( (now_ms - oldest_ms) / 60000 ))
            if (( age_min >= QUEUE_AGE_WARN_MIN )); then
                oldest_job="$(jq -r '.items | min_by(.inQueueSince) | .task.name // "unknown"' \
                              <<<"$queue_json" 2>/dev/null || echo unknown)"
                record $STATUS_WARN "queue-age" "oldest queued item has waited ${age_min}min ('${oldest_job}', threshold ${QUEUE_AGE_WARN_MIN}min)"
            else
                record $STATUS_OK "queue-age" "oldest queued item waiting ${age_min}min"
            fi
        fi
    fi
else
    record $STATUS_WARN "queue-depth" "could not read /queue/api/json (HTTP $(http_code))"
fi

# ---------------------------------------------------------------------------
# 6. Metrics plugin healthchecks (optional)
# ---------------------------------------------------------------------------
if [[ -n "$JENKINS_METRICS_KEY" ]]; then
    if metrics_json="$(jenkins_get "/metrics/${JENKINS_METRICS_KEY}/healthcheck")"; then
        if jq -e . >/dev/null 2>&1 <<<"$metrics_json"; then
            unhealthy="$(jq -r '[to_entries[] | select(.value.healthy == false)] | length' <<<"$metrics_json")"
            if (( unhealthy > 0 )); then
                while IFS=$'\t' read -r cname cmsg; do
                    [[ -z "$cname" ]] && continue
                    record $STATUS_WARN "metrics" "healthcheck '${cname}' failing${cmsg:+ — ${cmsg}}"
                done < <(jq -r 'to_entries[] | select(.value.healthy == false)
                                | [.key, (.value.message // "")] | @tsv' <<<"$metrics_json")
            else
                checked="$(jq -r 'length' <<<"$metrics_json")"
                record $STATUS_OK "metrics" "all ${checked} plugin healthcheck(s) passing"
            fi
        else
            record $STATUS_WARN "metrics" "healthcheck endpoint returned a non-JSON body"
        fi
    else
        record $STATUS_WARN "metrics" "healthcheck endpoint returned HTTP $(http_code) (is JENKINS_METRICS_KEY correct?)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
case $OVERALL in
    0) summary="HEALTHY — all checks passed" ;;
    1) summary="DEGRADED — ${WARN_COUNT} warning(s)" ;;
    2) summary="CRITICAL — ${CRIT_COUNT} critical, ${WARN_COUNT} warning(s)" ;;
esac

log_only "=== Result: ${summary} ==="

if [[ "$QUIET" == true && $OVERALL -ne 0 ]]; then
    echo "$summary"
fi

exit $OVERALL
