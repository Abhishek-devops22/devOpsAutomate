#!/usr/bin/env bash
#
# cleanup-idle-resources.sh — find and remove idle Docker containers,
# images, and volumes on this machine, logging every deletion for later
# review.
#
# "Idle" means:
#   containers - status exited, dead, or created (never started)
#   images     - dangling (untagged); with -a, ANY image not referenced
#                by an existing container (running or stopped)
#   volumes    - not attached to any container (dangling)
#
# Usage:
#   ./scripts/docker/cleanup-idle-resources.sh [options]
#
# Options:
#   -n, --dry-run             Show what would be removed; delete nothing.
#   -y, --yes                 Skip the confirmation prompt.
#   -a, --all-unused-images   Also remove images not used by any container,
#                             not just dangling/untagged ones. More aggressive
#                             — can remove tagged images you built for later use.
#       --skip-containers     Don't touch containers.
#       --skip-images         Don't touch images.
#       --skip-volumes        Don't touch volumes.
#   -h, --help                Show this help and exit.
#
# Every resource removed (or that would be removed, under --dry-run) is
# appended to scripts/docker/logs/cleanup-YYYY-MM-DD.log with timestamp,
# resource type, ID, name, and outcome (DELETED / DRY-RUN / FAILED).
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/cleanup-$(date +%Y-%m-%d).log"

DRY_RUN=false
ASSUME_YES=false
ALL_UNUSED_IMAGES=false
SKIP_CONTAINERS=false
SKIP_IMAGES=false
SKIP_VOLUMES=false

usage() {
    sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true ;;
        -y|--yes) ASSUME_YES=true ;;
        -a|--all-unused-images) ALL_UNUSED_IMAGES=true ;;
        --skip-containers) SKIP_CONTAINERS=true ;;
        --skip-images) SKIP_IMAGES=true ;;
        --skip-volumes) SKIP_VOLUMES=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

mkdir -p "$LOG_DIR"

if ! command -v docker &>/dev/null; then
    echo "docker CLI not found in PATH." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "Could not reach the Docker daemon (is it running?)." >&2
    exit 1
fi

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Writes one line to both stdout and the log file, unformatted.
log_raw() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Writes one structured deletion-event line to both stdout and the log file.
log_event() {
    local type="$1" id="$2" name="$3" status="$4"
    printf '%s | %-10s | %-15s | %-45s | %s\n' \
        "$(timestamp)" "$type" "$id" "$name" "$status" | tee -a "$LOG_FILE"
}

log_raw ""
log_raw "=== Cleanup run started $(timestamp) (dry-run=${DRY_RUN}, all-unused-images=${ALL_UNUSED_IMAGES}) ==="

DELETED_COUNT=0
FAILED_COUNT=0
SPACE_BEFORE="$(docker system df --format '{{.Type}}: {{.Size}} (reclaimable {{.Reclaimable}})' 2>/dev/null || true)"

confirm() {
    local prompt="$1"
    if [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]]; then
        return 0
    fi
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Containers: exited, dead, or created-but-never-started
# ---------------------------------------------------------------------------
cleanup_containers() {
    local rows id name status
    rows="$(docker ps -a \
        --filter status=exited \
        --filter status=dead \
        --filter status=created \
        --format '{{.ID}}\t{{.Names}}\t{{.Status}}')"

    if [[ -z "$rows" ]]; then
        log_raw "Containers: none idle."
        return
    fi

    echo "Idle containers:"
    echo "$rows" | awk -F'\t' '{printf "  %-15s %-25s %s\n", $1, $2, $3}'

    if ! confirm "Remove the above $(echo "$rows" | wc -l | tr -d ' ') container(s)?"; then
        log_raw "Containers: skipped by user."
        return
    fi

    while IFS=$'\t' read -r id name status; do
        [[ -z "$id" ]] && continue
        if [[ "$DRY_RUN" == true ]]; then
            log_event "container" "$id" "$name" "DRY-RUN"
            continue
        fi
        if docker rm "$id" &>/dev/null; then
            log_event "container" "$id" "$name" "DELETED"
            ((DELETED_COUNT++)) || true
        else
            log_event "container" "$id" "$name" "FAILED"
            ((FAILED_COUNT++)) || true
        fi
    done <<< "$rows"
}

# ---------------------------------------------------------------------------
# Images: dangling by default; all-unused if -a/--all-unused-images
# ---------------------------------------------------------------------------
cleanup_images() {
    local rows id ref

    if [[ "$ALL_UNUSED_IMAGES" == true ]]; then
        local used_ids all_rows
        used_ids="$(docker ps -a -q | xargs -I{} docker inspect --format '{{.Image}}' {} 2>/dev/null | sort -u)"
        all_rows="$(docker images --format '{{.ID}}\t{{.Repository}}:{{.Tag}}' | sort -u)"
        rows="$(while IFS=$'\t' read -r iid iref; do
                    [[ -z "$iid" ]] && continue
                    if ! grep -qx "$iid" <<< "$used_ids"; then
                        printf '%s\t%s\n' "$iid" "$iref"
                    fi
                done <<< "$all_rows")"
    else
        rows="$(docker images -f dangling=true --format '{{.ID}}\t{{.Repository}}:{{.Tag}}')"
    fi

    if [[ -z "$rows" ]]; then
        log_raw "Images: none idle."
        return
    fi

    echo "Idle images:"
    echo "$rows" | awk -F'\t' '{printf "  %-15s %s\n", $1, $2}'

    if ! confirm "Remove the above $(echo "$rows" | wc -l | tr -d ' ') image(s)?"; then
        log_raw "Images: skipped by user."
        return
    fi

    while IFS=$'\t' read -r id ref; do
        [[ -z "$id" ]] && continue
        if [[ "$DRY_RUN" == true ]]; then
            log_event "image" "$id" "$ref" "DRY-RUN"
            continue
        fi
        if docker rmi "$id" &>/dev/null; then
            log_event "image" "$id" "$ref" "DELETED"
            ((DELETED_COUNT++)) || true
        else
            log_event "image" "$id" "$ref" "FAILED"
            ((FAILED_COUNT++)) || true
        fi
    done <<< "$rows"
}

# ---------------------------------------------------------------------------
# Volumes: not attached to any container
# ---------------------------------------------------------------------------
cleanup_volumes() {
    local names name

    names="$(docker volume ls -f dangling=true -q)"

    if [[ -z "$names" ]]; then
        log_raw "Volumes: none idle."
        return
    fi

    echo "Idle volumes:"
    echo "$names" | awk '{printf "  %s\n", $1}'

    if ! confirm "Remove the above $(echo "$names" | wc -l | tr -d ' ') volume(s)?"; then
        log_raw "Volumes: skipped by user."
        return
    fi

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if [[ "$DRY_RUN" == true ]]; then
            log_event "volume" "-" "$name" "DRY-RUN"
            continue
        fi
        if docker volume rm "$name" &>/dev/null; then
            log_event "volume" "-" "$name" "DELETED"
            ((DELETED_COUNT++)) || true
        else
            log_event "volume" "-" "$name" "FAILED"
            ((FAILED_COUNT++)) || true
        fi
    done <<< "$names"
}

[[ "$SKIP_CONTAINERS" == true ]] || cleanup_containers
[[ "$SKIP_IMAGES" == true ]] || cleanup_images
[[ "$SKIP_VOLUMES" == true ]] || cleanup_volumes

SPACE_AFTER="$(docker system df --format '{{.Type}}: {{.Size}} (reclaimable {{.Reclaimable}})' 2>/dev/null || true)"

log_raw "--- disk usage before ---"
log_raw "$SPACE_BEFORE"
log_raw "--- disk usage after ---"
log_raw "$SPACE_AFTER"
log_raw "=== Cleanup run finished $(timestamp): ${DELETED_COUNT} deleted, ${FAILED_COUNT} failed ==="

if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run only — nothing was deleted. Full log: $LOG_FILE"
else
    echo "Done. Full log: $LOG_FILE"
fi
