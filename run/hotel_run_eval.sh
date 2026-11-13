#!/bin/bash
set -Eeuo pipefail


_REAL_USER="${SUDO_USER:-${USER}}"
_REAL_HOME="$(getent passwd "${_REAL_USER}" | cut -d: -f6 2>/dev/null || echo "${HOME}")"
_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

DSB_DIR="${DSB_DIR:-${_REAL_HOME}/DeathStarBench/hotelReservation}"
LOG_DIR="${LOG_DIR:-${_SCRIPT_DIR}/logs}"
mkdir -p "$LOG_DIR"

PLACEMENT_ENV="${PLACEMENT_ENV:-${_SCRIPT_DIR}/placement.env}"
[[ -f "$PLACEMENT_ENV" ]] && source "$PLACEMENT_ENV"
PLACEMENT="${PLACEMENT:-top5}"

DIST_MODE="${DIST_MODE:-off}"
REMOTE_B="${REMOTE_B:-}"
REMOTE_AGENT="${REMOTE_AGENT:-}"
REMOTE_SERVICES="${REMOTE_SERVICES:-geo profile rate reservation search}"
VERIFY_REMOTE_SVCS="${VERIFY_REMOTE_SVCS:-srv-geo srv-profile srv-rate srv-reservation srv-search}"
REMOTE_RESTORE_VOLS="${REMOTE_RESTORE_VOLS:-}"
HOST_A_IP="${HOST_A_IP:-}"
HOST_B_IP="${HOST_B_IP:-}"

TARGET_URL="${TARGET_URL:-${HOST_A_IP:+http://${HOST_A_IP}:5000}}"
WRK_BIN="${WRK_BIN:-${_REAL_HOME}/DeathStarBench/wrk2/wrk}"
APP="${APP:-premeasure-queue-rss_hotel}"
WRK_SCRIPT_TYPE="${WRK_SCRIPT_TYPE:-mixed}"
WRK_SCRIPT="${WRK_SCRIPT:-${DSB_DIR}/wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua}"
WRK_ENDPOINT="${WRK_ENDPOINT:-${TARGET_URL}}"   # hotel mixed workload uses base URL
RPS_START="${RPS_START:-2000}"
RPS_END="${RPS_END:-2000}"
RPS_STEP="${RPS_STEP:-200}"
MEM_SIZE_GB="${MEM_SIZE_GB:-0}"
MEM_SIZE_GB_NODE2="${MEM_SIZE_GB_NODE2:-0}"

TIER_ONCE="${TIER_ONCE:-off}"

HTMM_ENABLE="${HTMM_ENABLE:-off}"
HTMM_NODE0_MB="${HTMM_NODE0_MB:-0}"
WMARK_APPLY="${WMARK_APPLY:-on}"

HTMM_WARMUP="${HTMM_WARMUP:-off}"
NODE0_WMARK_PCT="${NODE0_WMARK_PCT:-10}"   # target ~low watermark as % of node0 size
WMARK_BAND_PCT="${WMARK_BAND_PCT:-1}"      # ~high = ~low + band (controls kswapd reclaim range)
MEM_HOLDER_GB="${MEM_HOLDER_GB:-1.75}"  # 0 = disabled (3, 2.5, 1.5, 1 are used in experiments)

NUMA_BALANCING="${NUMA_BALANCING:-3}"      # 3 = AutoNUMA + MEMORY_TIERING, 0 = off (MEMTIS)
DEMOTION_ENABLED="${DEMOTION_ENABLED:-1}"  # 1 = on, 0 = off (MEMTIS)

WRK_T="${WRK_T:-16}"
WRK_C="${WRK_C:-512}"
WRK_C_AUTO="${WRK_C_AUTO:-off}"

DOCKER_CPU_NODE="${DOCKER_CPU_NODE:-0}"
SVCMEM_NODE="${SVCMEM_NODE:-2}"
GATEWAY_MEM_NODE="${GATEWAY_MEM_NODE:-0}"
GATEWAY_SERVICES="${GATEWAY_SERVICES:-frontend}"
CLIENT_CPU_NODE="${CLIENT_CPU_NODE:-1}"
CLIENT_CPUSET="${CLIENT_CPUSET:-}"
CLIENT_MEM_NODE="${CLIENT_MEM_NODE:-1}"
SVC_CPUSET="${SVC_CPUSET:-$(cat /sys/devices/system/node/node${DOCKER_CPU_NODE}/cpulist 2>/dev/null || true)}"

BIND_SCRIPT="${BIND_SCRIPT:-${_SCRIPT_DIR}/numa_bind.sh}"
OFFLINE_SCRIPT="${OFFLINE_SCRIPT:-${_SCRIPT_DIR}/dram_limit.sh}"

SLEEP_AFTER_UP="${SLEEP_AFTER_UP:-15}"
SLEEP_AFTER_RECREATE="${SLEEP_AFTER_RECREATE:-10}"
SLEEP_AFTER_BIND="${SLEEP_AFTER_BIND:-2}"
SLEEP_BETWEEN_POINTS="${SLEEP_BETWEEN_POINTS:-5}"

WARMUP_ENABLED="${WARMUP_ENABLED:-on}"
WARMUP_DURATION_S="${WARMUP_DURATION_S:-400}"
MEASURE_DURATION_S="${MEASURE_DURATION_S:-180}"

DB_SNAPSHOT_DIR="${DB_SNAPSHOT_DIR:-${_REAL_HOME}/db_snapshot_baseline_hotel}"
DB_SNAPSHOT_ENABLED="${DB_SNAPSHOT_ENABLED:-on}"

ORIG_NUMA_BALANCING=""
ORIG_DEMOTION_ENABLED=""
ORIG_ZONE_RECLAIM_MODE=""
ORIG_MIN_FREE_KBYTES=""
ORIG_WSF=""
VMSTAT_TMP_BASE="/tmp/eval_vmstat_$$"

RUN_LOG=""
log() {
    local msg="[hotel_run_eval] $(date '+%H:%M:%S') $*"
    if [[ -t 1 ]]; then printf '\r\033[K%s\n' "$msg"
    else printf '%s\n' "$msg"; fi
    if [[ -n "${RUN_LOG:-}" ]]; then printf '%s\n' "$msg" >> "$RUN_LOG"; fi
}
die() { echo "[hotel_run_eval][FATAL] $*" >&2; exit 1; }

_MONGO_VOLUMES=(
    geo
    profile
    rate
    recommendation
    reservation
    user
    review
    attractions
)
_ALL_DB_VOLUMES=( "${_MONGO_VOLUMES[@]}" )

EXP_MODE="run"
for _arg in "$@"; do
    case "$_arg" in
        --snapshot) EXP_MODE="snapshot" ;;
        --setup)    EXP_MODE="setup" ;;
        --teardown) EXP_MODE="teardown" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--snapshot | --setup | --teardown | --help]

  (no args)   Run RPS sweep experiment (RPS_START..RPS_END step RPS_STEP).

  --snapshot  Capture current DB volume state to DB_SNAPSHOT_DIR and exit.
              Run once after initial stack bring-up (Go services auto-seed MongoDB).

  --setup     Bring the stack up (same sequence a sweep uses), verify it, and
              leave it running. Use this before any manual wrk2 / ss / sar
              probing — a sweep tears the stack down when it finishes, which is
              why a manual run afterwards gets "Connection refused".

  --teardown  Stop the stack on both hosts.

Key variables (override via environment):
  APP=<log-label>            WRK_SCRIPT_TYPE=mixed
  MEM_SIZE_GB=${MEM_SIZE_GB}               RPS_START=${RPS_START}  RPS_END=${RPS_END}  RPS_STEP=${RPS_STEP}
  WARMUP_DURATION_S=${WARMUP_DURATION_S}      MEASURE_DURATION_S=${MEASURE_DURATION_S}
EOF
            exit 0
            ;;
        *) die "Unknown argument: $_arg" ;;
    esac
done

[[ "$(uname -s)" == "Linux" ]] || die "Linux is required"
[[ -f "${DSB_DIR}/docker-compose.yml" ]] || die "Missing ${DSB_DIR}/docker-compose.yml; see run/README.md"
[[ "$DIST_MODE" == "on" || "$DIST_MODE" == "off" ]] || die "DIST_MODE must be on or off"
if [[ "$DIST_MODE" == "on" ]]; then
    [[ -n "$REMOTE_B" && -n "$REMOTE_AGENT" && -n "${HOST_A_IP:-}" && -n "$HOST_B_IP" ]] || die "Set REMOTE_B, REMOTE_AGENT (absolute path), HOST_A_IP, and HOST_B_IP for distributed runs"
    [[ "$REMOTE_AGENT" == /* ]] || die "REMOTE_AGENT must be an absolute path on Server B"
fi
if [[ "$EXP_MODE" == "run" || "$EXP_MODE" == "setup" ]]; then
    [[ -n "$TARGET_URL" ]] || die "Set TARGET_URL or HOST_A_IP to the frontend address"
    [[ -n "$SVC_CPUSET" ]] || die "Set SVC_CPUSET for the service CPUs"
fi
if [[ "$EXP_MODE" == "run" ]]; then
    [[ -x "$WRK_BIN" ]] || die "wrk2 executable not found: $WRK_BIN"
    [[ -r "$WRK_SCRIPT" ]] || die "wrk2 Lua script not found: $WRK_SCRIPT"
    [[ "$RPS_START" =~ ^[1-9][0-9]*$ && "$RPS_END" =~ ^[1-9][0-9]*$ && "$RPS_STEP" =~ ^[1-9][0-9]*$ ]] || die "RPS_START, RPS_END, and RPS_STEP must be positive integers"
    (( RPS_START <= RPS_END )) || die "RPS_START must not exceed RPS_END"
fi
REMOTE_DSB_DIR="${REMOTE_DSB_DIR:-${DSB_DIR}}"
REMOTE_DB_SNAPSHOT_DIR="${REMOTE_DB_SNAPSHOT_DIR:-${DB_SNAPSHOT_DIR}}"

ORIG_USER="${SUDO_USER:-$USER}"
ORIG_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6)"
[[ -n "$ORIG_HOME" ]] || die "Cannot resolve home for '$ORIG_USER'"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-$ORIG_HOME/.docker}"

sudo env DOCKER_CONFIG="$DOCKER_CONFIG_DIR" docker compose version >/dev/null 2>&1 || \
    die "Docker Compose v2 not usable under sudo"

_COMPOSE_FILES=(-f docker-compose.yml)
[[ -f "${DSB_DIR}/docker-compose.override.yml" ]] && _COMPOSE_FILES+=(-f docker-compose.override.yml)

compose() {
    sudo env DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
        docker compose "${_COMPOSE_FILES[@]}" "$@"
}
cdown()         { compose down --remove-orphans >/dev/null 2>&1 || true; }
crecreate_all() { compose up -d --force-recreate; }

cup_on_cxl() {
    sudo numactl --cpunodebind="$DOCKER_CPU_NODE" \
        env DOCKER_CONFIG="$DOCKER_CONFIG_DIR" \
        docker compose "${_COMPOSE_FILES[@]}" up -d
}

_ssh() {
    local opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${_REAL_USER:-}" && "$_REAL_USER" != "root" ]]; then
        sudo -u "$_REAL_USER" ssh "${opts[@]}" "$@"
    else
        ssh "${opts[@]}" "$@"
    fi
}

_rb_command() {
    local -a remote_env=(env APP_KIND=hotel "SERVICES=$REMOTE_SERVICES"
        "DSB_DIR=$REMOTE_DSB_DIR" "DB_SNAPSHOT_DIR=$REMOTE_DB_SNAPSHOT_DIR"
        "HOST_A_IP=${HOST_A_IP:-}" "HOST_B_IP=$HOST_B_IP")
    [[ -z "${REMOTE_SVC_CPUSET:-}" ]] || remote_env+=("SVC_CPUSET=$REMOTE_SVC_CPUSET")
    printf '%q ' "${remote_env[@]}" bash "$REMOTE_AGENT" "$@"
}
rb() {
    [[ "$DIST_MODE" == "on" ]] || return 0
    _ssh "$REMOTE_B" "$(_rb_command "$@")" 2>&1 \
        | tee -a "${RUN_LOG:-/dev/null}"
}
rb_try() { rb "$@" || true; }

reset_consul() {
    compose up -d --force-recreate --renew-anon-volumes consul
    sleep 10
    compose restart attractions recommendation review user frontend
    sleep 10
    log "[consul] wiped; Server A services re-registered"
}

verify_registrations() {
    [[ "$DIST_MODE" == "on" ]] || return 0
    command -v jq >/dev/null 2>&1 || die "jq required for registration check (apt install jq)"
    local s n addr fail=0
    for s in $VERIFY_REMOTE_SVCS; do
        addr="$(curl -s "http://localhost:8500/v1/catalog/service/${s}" | jq -r '.[].ServiceAddress')"
        n="$(printf '%s\n' "$addr" | grep -c . || true)"
        if [[ "$n" -ne 1 || "$addr" != "$HOST_B_IP" ]]; then
            log "[verify][FAIL] ${s}: instances=${n} addr=$(echo $addr | tr '\n' ' ')"
            fail=1
        fi
    done
    [[ "$fail" -eq 0 ]] || die "consul registration check failed — aborting before measurement"

    local out code t
    out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
        "${TARGET_URL}/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" || true)"
    code="${out%% *}"; t="${out##* }"
    [[ -n "$code" ]] || die "e2e check failed: no response from ${TARGET_URL}"
    [[ "$code" == "200" ]] || die "e2e check failed: HTTP ${code}"
    awk "BEGIN{exit !($t < 1.0)}" || die "e2e latency ${t}s — still routing to a dead backend"
    log "[verify] OK  1 instance each @${HOST_B_IP}  e2e=200 ${t}s"
}

_wrk_c_for() {
    local rps="$1" c
    [[ "$WRK_C_AUTO" == "on" ]] || { echo "$WRK_C"; return; }
    c=$(( rps / 2 )); (( c < 64 )) && c=64; (( c > WRK_C )) && c=$WRK_C
    echo "$c"
}

pin_service_mem() {
    local svc="$1" mem_node="$2" cid
    cid="$(compose ps -q "$svc" 2>/dev/null || true)"
    [[ -z "$cid" ]] && { log "[WARN] no container for '$svc'"; return 0; }
    sudo docker update --cpuset-mems="$mem_node" "$cid" >/dev/null
}

apply_cpuset_mems() {
    local mems="$1"
    { sudo DEFAULT_MEM_NODE="$mems" DEFAULT_CPUSET="$SVC_CPUSET" bash "$BIND_SCRIPT" || \
        die "NUMA binding failed"; } 2>&1 | \
        tee -a "${RUN_LOG:-/dev/null}"
    for svc in $GATEWAY_SERVICES; do
        pin_service_mem "$svc" "$GATEWAY_MEM_NODE"
    done
    echo "$mems" | sudo tee /sys/fs/cgroup/system.slice/cpuset.mems >/dev/null 2>&1 || true
    log "[mem-policy] cpuset.mems=${mems}"
}

_get_compose_project() {
    compose config --format json | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])'
}

snapshot_db_volumes() {
    local project; project="$(_get_compose_project)"
    log "[db-snapshot] project=${project}  dst=${DB_SNAPSHOT_DIR}"
    sudo mkdir -p "$DB_SNAPSHOT_DIR"
    local vol_base; vol_base="$(sudo docker info --format '{{.DockerRootDir}}')/volumes"
    for vol in "${_ALL_DB_VOLUMES[@]}"; do
        local src="${vol_base}/${project}_${vol}/_data"
        local dst="${DB_SNAPSHOT_DIR}/${vol}"
        if [[ ! -d "$src" ]]; then
            log "[db-snapshot][WARN] not found: $src — skipped"
            continue
        fi
        log "[db-snapshot] $vol ..."
        sudo mkdir -p "$dst"
        sudo rsync -a --delete "$src/" "$dst/"
    done
    log "[db-snapshot] done ($(sudo du -sh "$DB_SNAPSHOT_DIR" 2>/dev/null | cut -f1))"
}

restore_db_volumes() {
    [[ "$DB_SNAPSHOT_ENABLED" == "on" ]] || return 0
    if [[ ! -d "$DB_SNAPSHOT_DIR" ]]; then
        die "Snapshot directory missing: ${DB_SNAPSHOT_DIR}; prepare the dataset and run --snapshot first"
    fi
    local project; project="$(_get_compose_project)"
    log "[db-restore] project=${project}  src=${DB_SNAPSHOT_DIR}"
    local vol_base; vol_base="$(sudo docker info --format '{{.DockerRootDir}}')/volumes"
    for vol in "${_ALL_DB_VOLUMES[@]}"; do
        local src="${DB_SNAPSHOT_DIR}/${vol}"
        local dst_vol="${project}_${vol}"
        local dst="${vol_base}/${dst_vol}/_data"
        if [[ ! -d "$src" ]]; then
            die "Required snapshot missing: $src"
        fi
        sudo docker volume inspect "$dst_vol" >/dev/null 2>&1 || \
            sudo docker volume create "$dst_vol" >/dev/null
        if [[ ! -d "$dst" ]]; then
            die "Volume directory missing after create: $dst"
        fi
        log "[db-restore] $vol ..."
        sudo rsync -a --delete "$src/" "$dst/"
    done
    log "[db-restore] done"
}

save_numa_settings() {
    ORIG_NUMA_BALANCING="$(sysctl -n kernel.numa_balancing 2>/dev/null || echo '')"
    local dp="/sys/kernel/mm/numa/demotion_enabled"
    ORIG_DEMOTION_ENABLED="$([[ -f "$dp" ]] && cat "$dp" || echo '')"
    ORIG_ZONE_RECLAIM_MODE="$(sysctl -n vm.zone_reclaim_mode 2>/dev/null || echo '')"
    ORIG_MIN_FREE_KBYTES="$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo '')"
    ORIG_WSF="$(sysctl -n vm.watermark_scale_factor 2>/dev/null || echo '')"
}

restore_numa_settings() {
    [[ -n "${ORIG_NUMA_BALANCING:-}"    ]] && sudo sysctl -w "kernel.numa_balancing=${ORIG_NUMA_BALANCING}" >/dev/null 2>&1 || true
    local dp="/sys/kernel/mm/numa/demotion_enabled"
    [[ -n "${ORIG_DEMOTION_ENABLED:-}" && -f "$dp" ]] && echo "$ORIG_DEMOTION_ENABLED" | sudo tee "$dp" >/dev/null || true
    [[ -n "${ORIG_ZONE_RECLAIM_MODE:-}" ]] && sudo sysctl -w "vm.zone_reclaim_mode=${ORIG_ZONE_RECLAIM_MODE}" >/dev/null 2>&1 || true
    [[ -n "${ORIG_MIN_FREE_KBYTES:-}"   ]] && sudo sysctl -w "vm.min_free_kbytes=${ORIG_MIN_FREE_KBYTES}" >/dev/null 2>&1 || true
    [[ -n "${ORIG_WSF:-}"               ]] && sudo sysctl -w "vm.watermark_scale_factor=${ORIG_WSF}" >/dev/null 2>&1 || true
    ORIG_NUMA_BALANCING=""; ORIG_DEMOTION_ENABLED=""
    ORIG_ZONE_RECLAIM_MODE=""
    ORIG_MIN_FREE_KBYTES=""; ORIG_WSF=""
}

set_node0_watermark() {
    local node0_mb
    node0_mb=$(numactl --hardware 2>/dev/null | awk '/^node 0 size:/{print $4}')
    [[ "${node0_mb:-0}" -le 0 ]] && { log "[wmark] cannot read node0 size — skipping"; return 0; }

    local node0_managed
    node0_managed=$(awk '/Node 0, zone/{z=$0} z~/Normal/ && /managed/{print $2; z=""; exit}' \
        /proc/zoneinfo 2>/dev/null || echo 0)
    [[ "${node0_managed:-0}" -le 0 ]] && { log "[wmark] cannot read node0 managed pages — skipping"; return 0; }

    local target_low_mb=$(( node0_mb * NODE0_WMARK_PCT / 100 ))
    local target_high_mb=$(( node0_mb * (NODE0_WMARK_PCT + WMARK_BAND_PCT) / 100 ))

    if [[ "${NODE0_WMARK_PCT:-0}" -gt 0 ]]; then
        [[ "$target_low_mb" -ge "$target_high_mb" ]] && \
            { log "[wmark] WMARK_BAND_PCT must be > 0 — skipping"; return 0; }

        local wmin_mb=$(( 2 * target_low_mb - target_high_mb ))
        [[ "$wmin_mb" -lt 0 ]] && wmin_mb=0

        local total_normal_managed
        total_normal_managed=$(awk '/zone/{z=$0} z~/Normal/ && /managed/{s+=$2} END{print s+0}' \
            /proc/zoneinfo 2>/dev/null || echo 0)
        [[ "${total_normal_managed:-0}" -le 0 ]] && total_normal_managed=$node0_managed

        local new_min_free_kb=$(( wmin_mb * 1024 * total_normal_managed / node0_managed ))
        [[ "$new_min_free_kb" -lt 65536 ]] && new_min_free_kb=65536
        sudo sysctl -w "vm.min_free_kbytes=${new_min_free_kb}" >/dev/null
        log "[wmark] node0=${node0_mb}MB  ~low=${target_low_mb}MB  ~high=${target_high_mb}MB  ~min=${wmin_mb}MB  min_free_kbytes=${new_min_free_kb}"
    fi

    local step_p
    if [[ "${NODE0_WMARK_PCT:-0}" -gt 0 ]]; then
        step_p=$(( (target_high_mb - target_low_mb) * 256 ))
    else
        local wmin_pages
        wmin_pages=$(awk '/Node 0, zone/{z=$0} z~/Normal/ && /  min /{print $2; z=""; exit}' \
            /proc/zoneinfo 2>/dev/null || echo 0)
        step_p=$(( (target_high_mb * 256 - wmin_pages) / 2 ))
    fi
    [[ "$step_p" -le 0 ]] && step_p=1
    local wsf=$(( step_p * 10000 / node0_managed ))
    [[ "$wsf" -lt 1   ]] && wsf=1
    [[ "$wsf" -gt 3000 ]] && wsf=3000
    sudo sysctl -w "vm.watermark_scale_factor=${wsf}" >/dev/null
    if [[ "${NODE0_WMARK_PCT:-0}" -le 0 ]]; then
        log "[wmark] node0=${node0_mb}MB  ~high=${target_high_mb}MB  wsf=${wsf}"
    fi
}

apply_numa_settings() {
    sudo sysctl -w "kernel.numa_balancing=${NUMA_BALANCING}" >/dev/null
    log "[numa] numa_balancing=${NUMA_BALANCING} (3=MEMORY_TIERING, 0=off for MEMTIS)"

    local dp="/sys/kernel/mm/numa/demotion_enabled"
    if [[ -f "$dp" ]]; then
        echo "$DEMOTION_ENABLED" | sudo tee "$dp" >/dev/null
        local _v; _v="$(cat "$dp" 2>/dev/null)"
        log "[numa] demotion_enabled=${DEMOTION_ENABLED} (readback: ${_v})"
        if [[ "$DEMOTION_ENABLED" == "1" && ( "$_v" == "false" || "$_v" == "0" ) ]]; then
            log "[WARN] demotion_enabled not set — pgdemote_kswapd will stay 0"
        fi
    else
        log "[WARN] ${dp} not found (expected on the MEMTIS kernel)"
    fi

    local sp="/proc/sys/vm/numa_slow_tier_nodes"
    if [[ -f "$sp" ]]; then
        echo 4 | sudo tee "$sp" >/dev/null
        log "[numa] numa_slow_tier_nodes=4 (node2=CXL)"
    else
        log "[WARN] ${sp} not found — memory-tiers patch missing"
    fi

    sudo sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
    log "[misc] zone_reclaim_mode=0"

}

_online_all_node0() {
    local count=0 sp
    for sp in /sys/devices/system/memory/memory*/state; do
        grep -qx offline "$sp" 2>/dev/null || continue
        local blk; blk=$(basename "$(dirname "$sp")")
        [[ -e "/sys/devices/system/node/node0/${blk}" ]] || continue
        echo "online" | sudo tee "$sp" >/dev/null 2>&1 && (( count++ )) || true
    done
    log "[offline] node0 onlined: ${count} blocks"
}

cleanup() {
    log "Cleaning up..."
    stop_mem_holder
    if [[ "$DIST_MODE" == "on" ]]; then
        if [[ "${MEM_SIZE_GB:-0}" -gt 0 && "$TIER_ONCE" != "on" ]]; then
            rbq online >/dev/null 2>&1 || true
        fi
    else
        restore_numa_settings
        [[ "${MEM_SIZE_GB:-0}" -gt 0 ]] && _online_all_node0
    fi
    rm -f "${VMSTAT_TMP_BASE}"_*.snap "${VMSTAT_TMP_BASE}"_nodefree_* 2>/dev/null || true
    log "Cleanup complete."
}
trap 'log "[FATAL] line $LINENO failed: $BASH_COMMAND"' ERR
trap cleanup EXIT INT TERM

VMSTAT_PATTERN='^(numa_|pgdemote_|pgmigrate_|pgpromote_|kswapd_|pgsteal_|pgscan_|pgrefill|pswp|pgactivate|pglazyfreed|compact_|thp_)'

rbq() { _ssh "$REMOTE_B" "$(_rb_command "$@")" 2>/dev/null; }

_vmstat_src() {
    if [[ "$DIST_MODE" == "on" ]]; then rbq vmstat
    else cat /proc/vmstat; fi
}
_numactl_hw_src() {
    if [[ "$DIST_MODE" == "on" ]]; then rbq meminfo
    else numactl --hardware; fi
}

snap_vmstat() { _vmstat_src | grep -E "$VMSTAT_PATTERN" > "$1"; }

snap_node_free() {
    if [[ "$DIST_MODE" == "on" ]]; then
        rbq nodefree > "$1"
    else
        numactl --hardware | awk '/^node [0-9]+ free:/ { print $2, $4 }' > "$1"
    fi
}

log_node_rss_delta() {
    local snap_before="$1" out="$2"
    local after_src; after_src="$(mktemp "${VMSTAT_TMP_BASE}_nodefree_XXXXXX")"
    snap_node_free "$after_src"
    {
        printf '\n# ---- node ΔRSS (measure)%s @ %s ----\n' \
            "$([[ "$DIST_MODE" == "on" ]] && echo ' [Server B]')" "$(date --iso-8601=seconds)"
        cat "$after_src" | \
        while read -r nd after_mb; do
            before_mb=$(awk -v n="$nd" '$1==n { print $2 }' "$snap_before" 2>/dev/null || echo 0)
            delta=$(( before_mb - after_mb ))
            printf '#   node%s  free_before=%dMB  free_after=%dMB  delta_RSS=%+dMB\n' \
                "$nd" "$before_mb" "$after_mb" "$delta"
        done
    } >> "$out"
    rm -f "$after_src"
}

collect_numa_stats_delta() {
    local before="$1" out="$2" label="$3"
    local after="${VMSTAT_TMP_BASE}_after.snap"
    _vmstat_src | grep -E "$VMSTAT_PATTERN" > "$after"
    {
        printf '\n# ---- %s%s ----\n' "$label" \
            "$([[ "$DIST_MODE" == "on" ]] && echo ' [Server B]')"
        printf '#   %-42s  %14s  %14s\n' "counter" "absolute" "delta"
        while IFS=' ' read -r key val; do
            local bval delta
            bval=$(awk -v k="$key" '$1==k { print $2; exit }' "$before" 2>/dev/null || echo 0)
            delta=$(( val - bval ))
            printf '#   %-42s  %14d  %+14d\n' "$key" "$val" "$delta"
        done < "$after"
    } >> "$out"
}

collect_node_meminfo() {
    local out="$1"
    if [[ "$DIST_MODE" == "on" ]]; then
        {
            printf '\n# ---- node meminfo [Server B] [%s] ----\n' "$(date --iso-8601=seconds)"
            rbq meminfo | sed 's/^/#   /'
            printf '#\n# -- service RSS --\n'
            rbq rss | sed 's/^/#   /'
        } >> "$out"
        return 0
    fi
    {
        printf '\n# ---- node meminfo [%s] ----\n' "$(date --iso-8601=seconds)"
        numactl --hardware | grep -E '^node [0-9]+ (size|free):' | sed 's/^/#   /'
        for nd in /sys/devices/system/node/node*/meminfo; do
            [[ -f "$nd" ]] || continue
            printf '#\n# -- %s --\n' "$(basename "$(dirname "$nd")")"
            grep -E '(MemTotal|MemFree|MemUsed|Active|Inactive|AnonPages|FilePages|Slab)' \
                 "$nd" | sed 's/^/#   /'
        done
        command -v numastat >/dev/null 2>&1 && \
            { printf '#\n# -- numastat --\n'; numastat 2>/dev/null | sed 's/^/#   /' || true; }
    } >> "$out"
}

reset_stack() {
    local rps="$1"
    log "------------------------------------------------------------"
    log "RESET  rps=${rps}  dist=${DIST_MODE}"
    log "------------------------------------------------------------"
    cd "$DSB_DIR"

    rb down5
    cdown
    sleep 2
    restore_db_volumes            # all 8 mongo volumes live on Server A

    if [[ "$DIST_MODE" == "on" ]]; then
        stop_mem_holder
        if [[ "$TIER_ONCE" == "on" ]]; then
            local _n0 _n2
            _n0="$(rbq nodesize 0 2>/dev/null || echo 0)"
            _n2="$(rbq nodesize 2 2>/dev/null || echo 0)"
            log "[tier] TIER_ONCE=on — pre-set sizes: node0=${_n0}MB node2=${_n2}MB"
            if [[ "${MEM_SIZE_GB}" -gt 0 && "${_n0:-0}" -gt $(( MEM_SIZE_GB * 1536 )) ]]; then
                die "node0 is ${_n0}MB, expected ~$(( MEM_SIZE_GB * 1024 ))MB. Run this on Server B first: bash ${REMOTE_AGENT} tier ${MEM_SIZE_GB} ${MEM_SIZE_GB_NODE2}"
            fi
        else
            rb tier "${MEM_SIZE_GB}" "${MEM_SIZE_GB_NODE2}"
        fi
        if [[ "$WMARK_APPLY" == "on" ]]; then
            rb watermark "${NODE0_WMARK_PCT}" "${WMARK_BAND_PCT}"
        else
            rb_try wmark-default
        fi
        start_mem_holder

        cup_on_cxl
        sleep "$SLEEP_AFTER_UP"

        compose rm -sf $REMOTE_SERVICES >/dev/null 2>&1 || true
        reset_consul
        [[ -n "$REMOTE_RESTORE_VOLS" ]] && rb restore-db "$REMOTE_RESTORE_VOLS"
        if [[ "$HTMM_ENABLE" == "on" ]]; then rb_try htmm-parent; fi
        rb up5
        sleep "$SLEEP_AFTER_RECREATE"
        rb cpuset "${SVCMEM_NODE}"
        for svc in $GATEWAY_SERVICES; do pin_service_mem "$svc" "$GATEWAY_MEM_NODE"; done
        sleep "$SLEEP_AFTER_BIND"
        if [[ "$HTMM_ENABLE" == "on" && "$EXP_MODE" == "setup" ]]; then
            rb htmm on "${HTMM_NODE0_MB}"
            rb_try htmm-status
        fi
        rb verify
        verify_registrations
        return 0
    fi

    if [[ -x "${OFFLINE_SCRIPT}" && "${MEM_SIZE_GB}" -gt 0 ]]; then
        _online_all_node0
        log "[offline] Offlining node0 to size=${MEM_SIZE_GB}GB ..."
        sudo "${OFFLINE_SCRIPT}" --target-size-gb "${MEM_SIZE_GB}" 2>&1 | \
            tee -a "${RUN_LOG:-/dev/null}" || \
            log "[WARN] offline returned non-zero"
        log "[offline] node0: size=$(numactl --hardware | awk '/^node 0 size:/{print $4}')MB"

        local _re_blk="" _bl _a _sp _st
        for _bl in /sys/devices/system/node/node0/memory*; do
            _a="$(readlink -f "$_bl" 2>/dev/null)" || continue
            _sp="${_a}/state"; [[ -f "$_sp" ]] || continue
            _st="$(cat "$_sp" 2>/dev/null)" || continue
            if [[ "$_st" == "offline" ]]; then
                echo "online" | sudo tee "$_sp" >/dev/null 2>&1 && _re_blk="$(basename "$_a")" && break
            fi
        done
        [[ -n "$_re_blk" ]] && log "[offline] re-onlined ${_re_blk} → demotion targets restored"
    fi

    set_node0_watermark

    cup_on_cxl
    sleep "$SLEEP_AFTER_UP"

    apply_cpuset_mems "${SVCMEM_NODE}"
    sleep "$SLEEP_AFTER_BIND"

    crecreate_all
    sleep "$SLEEP_AFTER_RECREATE"
    apply_cpuset_mems "${SVCMEM_NODE}"
    sleep "$SLEEP_AFTER_BIND"
}

run_wrk() {
    local rps="$1"

    {
        printf '\n# ════════════════════════════════════════════════════════════\n'
        printf '# RPS=%s  app=%s  script=%s  date=%s\n' "$rps" "$APP" "$WRK_SCRIPT_TYPE" "$(date --iso-8601=seconds)"
        printf '# ════════════════════════════════════════════════════════════\n'
        printf '# node0_target=%sGB  svcmem=node%s  gateway=node%s  client=node%s/%s\n' \
               "$MEM_SIZE_GB" "$SVCMEM_NODE" "$GATEWAY_MEM_NODE" "$CLIENT_CPU_NODE" "$CLIENT_MEM_NODE"
        printf '# warmup=%ss  measure=%ss  warmup_enabled=%s\n' \
               "$WARMUP_DURATION_S" "$MEASURE_DURATION_S" "$WARMUP_ENABLED"
        if [[ "$DIST_MODE" == "on" ]]; then
            printf '# [Server B] kernel=%s  numa_balancing=%s  demotion_enabled=%s\n' \
                   "$(rbq kver 2>/dev/null || echo n/a)" \
                   "$(rbq sysctl-numa 2>/dev/null || echo n/a)" \
                   "$(rbq sysctl-demotion 2>/dev/null || echo n/a)"
            printf '# [Server B] min_free_kbytes=%s  wsf=%s  thp=%s  htmm_cxl=%s\n' \
                   "$(rbq sysctl-minfree 2>/dev/null || echo n/a)" \
                   "$(rbq sysctl-wsf 2>/dev/null || echo n/a)" \
                   "$(rbq sysctl-thp 2>/dev/null || echo n/a)" \
                   "$(rbq sysctl-htmm 2>/dev/null || echo n/a)"
        else
            printf '# numa_balancing=%s  demotion_enabled=%s\n' \
                   "$(sysctl -n kernel.numa_balancing 2>/dev/null || echo n/a)" \
                   "$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo n/a)"
            printf '# min_free_kbytes=%s  thp=%s\n' \
                   "$(sysctl -n vm.min_free_kbytes 2>/dev/null || echo n/a)" \
                   "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' || echo n/a)"
        fi
    } >> "$RUN_LOG"

    local node_free_snap="${VMSTAT_TMP_BASE}_node_free.snap"
    snap_node_free "$node_free_snap"

    local _c; _c="$(_wrk_c_for "$rps")"

    if [[ "$WARMUP_ENABLED" == "on" && "$WARMUP_DURATION_S" -gt 0 ]]; then
        local _dp="/sys/kernel/mm/numa/demotion_enabled"
        if [[ "$DIST_MODE" == "on" ]]; then
            rb numa 0 0
            case "${HTMM_ENABLE}:${HTMM_WARMUP}" in
                on:on)   rb htmm on "${HTMM_NODE0_MB}" ;;
                on:skip) log "[warm-up] htmm left as inherited (no registration, no migration)" ;;
                on:*)    rb htmm off ;;
            esac
            rb cpuset "${SVCMEM_NODE}"
        else
            sudo sysctl -w kernel.numa_balancing=0 >/dev/null
            [[ -f "$_dp" ]] && echo 0 | sudo tee "$_dp" >/dev/null || true
        fi
        log "[warm-up] numa_balancing=0  demotion_enabled=0  cpuset.mems=${SVCMEM_NODE}"

        local _wu_tmp; _wu_tmp="$(mktemp /tmp/wrk2_warmup_XXXXXX.raw)"
        log "▶ warm-up  rps=${rps}  c=${_c}  d=${WARMUP_DURATION_S}s"
        _cpu_bind=(); [[ -n "${CLIENT_CPUSET:-}" ]] && _cpu_bind=(--physcpubind="${CLIENT_CPUSET}") || _cpu_bind=(--cpunodebind="${CLIENT_CPU_NODE}")
        sudo numactl "${_cpu_bind[@]}" --membind="${CLIENT_MEM_NODE}" \
            "$WRK_BIN" -D exp -t "$WRK_T" -c "$_c" -d "$WARMUP_DURATION_S" \
            -s "$WRK_SCRIPT" "$WRK_ENDPOINT" -R "$rps" \
            >"$_wu_tmp" 2>&1 || { cat "$_wu_tmp" >&2; rm -f "$_wu_tmp"; die "wrk2 warm-up failed"; }
        rm -f "$_wu_tmp"

        log "[phase] measure: cpuset.mems=0,${SVCMEM_NODE}  numa_balancing=${NUMA_BALANCING}  demotion_enabled=${DEMOTION_ENABLED}"
        if [[ "$DIST_MODE" == "on" ]]; then
            rb cpuset "0,${SVCMEM_NODE}"
            rb numa "${NUMA_BALANCING}" "${DEMOTION_ENABLED}"
            if [[ "$HTMM_ENABLE" == "on" ]]; then
                rb htmm on "${HTMM_NODE0_MB}"
                { printf '\n# ---- MEMTIS state at measure start ----\n'
                  rbq htmm-status 2>/dev/null | sed 's/^/#   /' || true; } >> "$RUN_LOG"
            fi
        else
            apply_cpuset_mems "0,${SVCMEM_NODE}"
            sudo sysctl -w "kernel.numa_balancing=${NUMA_BALANCING}" >/dev/null
            [[ -f "$_dp" ]] && echo "$DEMOTION_ENABLED" | sudo tee "$_dp" >/dev/null || true
        fi
        sleep 2
    fi

    local snap_before="${VMSTAT_TMP_BASE}_before.snap"
    snap_vmstat "$snap_before"
    collect_node_meminfo "$RUN_LOG"

    log "▶ measure  rps=${rps}  c=${_c}  d=${MEASURE_DURATION_S}s  target=${WRK_ENDPOINT}"
    local _tmp; _tmp="$(mktemp /tmp/wrk2_XXXXXX.raw)"
    _cpu_bind=(); [[ -n "${CLIENT_CPUSET:-}" ]] && _cpu_bind=(--physcpubind="${CLIENT_CPUSET}") || _cpu_bind=(--cpunodebind="${CLIENT_CPU_NODE}")
    sudo numactl "${_cpu_bind[@]}" --membind="${CLIENT_MEM_NODE}" \
        "$WRK_BIN" -D exp -t "$WRK_T" -c "$_c" -d "${MEASURE_DURATION_S}" \
        -s "$WRK_SCRIPT" "$WRK_ENDPOINT" -R "$rps" \
        >"$_tmp" 2>&1 || { cat "$_tmp" >&2; rm -f "$_tmp"; die "wrk2 measurement failed"; }
    sed 's/\r[^\n]*/\r/g; s/\r//g' "$_tmp" | \
        sed 's/\x1b\[[0-9;]*[mGKHFABCDJsunr]//g' | \
        grep -v '^[[:space:]]*$' | tee -a "$RUN_LOG"
    rm -f "$_tmp"
    printf '\n'

    printf '# ts_end=%s  (%s)\n' "$(date +%s)" "$(date '+%H:%M:%S')" >> "$RUN_LOG"
    collect_numa_stats_delta "$snap_before" "$RUN_LOG" "run"
    if [[ "$DIST_MODE" == "on" && "$HTMM_ENABLE" == "on" ]]; then
        { printf '\n# ---- ksamplingd statistics [Server B] ----\n'
          rbq htmm-trace 2>/dev/null | sed 's/^/#   /' || true; } >> "$RUN_LOG"
    fi
    log_node_rss_delta "$node_free_snap" "$RUN_LOG"
    collect_node_meminfo "$RUN_LOG"
}

_MEM_HOLDER_PID=""

start_mem_holder() {
    if [[ "$DIST_MODE" == "on" ]]; then
        rb memholder-start "${MEM_HOLDER_GB:-0}"
        return 0
    fi
    awk "BEGIN{exit !(${MEM_HOLDER_GB:-0} > 0)}" || return 0
    numactl --membind="${DOCKER_CPU_NODE}" --cpunodebind="${DOCKER_CPU_NODE}" \
        python3 -c "
import mmap, ctypes, time, sys
n = int(float(sys.argv[1]) * (1<<30))
m = mmap.mmap(-1, n)
c = b'\x01' * (1<<20)
for i in range(0, n, 1<<20): m[i:i+(1<<20)] = c
libc = ctypes.CDLL('libc.so.6', use_errno=True)
libc.mlock.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
libc.mlock.restype = ctypes.c_int
arr = (ctypes.c_char * n).from_buffer(m)
if libc.mlock(arr, n) != 0:
    sys.stderr.write('[mem-holder] mlock failed errno=' + str(ctypes.get_errno()) + '\n')
sys.stdout.write('ready\n'); sys.stdout.flush()
time.sleep(999999)
" "${MEM_HOLDER_GB}" &
    _MEM_HOLDER_PID=$!
    log "[mem-holder] holding ${MEM_HOLDER_GB}GB on node${DOCKER_CPU_NODE}  pid=${_MEM_HOLDER_PID} (initializing...)"
}

stop_mem_holder() {
    if [[ "$DIST_MODE" == "on" ]]; then
        rbq memholder-stop >/dev/null 2>&1 || true
        return 0
    fi
    [[ -n "${_MEM_HOLDER_PID:-}" ]] || return 0
    kill "${_MEM_HOLDER_PID}" 2>/dev/null || true
    wait "${_MEM_HOLDER_PID}" 2>/dev/null || true
    _MEM_HOLDER_PID=""
    log "[mem-holder] released"
}

sweep() {
    log "Sweep  app=${APP}  script=${WRK_SCRIPT_TYPE}  RPS ${RPS_START}..${RPS_END} step ${RPS_STEP}  warmup=${WARMUP_DURATION_S}s  measure=${MEASURE_DURATION_S}s"
    [[ "$DIST_MODE" == "on" ]] || start_mem_holder
    for (( rps=RPS_START; rps<=RPS_END; rps+=RPS_STEP )); do
        RUN_LOG="${LOG_DIR}/${APP}_${WRK_SCRIPT_TYPE}_rps${rps}_$(date '+%Y%m%d_%H%M%S').run.log"
        log "LOG → ${RUN_LOG}"
        reset_stack "$rps"
        run_wrk "$rps"
        sleep "$SLEEP_BETWEEN_POINTS"
    done
    rb down5
    cdown
}

prereq_local() {
    sudo iptables-nft -P FORWARD ACCEPT 2>/dev/null || log "[WARN] iptables-nft FORWARD not set"
    sudo swapoff -a 2>/dev/null || true
    echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    log "[prereq] FORWARD=ACCEPT swap=off governor=performance"
}

main() {
    cd "$DSB_DIR"
    local _node0_mb; _node0_mb=$(numactl --hardware 2>/dev/null | awk '/^node 0 size:/{print $4}')
    log "app=${APP}  script=${WRK_SCRIPT_TYPE}  node0=${_node0_mb}MB  LOG_DIR=${LOG_DIR}"
    log "RPS=${RPS_START}..${RPS_END} step ${RPS_STEP}  warmup=${WARMUP_DURATION_S}s  measure=${MEASURE_DURATION_S}s  t=${WRK_T} c=${WRK_C} auto=${WRK_C_AUTO}"

    prereq_local
    if [[ "$DIST_MODE" == "on" ]]; then
        log "dist=on  placement=${PLACEMENT}  remote=${REMOTE_B}  target=${TARGET_URL}"
        log "  Server B services: [${REMOTE_SERVICES}]"
        _ssh "$REMOTE_B" 'sudo -n true' \
            || die "SSH/sudo to ${REMOTE_B} failed. Check: (1) ssh-copy-id done for user '${_REAL_USER}', (2) /etc/sudoers.d/99-dsb-eval on Server B"
        local _ta _tb _skew
        _ta="$(date +%s)"; _tb="$(_ssh "$REMOTE_B" 'date +%s')"
        _skew=$(( _tb - _ta )); [[ "$_skew" -lt 0 ]] && _skew=$(( -_skew ))
        log "[clock] A=$(date '+%H:%M:%S')  B_offset=$(( _tb - _ta ))s"
        if [[ "$_skew" -gt 5 ]]; then
            log "[clock][WARN] hosts ${_skew}s apart — run 'sudo timedatectl set-ntp true' on both"
        fi
        rb prereq
        if [[ "${SVCMEM_NODE}" != "0" ]]; then
            local _nsz; _nsz="$(rbq nodesize "${SVCMEM_NODE}" 2>/dev/null || echo 0)"
            [[ "${_nsz:-0}" -gt 0 ]] || \
                die "Server B has no usable node${SVCMEM_NODE} (size=${_nsz:-0}MB). Check 'numactl -H' and the CXL device on Server B before running."
            log "[numa] Server B node${SVCMEM_NODE} = ${_nsz}MB"
        fi
        local _kver; _kver="$(rbq kver 2>/dev/null || echo unknown)"
        log "[profile] Server B kernel=${_kver}  NUMA_BALANCING=${NUMA_BALANCING}  HTMM_ENABLE=${HTMM_ENABLE}  HTMM_WARMUP=${HTMM_WARMUP}  WMARK_APPLY=${WMARK_APPLY}"
        [[ "$HTMM_ENABLE" == "on" ]] && rb_try htmm-trace-reset
        if [[ "$_kver" == *htmm* ]]; then
            [[ "$NUMA_BALANCING" == "0" ]] || \
                die "Server B runs ${_kver} (MEMTIS): pass NUMA_BALANCING=0 DEMOTION_ENABLED=0"
            [[ "$HTMM_ENABLE" == "on" ]] || \
                log "[profile][WARN] MEMTIS kernel but HTMM_ENABLE=off — MEMTIS will not migrate anything"
            case "${HTMM_NODE0_MB:-0}" in
                auto|max) : ;;
                ''|0) log "[profile][WARN] HTMM_NODE0_MB=0 — no fast-tier cap, so MEMTIS has nothing to demote against" ;;
            esac
            [[ "$WMARK_APPLY" == "off" ]] || \
                log "[profile][WARN] WMARK_APPLY=on on a MEMTIS kernel — watermarks are not MEMTIS's trigger; off is intended"
        else
            [[ "$HTMM_ENABLE" == "off" ]] || \
                die "HTMM_ENABLE=on but Server B runs ${_kver}, not a MEMTIS kernel"
        fi
        rb numa "${NUMA_BALANCING}" "${DEMOTION_ENABLED}"
        [[ "$HTMM_ENABLE" == "on" ]] && rb_try htmm-tune
    else
        save_numa_settings
        apply_numa_settings
        set_node0_watermark
    fi

    if [[ "$EXP_MODE" == "setup" ]]; then
        RUN_LOG="${LOG_DIR}/setup_$(date '+%Y%m%d_%H%M%S').log"
        reset_stack 0
        log "Stack is UP and verified. Target: ${TARGET_URL}"
        log "Probe it, then: sudo DIST_MODE=${DIST_MODE} bash $0 --teardown"
        trap - EXIT INT TERM        # keep the holder and node sizing in place
        exit 0
    fi

    if [[ "$EXP_MODE" == "teardown" ]]; then
        stop_mem_holder
        rb down5
        cdown
        if [[ "$DIST_MODE" == "on" && "$TIER_ONCE" != "on" ]]; then
            rbq online >/dev/null 2>&1 || true
            log "Stack is DOWN; Server B nodes restored to full size."
        else
            log "Stack is DOWN. TIER_ONCE=${TIER_ONCE} — node sizing left as is."
        fi
        trap - EXIT INT TERM
        exit 0
    fi

    if [[ "$EXP_MODE" == "snapshot" ]]; then
        log "[snapshot] Capturing DB volume state → ${DB_SNAPSHOT_DIR}"
        cdown
        sleep 2
        snapshot_db_volumes
        log "[snapshot] Complete. Re-run without arguments to start experiments."
        exit 0
    fi

    sweep
    log "DONE. Logs: ${LOG_DIR}"
}

main
