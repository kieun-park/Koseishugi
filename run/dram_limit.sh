#!/bin/bash
set -euo pipefail


TARGET_SIZE_GB="${TARGET_SIZE_GB:-4}"
NODE="${NODE:-0}"

usage() {
    cat <<EOF
Usage: $0 [--target-size-gb N] [--restore] [--node N]

  --target-size-gb N   Target physical size in GB for node (default: ${TARGET_SIZE_GB})
  --restore            Online all offline blocks on node (full restore)
  --node N             NUMA node to operate on (default: ${NODE})
  --help               Show this message
EOF
}

OFFLINE_TIMEOUT_S="${OFFLINE_TIMEOUT_S:-45}"
SKIP_BLOCKS_BELOW="${SKIP_BLOCKS_BELOW:-0}"

MODE="offline"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-size-gb) TARGET_SIZE_GB="${2:?--target-size-gb requires a value}"; shift 2 ;;
        --restore)        MODE="restore"; shift ;;
        --node)           NODE="${2:?--node requires a value}"; shift 2 ;;
        --help|-h)        usage; exit 0 ;;
        *)                echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ "$NODE" =~ ^[0-9]+$ ]] || { echo "--node must be a non-negative integer" >&2; exit 2; }
[[ "$TARGET_SIZE_GB" =~ ^[1-9][0-9]*$ ]] || { echo "--target-size-gb must be a positive integer" >&2; exit 2; }
[[ -d "/sys/devices/system/node/node${NODE}" ]] || { echo "NUMA node${NODE} not found" >&2; exit 1; }
command -v numactl >/dev/null || { echo "numactl is required" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || { echo "[mem-offline] Run as root (sudo)." >&2; exit 1; }

if [[ "$MODE" == "restore" ]]; then
    count=0
    for state_path in /sys/devices/system/node/node${NODE}/memory*/state; do
        grep -qx offline "$state_path" 2>/dev/null || continue
        blk=$(basename "$(dirname "$state_path")")
        printf '[mem-offline] onlining %s ...\n' "$blk"
        if echo "online" | tee "$state_path" > /dev/null; then
            (( count++ )) || true
            printf '[mem-offline] ✓ %s online\n' "$blk"
        else
            printf '[mem-offline] ✗ %s failed\n' "$blk"
        fi
    done
    echo "[mem-offline] Restored: ${count} blocks onlined"
    echo "[mem-offline] node${NODE} size now: $(numactl --hardware | awk "/^node ${NODE} size:/ { print \$4 }") MB"
    exit 0
fi

BLOCK_SIZE_BYTES=$(printf '%d' "0x$(cat /sys/devices/system/memory/block_size_bytes 2>/dev/null || echo 80000000)")
BLOCK_SIZE_MB=$(( BLOCK_SIZE_BYTES / 1024 / 1024 ))

get_node_size_mb() {
    numactl --hardware | awk "/^node ${NODE} size:/ { print \$4 }"
}

target_size_mb=$(( TARGET_SIZE_GB * 1024 ))
cur_size_mb=$(get_node_size_mb)

echo "[mem-offline] Memory block size  : ${BLOCK_SIZE_MB} MB"
echo "[mem-offline] node${NODE} size now : ${cur_size_mb} MB"
echo "[mem-offline] Target size        : ${target_size_mb} MB  (--target-size-gb ${TARGET_SIZE_GB})"

if (( cur_size_mb <= target_size_mb )); then
    echo "[mem-offline] Already at or below target. Nothing to do."
    exit 0
fi

need_mb=$(( cur_size_mb - target_size_mb ))
need_blocks=$(( (need_mb + BLOCK_SIZE_MB - 1) / BLOCK_SIZE_MB ))
echo "[mem-offline] Need to offline ≈ ${need_mb} MB (~${need_blocks} blocks)"
echo ""

mapfile -t blk_links < <(
    ls -d /sys/devices/system/node/node${NODE}/memory* 2>/dev/null | \
    sort -t 'y' -k2 -rn
)

if [[ ${#blk_links[@]} -eq 0 ]]; then
    echo "[mem-offline] ERROR: no memory blocks found for node${NODE}" >&2
    exit 1
fi

offlined_mb=0
offlined_count=0
skipped_count=0

for blk_link in "${blk_links[@]}"; do
    cur_size_mb=$(get_node_size_mb)
    if (( cur_size_mb <= target_size_mb )); then
        break
    fi

    actual=$(readlink -f "$blk_link")
    blk=$(basename "$actual")
    state_path="${actual}/state"

    [[ -f "$state_path" ]] || continue
    state=$(cat "$state_path")
    [[ "$state" == "online" ]] || continue

    blk_idx="${blk#memory}"
    if [[ "$blk_idx" =~ ^[0-9]+$ ]] && (( blk_idx < SKIP_BLOCKS_BELOW )); then
        skipped_count=$(( skipped_count + 1 ))
        printf '[mem-offline] - %-12s  skip (below SKIP_BLOCKS_BELOW=%s)\n' "$blk" "$SKIP_BLOCKS_BELOW"
        continue
    fi

    if timeout "${OFFLINE_TIMEOUT_S}" tee "$state_path" <<<"offline" >/dev/null 2>&1; then
        offlined_mb=$(( offlined_mb + BLOCK_SIZE_MB ))
        offlined_count=$(( offlined_count + 1 ))
        cur_sz=$(get_node_size_mb)
        printf '[mem-offline] ✓ %-12s  +%4dMB offlined  | node%s size: %d MB\n' \
               "$blk" "$BLOCK_SIZE_MB" "$NODE" "$cur_sz"
    else
        rc=$?
        skipped_count=$(( skipped_count + 1 ))
        if (( rc == 124 )); then
            printf '[mem-offline] ✗ %-12s  skip (gave up after %ss — pinned pages)\n' "$blk" "$OFFLINE_TIMEOUT_S"
        else
            printf '[mem-offline] ✗ %-12s  skip (unmovable pages)\n' "$blk"
        fi
    fi
done

echo ""
echo "[mem-offline] ============================================================"
echo "[mem-offline]   Offlined : ${offlined_count} blocks  (${offlined_mb} MB)"
echo "[mem-offline]   Skipped  : ${skipped_count} blocks"
echo "[mem-offline]   node${NODE} size now: $(get_node_size_mb) MB  (target: ${target_size_mb} MB)"
echo "[mem-offline] ============================================================"
