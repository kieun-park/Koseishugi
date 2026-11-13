#!/bin/bash
set -Eeuo pipefail


_REAL_USER="${SUDO_USER:-${USER}}"
_REAL_HOME="$(getent passwd "${_REAL_USER}" | cut -d: -f6 2>/dev/null || echo "${HOME}")"

APP_KIND="${APP_KIND:-hotel}"
if [[ "$APP_KIND" == "social" ]]; then
    DSB_DIR="${DSB_DIR:-${_REAL_HOME}/DeathStarBench/socialNetwork}"
else
    DSB_DIR="${DSB_DIR:-${_REAL_HOME}/DeathStarBench/hotelReservation}"
fi
IP_ALIAS="${IP_ALIAS:-}"
IP_ALIAS_DEV="${IP_ALIAS_DEV:-}"
HOST_A_IP="${HOST_A_IP:-}"
HOST_B_IP="${HOST_B_IP:-}"
RUN_DIR="${RUN_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
SERVICES="${SERVICES:-geo profile rate reservation search}"

SVC_CPUSET="${SVC_CPUSET:-$(cat /sys/devices/system/node/node0/cpulist 2>/dev/null || true)}"
HOLDER_NODE="${HOLDER_NODE:-0}"
HOLDER_PID_FILE="${HOLDER_PID_FILE:-/tmp/dsb_mem_holder.pid}"
HOLDER_LOG="${HOLDER_LOG:-/tmp/dsb_mem_holder.log}"
OFFLINE_SCRIPT="${OFFLINE_SCRIPT:-${RUN_DIR}/dram_limit.sh}"

log() { echo "[remote_b] $(date '+%H:%M:%S') $*"; }
die() { echo "[remote_b][FATAL] $*" >&2; exit 1; }

_compose_args() {
    local a=(-f docker-compose.yml)
    [[ -f "${DSB_DIR}/docker-compose.override.yml" ]] && a+=(-f docker-compose.override.yml)
    printf '%s\n' "${a[@]}"
}
compose() {
    local args=(); mapfile -t args < <(_compose_args)
    cd "$DSB_DIR" && sudo docker compose "${args[@]}" "$@"
}

cmd_down5() {
    compose rm -sf $SERVICES >/dev/null 2>&1 || true
    log "down5: removed [$SERVICES]"
}

cmd_up5() {
    compose up -d --no-deps $SERVICES
    log "up5: started [$SERVICES]"
}

cmd_ps() { compose ps; }
cmd_kver() { uname -r; }

cmd_sysctl_one() {
    case "${1:-}" in
        numa)     sysctl -n kernel.numa_balancing 2>/dev/null || echo n/a ;;
        demotion) cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo absent ;;
        minfree)  sysctl -n vm.min_free_kbytes 2>/dev/null || echo n/a ;;
        wsf)      sysctl -n vm.watermark_scale_factor 2>/dev/null || echo n/a ;;
        thp)      grep -o '\[.*\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a ;;
        htmm)     cat /sys/kernel/mm/htmm/htmm_cxl_mode 2>/dev/null || echo absent ;;
        *)        echo n/a ;;
    esac
}

HTMM_NODE0_MB="${HTMM_NODE0_MB:-0}"   # 0 = do not touch memory.max_at_node0

_cgroup_path_of() {
    local pid rel
    pid="$(_svc_pid "$1")"
    [[ "$pid" -gt 0 ]] || { echo ""; return; }
    rel="$(awk -F: '$1=="0"{print $3}' "/proc/${pid}/cgroup" 2>/dev/null || true)"
    if [[ -n "$rel" && -d "/sys/fs/cgroup${rel}" ]]; then echo "/sys/fs/cgroup${rel}"; return; fi
    rel="$(awk -F: '$2 ~ /(^|,)memory(,|$)/{print $3}' "/proc/${pid}/cgroup" 2>/dev/null || true)"
    if [[ -n "$rel" && -d "/sys/fs/cgroup/memory${rel}" ]]; then echo "/sys/fs/cgroup/memory${rel}"; return; fi
    echo ""
}

cmd_htmm_probe() {
    echo "cgroup fs type        = $(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
    echo "cgroup v1 memory      = $([[ -d /sys/fs/cgroup/memory ]] && echo present || echo absent)"
    echo "-- htmm memcg interface files found anywhere:"
    find /sys/fs/cgroup -maxdepth 6 -name 'memory.htmm*' -o -maxdepth 6 -name 'memory.max_nr_base_pages' 2>/dev/null | head -10
    echo "-- per-service cgroup paths and whether the interface is there:"
    local svc cg
    for svc in $SERVICES; do
        cg="$(_cgroup_path_of "$svc")"
        if [[ -z "$cg" ]]; then
            printf '   %-20s (no cgroup — container down?)\n' "$svc"
        else
            printf '   %-20s %s  htmm_enabled=%s  max_nr_base_pages=%s\n' "$svc" "$cg" \
                "$([[ -f $cg/memory.htmm_enabled ]] && echo yes || echo NO)" \
                "$([[ -f $cg/memory.max_nr_base_pages ]] && echo yes || echo NO)"
        fi
    done
    echo "-- kernel threads (none until htmm is enabled somewhere)"
    ps -ef | grep -E "kmigraterd|ksampled" | grep -v grep || echo "   (none)"
}

_htmm_sel() {
    local f="$1" raw
    [[ -r "$f" ]] || { echo "n/a"; return; }
    raw="$(tr '\n' ' ' < "$f" 2>/dev/null)"
    if [[ "$raw" == *"["* ]]; then
        sed 's/.*\[\([^]]*\)\].*/\1/' <<<"$raw"
    else
        awk '{$1=$1; print}' <<<"$raw"
    fi
}

_htmm_write() {
    local f="$1"; shift
    local v
    for v in "$@"; do
        if echo "$v" | sudo tee "$f" >/dev/null 2>&1; then echo "$v"; return 0; fi
    done
    return 1
}

cmd_htmm_parent() {
    local parent="${1:-}" svc cg drv src

    if [[ -z "$parent" ]]; then
        for svc in $SERVICES; do
            cg="$(_cgroup_path_of "$svc" 2>/dev/null)" || true
            if [[ -n "$cg" ]]; then
                parent="$(dirname "$cg")"; src="live container"; break
            fi
        done
    else
        src="explicit"
    fi
    if [[ -z "$parent" ]]; then
        drv=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo systemd)
        src="driver=${drv}"
        if [[ "$drv" == "systemd" ]]; then
            parent=/sys/fs/cgroup/system.slice
        else
            parent=/sys/fs/cgroup/docker
            sudo mkdir -p "$parent" 2>/dev/null || true
        fi
    fi

    if [[ ! -e "$parent/memory.htmm_enabled" ]]; then
        log "[WARN] htmm-parent: ${parent}/memory.htmm_enabled absent (${src}) — no inheritance"
        return 0
    fi
    if _htmm_write "$parent/memory.htmm_enabled" enabled 1 >/dev/null; then
        log "htmm-parent: enabled on ${parent} (${src}) — new containers inherit at creation"
    else
        log "[WARN] htmm-parent: write to ${parent} failed"
    fi
    return 0
}

cmd_htmm() {
    local mode="${1:?usage: htmm <on|off> [node0_MB]}"
    local node0_mb="${2:-$HTMM_NODE0_MB}"
    local svc cg n=0 missing=0 used=""
    for svc in $SERVICES; do
        cg="$(_cgroup_path_of "$svc")"
        [[ -n "$cg" ]] || { log "[WARN] htmm: no cgroup for ${svc}"; missing=1; continue; }
        if [[ ! -f "${cg}/memory.htmm_enabled" ]]; then
            log "[WARN] htmm: ${cg}/memory.htmm_enabled absent"; missing=1; continue
        fi
        if [[ "$mode" == "on" ]]; then
            used="$(_htmm_write "${cg}/memory.htmm_enabled" enabled 1 true on y)" || {
                log "[WARN] htmm: every value rejected for ${svc} (${cg}/memory.htmm_enabled)"
                missing=1; continue; }
        else
            used="$(_htmm_write "${cg}/memory.htmm_enabled" disabled 0 false off n)" || {
                log "[WARN] htmm: every value rejected for ${svc}"; missing=1; continue; }
        fi
        n=$(( n + 1 ))
    done
    log "htmm: ${mode} on ${n} cgroups  accepted='${used:-none}'"
    if [[ "$mode" == "on" ]]; then
        case "${node0_mb:-0}" in
            auto|max)      cmd_maxnode0 "$node0_mb" ;;
            ''|0)          : ;;
            *[!0-9]*)      log "[WARN] htmm: HTMM_NODE0_MB='${node0_mb}' not understood — skipped" ;;
            *)             cmd_maxnode0 "$node0_mb" ;;
        esac
        local t s m mnum cxl
        t="$(ps -ef | grep -cE '[k]migraterd' || true)"
        s="$(ps -ef | grep -cE '[k]samplingd' || true)"
        m="$(_htmm_sel /sys/kernel/mm/htmm/htmm_mode)"
        mnum="${m##*-}"
        cxl="$(_htmm_sel /sys/kernel/mm/htmm/htmm_cxl_mode)"
        log "htmm: kmigraterd=${t}  ksamplingd=${s}  htmm_mode=${m}  htmm_cxl_mode=${cxl}"
        if [[ "$s" -eq 0 ]]; then
            log "[WARN] htmm: ksamplingd is NOT running — no PEBS samples, so nothing gets classified hot"
            log "[WARN] htmm: kernel messages since enabling htmm:"
            sudo dmesg 2>/dev/null | grep -aiE "htmm|pebs|perf_event" | tail -15 \
                | sed 's/^/   /' || log "   (no htmm/pebs messages in dmesg)"
            log "[WARN] htmm: PMU counters in use by others (NMI watchdog takes one per CPU):"
            log "   nmi_watchdog=$(sysctl -n kernel.nmi_watchdog 2>/dev/null)  perf_event_paranoid=$(sysctl -n kernel.perf_event_paranoid 2>/dev/null)"
        fi
        [[ "$mnum" == "2" ]] || \
            log "[WARN] htmm: htmm_mode selected='${m}', upstream run_bench.sh uses 2 — run 'htmm-tune'"
        [[ "$cxl" == "enabled" ]] || \
            log "[WARN] htmm: htmm_cxl_mode='${cxl}' — must be enabled or MEMTIS cannot see CXL accesses"
    fi
    [[ "$missing" -eq 0 ]] || log "[WARN] htmm: some cgroups failed — run 'htmm-probe'"
}

cmd_htmm_trace() {
    local t=/sys/kernel/debug/tracing
    if [[ ! -d "$t" ]]; then
        sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
        sudo mount -t tracefs none /sys/kernel/tracing 2>/dev/null || true
        [[ -d /sys/kernel/tracing ]] && t=/sys/kernel/tracing
    fi
    [[ -d "$t" ]] || { echo "(ftrace unavailable: mount -t debugfs none /sys/kernel/debug)"; return 0; }
    echo "tracing_on = $(sudo cat "${t}/tracing_on" 2>/dev/null)"
    echo "-- ksamplingd statistics (most recent lines)"
    sudo grep -aiE "nr_sampled|nr_dram|nr_lost|nr_throttl|cputime|hr_dram|hr_nvm" \
        "${t}/trace" 2>/dev/null | tail -20 \
        || echo "   (nothing yet)"
    echo
    echo "   nr_sampled  이 0 이거나 안 늘면 -> 샘플링이 안 됨"
    echo "   nr_lost / nr_throttled 이 크면 -> PEBS 버퍼 넘침 또는 CPU quota 스로틀"
    echo "   cputime 이 ksampled_soft_cpu_quota(30) 근처면 -> 스스로 샘플 주기를 늘려 감속 중"
}

cmd_why() {
    echo "== ksamplingd $(ps -ef | grep -cE '[k]samplingd')  kmigraterd $(ps -ef | grep -cE '[k]migraterd')"
    echo "== A) ksamplingd_init / ksamplingd_run callers in the WHOLE tree:"
    grep -rn --include=*.c --include=*.h         -e 'ksamplingd_init' -e 'ksamplingd_run' "${KDIR}" 2>/dev/null         | grep -v 'htmm_sampler\.c' | sed 's|.*/linux/||' | head -6 | sed 's/^/   /'
    echo "   (^ 비어 있으면 = 커널에 연결 코드가 아예 없다는 뜻)"
    echo "== B) memcg htmm_enabled write handler (code only):"
    local f="${KDIR}/mm/memcontrol.c" ln
    ln="$(grep -n 'memcg->htmm_enabled = true' "$f" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -n "$ln" ]]; then
        sed -n "$(( ln > 14 ? ln - 14 : 1 )),$(( ln + 26 ))p" "$f"             | grep -vE '^[[:space:]]*$|^[[:space:]]*/\*|^[[:space:]]*\*|^[[:space:]]*//'             | head -24 | sed 's/^/   /'
    else
        echo "   (memcontrol.c 에서 htmm_enabled 대입부를 못 찾음 — KDIR 확인)"
    fi
    return 0
}

cmd_htmm_trace_reset() {
    local t=/sys/kernel/debug/tracing
    [[ -d "$t" ]] || { sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null || true; }
    [[ -d "$t" ]] || { [[ -d /sys/kernel/tracing ]] && t=/sys/kernel/tracing; }
    [[ -d "$t" ]] || { log "htmm-trace-reset: ftrace not mounted — skipped"; return 0; }
    echo 1 | sudo tee "${t}/tracing_on" >/dev/null
    sudo truncate -s 0 "${t}/trace" 2>/dev/null || echo | sudo tee "${t}/trace" >/dev/null
    log "htmm-trace-reset: ftrace buffer cleared, tracing_on=1"
}

cmd_dump() {
    local out="${1:-/tmp/memtis_diag.txt}"
    {
        echo "=================== SUMMARY (이 10줄만 옮기면 됨) ==================="
        printf 'kernel            %s\n' "$(uname -r)"
        printf 'ksamplingd        %s\n' "$(ps -ef | grep -cE '[k]samplingd')"
        printf 'kmigraterd        %s\n' "$(ps -ef | grep -cE '[k]migraterd')"
        printf 'htmm_mode         %s\n' "$(_htmm_sel /sys/kernel/mm/htmm/htmm_mode)"
        printf 'htmm_cxl_mode     %s\n' "$(_htmm_sel /sys/kernel/mm/htmm/htmm_cxl_mode)"
        printf 'cgroups enabled   %s / %s\n' \
            "$(for s in $SERVICES; do c=$(_cgroup_path_of "$s"); [[ -n "$c" ]] && _htmm_sel "$c/memory.htmm_enabled"; done | grep -c enabled)" \
            "$(echo $SERVICES | wc -w)"
        printf 'node0 / node2     %s MB / %s MB\n' "$(_node_size_mb 0)" "$(_node_size_mb 2)"
        printf 'ftrace htmm lines %s\n' \
            "$(sudo grep -acaiE 'htmm|pebs|sampl' /sys/kernel/debug/tracing/trace 2>/dev/null || echo 0)"
        printf 'dmesg htmm lines  %s\n' \
            "$(sudo dmesg 2>/dev/null | grep -caiE 'htmm|pebs' || echo 0)"
        printf 'ksamplingd_init   %s\n' \
            "$(grep -rn 'ksamplingd_init(' "${KDIR}/mm/" 2>/dev/null | grep -v 'htmm.h' | head -2 | tr '\n' ' ')"
        echo "===================================================================="
        echo
        echo "######## $(date -Is)  $(hostname)  $(uname -r)"
        echo; echo "######## htmm-status"; cmd_htmm_status
        echo; echo "######## htmm-probe";  cmd_htmm_probe
        echo; echo "######## htmm-trace";  cmd_htmm_trace
        echo; echo "######## kernel write handler (htmm-src)"; cmd_htmm_src
        echo; echo "######## sysctl / PMU"
        for k in kernel.numa_balancing kernel.nmi_watchdog kernel.perf_event_paranoid \
                 kernel.perf_event_max_sample_rate vm.min_free_kbytes vm.watermark_scale_factor; do
            echo "   ${k} = $(sysctl -n "$k" 2>/dev/null || echo n/a)"
        done
        echo; echo "######## numactl -H"; numactl -H 2>/dev/null
        echo; echo "######## dmesg (htmm|pebs|perf|cxl)"
        sudo dmesg 2>/dev/null | grep -aiE "htmm|pebs|perf_event|cxl" | tail -60
        echo; echo "######## vmstat (migration / compaction)"
        grep -E "^(pgmigrate|compact_|numa_pages_migrated|pgdemote|pgpromote)" /proc/vmstat
    } > "$out" 2>&1
    log "dump: wrote ${out} ($(wc -l < "$out") lines)"
    echo "   fetch with:  rsync ${_REAL_USER}@$(hostname):${out} ."
}

cmd_htmm_status() {
    local d=/sys/kernel/mm/htmm f svc cg
    if [[ -d "$d" ]]; then
        echo "-- /sys/kernel/mm/htmm   (bracketed = active)"
        for f in "$d"/*; do
            [[ -f "$f" ]] || continue
            printf '   %-30s %-52s [sel=%s]\n' "$(basename "$f")" \
                "$(tr '\n' ' ' < "$f" 2>/dev/null)" "$(_htmm_sel "$f")"
        done
    else
        echo "-- /sys/kernel/mm/htmm absent (not a MEMTIS kernel)"
    fi
    echo "-- threads (ksampled is what feeds MEMTIS its access data)"
    ps -ef | grep -E "[k]samplingd|[k]migraterd" | awk '{printf "   pid=%-8s %s\n", $2, $8}' \
        || echo "   (none)"
    echo "-- per-cgroup"
    for svc in $SERVICES; do
        cg="$(_cgroup_path_of "$svc")"
        [[ -n "$cg" ]] || continue
        printf '   %-20s htmm=%-9s max_at_node0=%s MB\n' "$svc" \
            "$(_htmm_sel "${cg}/memory.htmm_enabled")" \
            "$(awk -v b="$(tr -d '\n' < "${cg}/memory.max_at_node0" 2>/dev/null || echo 0)" \
                 'BEGIN{ if (b+0 > 1e15) print "unlimited"; else printf "%.0f", b/1048576 }')"
    done
}

cmd_maxnode0() {
    local total_mb="${1:?usage: maxnode0 <total_MB|auto|max>}"
    local svc cg pid rss total_rss=0 share n=0
    declare -A RSS=()

    if [[ "$total_mb" == "auto" ]]; then
        local free_kb anon_kb
        free_kb=$(awk '/^Node 0 MemFree:/{print $4}'   /sys/devices/system/node/node0/meminfo 2>/dev/null)
        anon_kb=$(awk '/^Node 0 AnonPages:/{print $4}' /sys/devices/system/node/node0/meminfo 2>/dev/null)
        if [[ -z "${free_kb:-}" || -z "${anon_kb:-}" ]]; then
            log "[WARN] maxnode0 auto: cannot read node0 meminfo — skipped"; return 0
        fi
        total_mb=$(( (free_kb + anon_kb) / 1024 ))
        log "maxnode0 auto: node0 free=$(( free_kb/1024 ))MB + anon=$(( anon_kb/1024 ))MB -> ${total_mb}MB"
    fi

    if [[ "$total_mb" == "max" ]]; then
        for svc in $SERVICES; do
            cg="$(_cgroup_path_of "$svc")"
            [[ -n "$cg" && -f "${cg}/memory.max_at_node0" ]] || continue
            echo 18446744073709551615 | sudo tee "${cg}/memory.max_at_node0" >/dev/null 2>&1 && n=$(( n + 1 ))
        done
        log "maxnode0: unlimited on ${n} cgroups"
        return 0
    fi

    for svc in $SERVICES; do
        pid="$(_svc_pid "$svc")"
        [[ "$pid" -gt 0 && -r "/proc/${pid}/status" ]] || continue
        rss=$(( $(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status") / 1024 ))
        [[ "$rss" -lt 1 ]] && rss=1
        RSS[$svc]=$rss
        total_rss=$(( total_rss + rss ))
    done
    [[ "$total_rss" -gt 0 ]] || { log "[WARN] maxnode0: no running services"; return 0; }

    for svc in "${!RSS[@]}"; do
        cg="$(_cgroup_path_of "$svc")"
        [[ -n "$cg" && -f "${cg}/memory.max_at_node0" ]] || {
            log "[WARN] maxnode0: ${svc} has no memory.max_at_node0"; continue; }
        share=$(( total_mb * RSS[$svc] / total_rss ))
        [[ "$share" -lt 16 ]] && share=16
        if echo $(( share * 1048576 )) | sudo tee "${cg}/memory.max_at_node0" >/dev/null 2>&1; then
            printf '   %-20s rss=%5sMB  max_at_node0=%5sMB\n' "$svc" "${RSS[$svc]}" "$share"
            n=$(( n + 1 ))
        else
            log "[WARN] maxnode0: write rejected for ${svc}"
        fi
    done
    log "maxnode0: ${total_mb}MB split across ${n} cgroups by RSS"
}

cmd_htmm_tune() {
    local d=/sys/kernel/mm/htmm
    [[ -d "$d" ]] || { log "[WARN] htmm-tune: ${d} absent"; return 0; }
    local k v
    while read -r k v; do
        [[ -f "${d}/${k}" ]] || { log "[WARN] htmm-tune: ${k} absent"; continue; }
        echo "$v" | sudo tee "${d}/${k}" >/dev/null 2>&1 \
            || log "[WARN] htmm-tune: ${k}=${v} rejected"
    done <<'KNOBS'
htmm_sample_period 199
htmm_inst_sample_period 100007
htmm_thres_hot 1
htmm_split_period 2
htmm_adaptation_period 100000
htmm_cooling_period 2000000
htmm_mode 2
htmm_demotion_period_in_ms 500
htmm_promotion_period_in_ms 500
htmm_gamma 4
ksampled_soft_cpu_quota 30
KNOBS
    sudo sysctl -w kernel.perf_event_max_sample_rate=100000 >/dev/null 2>&1 || true
    _htmm_write "${d}/htmm_cxl_mode" enabled 1 true >/dev/null || \
        log "[WARN] htmm-tune: htmm_cxl_mode not set"
    log "htmm-tune: applied upstream run_bench.sh values"
    for k in htmm_mode htmm_cxl_mode htmm_thres_hot htmm_gamma; do
        if [[ -f "${d}/${k}" ]]; then
            printf '   %-28s selected=%s\n' "$k" "$(_htmm_sel "${d}/${k}")"
        fi
    done
    return 0
}

KDIR="${KDIR:-${_REAL_HOME}/memtis/linux}"
cmd_htmm_src() {
    local f="${KDIR}/mm/memcontrol.c"
    [[ -f "$f" ]] || { echo "not found: $f   (re-run as: KDIR=/path/to/linux $0 htmm-src)"; return 0; }
    local ln
    ln="$(grep -n '"htmm_enabled"' "$f" | cut -d: -f1 | head -1)"
    [[ -n "$ln" ]] || { echo "htmm_enabled cftype not found in $f"; return 0; }
    echo "=== ${f}: write handler / cftype around line ${ln}"
    sed -n "$(( ln > 80 ? ln-80 : 1 )),$(( ln+20 ))p" "$f"
    echo
    echo "=== max_nr_base_pages references"
    grep -n "max_nr_base_pages" "$f" | head -20
}

cmd_verify() {
    local want n extra pat
    want=$(echo $SERVICES | wc -w)
    pat="^($(echo $SERVICES | tr ' ' '|'))$"
    n=$(compose ps --services --filter status=running 2>/dev/null | grep -cE "$pat" || true)
    [[ "$n" -eq "$want" ]] || die "verify: expected ${want} running services, found ${n}"
    extra=$(compose ps --services --filter status=running 2>/dev/null | grep -vE "$pat" || true)
    [[ -z "$extra" ]] || die "verify: unexpected services on Server B: $(echo $extra)"
    if [[ "$APP_KIND" == "social" ]]; then
        local cfg="${DSB_DIR}/config/service-config.json"
        [[ -f "$cfg" ]] || die "verify: ${cfg} missing — run social_placement.sh top7"
        grep -Fq "\"${HOST_A_IP:?Set HOST_A_IP for verify}\"" "$cfg" \
            || die "verify: service-config.json has no Server A address — placement not applied"
        local probe="${VERIFY_CONFIG_SVC:-home-timeline-service}"
        compose exec -T "$probe" grep -Fq "${HOST_A_IP:?Set HOST_A_IP for verify}" \
            /social-network-microservices/config/service-config.json \
            || die "verify: ${probe} is not reading the mounted service-config.json"
        log "verify: OK (${want} services, service-config.json mounted and points at Server A)"
    else
        grep -q "\"SearchIP\": *\"${HOST_B_IP:?Set HOST_B_IP for verify}\"" "${DSB_DIR}/config.json" \
            || die "verify: config.json missing SearchIP=${HOST_B_IP}"
        compose exec -T search grep -Fq "${HOST_B_IP:?Set HOST_B_IP for verify}" /workspace/config.json \
            || die "verify: container is not reading the mounted config.json"
        log "verify: OK (${want} services, config.json mounted)"
    fi
    _htmm_report_inherited
}

_htmm_report_inherited() {
    local svc cg pre n=0 inh=0
    for svc in $SERVICES; do
        cg="$(_cgroup_path_of "$svc" 2>/dev/null)" || true
        [[ -n "$cg" && -f "${cg}/memory.htmm_enabled" ]] || continue
        n=$(( n + 1 ))
        pre="$(_htmm_sel "${cg}/memory.htmm_enabled")"
        if [[ "$pre" == enabled* || "$pre" == "1" ]]; then
            inh=$(( inh + 1 ))
        fi
    done
    [[ "$n" -gt 0 ]] || return 0
    if [[ "$inh" -eq "$n" ]]; then
        log "htmm: INHERITED ${inh}/${n} at creation — page tables carry metadata"
    else
        log "[WARN] htmm: INHERITED ${inh}/${n} — the rest stay invisible to MEMTIS"
        log "[WARN] htmm: run 'remote_b.sh htmm-parent' before the containers start"
    fi
    return 0
}

cmd_prereq() {
    if [[ "$APP_KIND" == "social" ]]; then
        [[ -n "$IP_ALIAS" && -n "$IP_ALIAS_DEV" ]] || die "Set IP_ALIAS (address/prefix) and IP_ALIAS_DEV for social prereq"
    fi
    sudo iptables-nft -P FORWARD ACCEPT
    sudo swapoff -a
    echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
    local alias_note=""
    if [[ "$APP_KIND" == "social" ]]; then
        if ip -br addr show dev "$IP_ALIAS_DEV" 2>/dev/null | grep -Fq "${IP_ALIAS%%/*}"; then
            alias_note=" alias=${IP_ALIAS%%/*}(present)"
        else
            sudo ip addr add "$IP_ALIAS" dev "$IP_ALIAS_DEV" || die "Could not configure $IP_ALIAS on $IP_ALIAS_DEV"
            alias_note=" alias=${IP_ALIAS%%/*}(added)"
        fi
    fi
    log "prereq: FORWARD=ACCEPT swap=off governor=performance${alias_note}"
}

_node_size_mb() { numactl --hardware | awk -v n="$1" '$0 ~ "^node "n" size:" {print $4}'; }

cmd_online() {
    local n
    for n in 0 2; do
        [[ -d "/sys/devices/system/node/node${n}" ]] || continue
        sudo "$OFFLINE_SCRIPT" --restore --node "$n" >/dev/null 2>&1 || true
    done
    log "online: node0=$(_node_size_mb 0)MB node2=$(_node_size_mb 2)MB"
}

cmd_tier() {
    local gb0="${1:-0}" gb2="${2:-0}"
    if [[ "$gb0" -le 0 && "$gb2" -le 0 ]]; then
        log "tier: both targets 0 — nodes left at full size"; return 0
    fi
    [[ -x "$OFFLINE_SCRIPT" ]] || die "tier: not executable: $OFFLINE_SCRIPT"
    cmd_online
    if [[ "$gb0" -gt 0 ]]; then
        log "tier: offlining node0 → ${gb0}GB ..."
        sudo "$OFFLINE_SCRIPT" --target-size-gb "$gb0" --node 0 \
            || log "[WARN] dram_limit node0 returned non-zero"
    fi
    if [[ "$gb2" -gt 0 ]]; then
        log "tier: offlining node2 → ${gb2}GB ..."
        sudo "$OFFLINE_SCRIPT" --target-size-gb "$gb2" --node 2 \
            || log "[WARN] dram_limit node2 returned non-zero"
    fi
    local bl a sp
    for bl in /sys/devices/system/node/node0/memory*; do
        a="$(readlink -f "$bl" 2>/dev/null)" || continue
        sp="${a}/state"; [[ -f "$sp" ]] || continue
        if [[ "$(cat "$sp")" == "offline" ]]; then
            echo online | sudo tee "$sp" >/dev/null 2>&1 && \
                log "tier: re-onlined $(basename "$a") → demotion targets restored" && break
        fi
    done
    log "tier: node0=$(_node_size_mb 0)MB node2=$(_node_size_mb 2)MB"
}

cmd_memholder_start() {
    local gb="${1:-0}"
    cmd_memholder_stop
    awk "BEGIN{exit !(${gb} > 0)}" || { log "memholder: disabled (0GB)"; return 0; }
    sudo rm -f "$HOLDER_LOG"
    sudo setsid nohup numactl --membind="$HOLDER_NODE" --cpunodebind="$HOLDER_NODE" \
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
    sys.stderr.write('mlock failed errno=' + str(ctypes.get_errno()) + '\n')
sys.stdout.write('ready\n'); sys.stdout.flush()
time.sleep(999999)
" "$gb" >"$HOLDER_LOG" 2>&1 </dev/null &
    local pid=$!
    echo "$pid" | sudo tee "$HOLDER_PID_FILE" >/dev/null
    local i
    for i in $(seq 120); do
        grep -q ready "$HOLDER_LOG" 2>/dev/null && break
        sleep 1
    done
    grep -q ready "$HOLDER_LOG" 2>/dev/null \
        && log "memholder: holding ${gb}GB on node${HOLDER_NODE} (pid ${pid})" \
        || log "[WARN] memholder did not report ready — see ${HOLDER_LOG}"
}

cmd_memholder_stop() {
    [[ -f "$HOLDER_PID_FILE" ]] || return 0
    local pid; pid="$(cat "$HOLDER_PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && sudo pkill -P "$pid" 2>/dev/null
    [[ -n "$pid" ]] && sudo kill "$pid" 2>/dev/null
    sudo pkill -f 'mmap.mmap\(-1, n\)' 2>/dev/null || true
    sudo rm -f "$HOLDER_PID_FILE"
    log "memholder: released"
}

cmd_cputopo() {
    local n b first
    for n in /sys/devices/system/node/node[0-9]*; do
        b=$(basename "$n")
        printf '%-6s cpulist: %s\n' "$b" "$(cat "$n/cpulist" 2>/dev/null || echo none)"
    done
    first="${SVC_CPUSET%%[-,]*}"
    printf 'svc cpuset     : %s\n' "$SVC_CPUSET"
    printf 'SMT sibs cpu%-3s: %s\n' "$first" \
        "$(cat "/sys/devices/system/cpu/cpu${first}/topology/thread_siblings_list" 2>/dev/null || echo n/a)"
    printf 'online CPUs    : %s\n' "$(cat /sys/devices/system/cpu/online 2>/dev/null || echo n/a)"
    return 0
}

cmd_cpuset() {
    local mems="${1:?usage: cpuset <mem-nodes>}"
    local svc cid
    for svc in $SERVICES; do
        cid="$(compose ps -q "$svc" 2>/dev/null || true)"
        [[ -z "$cid" ]] && { log "[WARN] cpuset: no container for '$svc'"; continue; }
        sudo docker update --cpuset-mems="$mems" --cpuset-cpus="$SVC_CPUSET" "$cid" >/dev/null
    done
    log "cpuset: mems=${mems} cpus=${SVC_CPUSET} applied to [$SERVICES]"
}

cmd_numa() {
    local nb="${1:?usage: numa <numa_balancing> <demotion_enabled>}" dem="${2:?}"
    sudo sysctl -w "kernel.numa_balancing=${nb}" >/dev/null
    local dp=/sys/kernel/mm/numa/demotion_enabled
    if [[ -f "$dp" ]]; then
        echo "$dem" | sudo tee "$dp" >/dev/null
        local v; v="$(cat "$dp" 2>/dev/null)"
        if [[ "$dem" == "1" && ( "$v" == "false" || "$v" == "0" ) ]]; then
            log "[WARN] numa: demotion_enabled not set — pgdemote_kswapd will stay 0"
        fi
    else
        log "[WARN] numa: ${dp} absent (expected on 5.15.19-htmm) — skipped"
    fi

    local sp=/proc/sys/vm/numa_slow_tier_nodes
    if [[ -f "$sp" ]]; then
        echo 4 | sudo tee "$sp" >/dev/null      # bitmask: node2 = CXL
        log "numa: numa_slow_tier_nodes=4 (node2=CXL)"
    else
        log "[WARN] numa: ${sp} absent — memory-tiers patch missing"
    fi

    sudo sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
    log "numa: numa_balancing=${nb} demotion_enabled=${dem} zone_reclaim_mode=0"
}

cmd_watermark() {
    local pct="${1:-10}" band="${2:-1}"
    local node0_mb; node0_mb=$(_node_size_mb 0)
    [[ "${node0_mb:-0}" -gt 0 ]] || { log "[wmark] cannot read node0 size — skipped"; return 0; }

    local node0_managed
    node0_managed=$(awk '/Node 0, zone/{z=$0} z~/Normal/ && /managed/{print $2; z=""; exit}' \
        /proc/zoneinfo 2>/dev/null || echo 0)
    [[ "${node0_managed:-0}" -gt 0 ]] || { log "[wmark] cannot read node0 managed pages — skipped"; return 0; }

    local target_low_mb=$(( node0_mb * pct / 100 ))
    local target_high_mb=$(( node0_mb * (pct + band) / 100 ))

    if [[ "$pct" -gt 0 ]]; then
        [[ "$target_low_mb" -lt "$target_high_mb" ]] || { log "[wmark] band must be > 0 — skipped"; return 0; }
        local wmin_mb=$(( 2 * target_low_mb - target_high_mb ))
        [[ "$wmin_mb" -lt 0 ]] && wmin_mb=0
        local total_normal_managed
        total_normal_managed=$(awk '/zone/{z=$0} z~/Normal/ && /managed/{s+=$2} END{print s+0}' \
            /proc/zoneinfo 2>/dev/null || echo 0)
        [[ "${total_normal_managed:-0}" -gt 0 ]] || total_normal_managed=$node0_managed
        local new_min_free_kb=$(( wmin_mb * 1024 * total_normal_managed / node0_managed ))
        [[ "$new_min_free_kb" -lt 65536 ]] && new_min_free_kb=65536
        sudo sysctl -w "vm.min_free_kbytes=${new_min_free_kb}" >/dev/null
        log "[wmark] node0=${node0_mb}MB ~min=${wmin_mb}MB ~low=${target_low_mb}MB ~high=${target_high_mb}MB min_free_kbytes=${new_min_free_kb}"
    fi

    local step_p
    if [[ "$pct" -gt 0 ]]; then
        step_p=$(( (target_high_mb - target_low_mb) * 256 ))
    else
        local wmin_pages
        wmin_pages=$(awk '/Node 0, zone/{z=$0} z~/Normal/ && /  min /{print $2; z=""; exit}' \
            /proc/zoneinfo 2>/dev/null || echo 0)
        step_p=$(( (target_high_mb * 256 - wmin_pages) / 2 ))
    fi
    [[ "$step_p" -le 0 ]] && step_p=1
    local wsf=$(( step_p * 10000 / node0_managed ))
    [[ "$wsf" -lt 1 ]] && wsf=1
    [[ "$wsf" -gt 3000 ]] && wsf=3000
    sudo sysctl -w "vm.watermark_scale_factor=${wsf}" >/dev/null
    log "[wmark] watermark_scale_factor=${wsf}"
}

cmd_wmark_default() {
    local lowmem_pages tmp
    lowmem_pages=$(awk '/zone/{z=$0} z~/(Normal|DMA32|DMA)/ && /managed/{s+=$2} END{print s+0}' \
        /proc/zoneinfo 2>/dev/null || echo 0)
    if [[ "${lowmem_pages:-0}" -le 0 ]]; then
        log "[WARN] wmark-default: cannot read zoneinfo — left as is"; return 0
    fi
    tmp=$(awk -v p="$lowmem_pages" 'BEGIN{printf "%d", 4*int(sqrt(p*4*16))}')
    [[ "$tmp" -lt 128 ]] && tmp=128
    [[ "$tmp" -gt 262144 ]] && tmp=262144
    sudo sysctl -w "vm.min_free_kbytes=${tmp}" >/dev/null
    sudo sysctl -w vm.watermark_scale_factor=10 >/dev/null
    log "wmark-default: min_free_kbytes=${tmp} watermark_scale_factor=10 (kernel defaults)"
}

cmd_wmark() {
    awk '
      /^Node/ { n=$2; sub(/,/,"",n); z=$4; f=mn=lo=hi=pr=mg=0; next }
      /^  pages free/ { f=$3 }
      $1=="min"     { mn=$2 }
      $1=="low"     { lo=$2 }
      $1=="high"    { hi=$2 }
      $1=="promo"   { pr=$2 }
      $1=="managed" { mg=$2
        if (mg > 0)
          printf "node%-2s %-8s managed=%7.0f free=%7.0f | min=%7.0f low=%7.0f high=%7.0f promo=%7.0f  (MB)\n",
                 n, z, mg/256, f/256, mn/256, lo/256, hi/256, pr/256 }
    ' /proc/zoneinfo
}

cmd_recvq() {
    local svc pid
    printf '%-14s %8s %10s %10s\n' SERVICE CONNS SUM_RECVQ MAX_RECVQ
    for svc in $SERVICES; do
        pid="$(_svc_pid "$svc")"
        [[ "$pid" -gt 0 ]] || continue
        sudo nsenter -t "$pid" -n ss -tn state established 2>/dev/null | awk -v s="$svc" '
            NR > 1 { n++; rq += $1; if ($1 > mx) mx = $1 }
            END { printf "%-14s %8d %10d %10d\n", s, n+0, rq+0, mx+0 }'
    done
    echo "--- host namespace (expected to be empty under the distributed layout)"
    ss -tn state established 2>/dev/null | awk '
        NR > 1 && ($3 ~ /:80(8[1-7]|00)$/ || $4 ~ /:80(8[1-7]|00)$/) { n++; rq += $1 }
        END { printf "    conns=%d  sum_recvq=%d\n", n+0, rq+0 }'
    echo "--- /proc/<pid>/net/tcp is the same view without nsenter:"
    for svc in $SERVICES; do
        pid="$(_svc_pid "$svc")"
        [[ "$pid" -gt 0 ]] || continue
        printf '    %-14s /proc/%s/net/tcp\n' "$svc" "$pid"
    done
}

cmd_tiering() {
    echo "numa_balancing         = $(sysctl -n kernel.numa_balancing 2>/dev/null || echo '(absent)')"
    echo "demotion_enabled       = $(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo '(absent)')"
    echo "numa_slow_tier_nodes   = $(cat /proc/sys/vm/numa_slow_tier_nodes 2>/dev/null || echo '(absent)')"
    echo "promote_rate_limit_MBps= $(sysctl -n kernel.numa_balancing_promote_rate_limit_MBps 2>/dev/null || echo '(absent)')"
    echo "min_free_kbytes        = $(sysctl -n vm.min_free_kbytes 2>/dev/null)"
    echo "watermark_scale_factor = $(sysctl -n vm.watermark_scale_factor 2>/dev/null)"
    echo "zone_reclaim_mode      = $(sysctl -n vm.zone_reclaim_mode 2>/dev/null)"
    echo "-- memory tiers (node0 and node2 must NOT share a tier)"
    local d found=0
    for d in /sys/devices/virtual/memory_tiering/memory_tier*; do
        [[ -d "$d" ]] || continue
        found=1
        echo "   $(basename "$d"): nodelist=$(cat "$d/nodelist" 2>/dev/null)"
    done
    [[ "$found" -eq 1 ]] || echo "   (memory_tiering sysfs absent — demotion target cannot be derived)"

    if [[ -r /proc/pebs_page_hist ]]; then
        echo "-- pebs working set (must read 'pages=0/...' for a Baseline run)"
        echo "   $(head -1 /proc/pebs_page_hist)"
    else
        echo "-- pebs working set: /proc/pebs_page_hist absent (hooks not in this kernel)"
    fi

    echo "-- counters"
    grep -E "^(pgpromote_success|pgpromote_candidate|pgdemote_kswapd|pgdemote_direct|pgdemote_khugepaged|numa_pages_migrated|numa_hint_faults|numa_hint_faults_local|pgmigrate_success|pgmigrate_fail|pgscan_kswapd|pgscan_direct|pgsteal_kswapd|pgsteal_direct)" /proc/vmstat
}

cmd_meminfo() {
    local n b
    for n in /sys/devices/system/node/node[0-9]*; do
        b=$(basename "$n")
        echo "### $b"
        grep -E "MemTotal|MemFree|MemUsed|FilePages|AnonPages" "$n/meminfo" 2>/dev/null || true
        awk -v b="$b" '/^nr_active_anon /{a=$2} /^nr_inactive_anon /{i=$2}
                       END{printf "%s ActiveAnon: %d MB  InactiveAnon: %d MB\n", b, a*4/1024, i*4/1024}' \
            "$n/vmstat" 2>/dev/null || true
    done
}

cmd_vmstat() {
    cat /proc/vmstat
}

cmd_nodefree() {
    numactl --hardware | awk '/^node [0-9]+ free:/ { print $2, $4 }'
}

cmd_nodesize() { _node_size_mb "${1:-0}"; }

if [[ "$APP_KIND" == "social" ]]; then
    DB_SNAPSHOT_DIR="${DB_SNAPSHOT_DIR:-${_REAL_HOME}/db_snapshot_baseline}"
else
    DB_SNAPSHOT_DIR="${DB_SNAPSHOT_DIR:-${_REAL_HOME}/db_snapshot_baseline_hotel}"
fi

_compose_project() {
    compose config --format json | python3 -c 'import json, sys; print(json.load(sys.stdin)["name"])'
}

cmd_restore_db() {
    local vols=("$@"); [[ ${#vols[@]} -eq 0 ]] && vols=(rate reservation)
    [[ -d "$DB_SNAPSHOT_DIR" ]] || die "restore-db: snapshot missing: ${DB_SNAPSHOT_DIR}"
    local project; project="$(_compose_project)"
    local v src dst
    for v in "${vols[@]}"; do
        src="${DB_SNAPSHOT_DIR}/${v}"
        dst="$(sudo docker info --format '{{.DockerRootDir}}')/volumes/${project}_${v}/_data"
        [[ -d "$src" ]] || die "restore-db: required snapshot missing: ${src}"
        sudo docker volume inspect "${project}_${v}" >/dev/null 2>&1 || \
            sudo docker volume create "${project}_${v}" >/dev/null
        sudo rsync -a --delete "${src}/" "${dst}/"
        log "restore-db: ${v} restored"
    done
}

_svc_pid() {
    local cid pid i
    for i in 1 2 3 4 5; do
        cid="$(compose ps -q "$1" 2>/dev/null || true)"
        if [[ -n "$cid" ]]; then
            pid="$(sudo docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)"
            [[ "${pid:-0}" -gt 0 ]] && { echo "$pid"; return; }
        fi
        sleep 1
    done
    echo 0
}

cmd_wait_ready() {
    local timeout="${1:-60}" svc cid out t0 tsvc waited=0 slow=""
    t0=$(date +%s)
    for svc in $SERVICES; do
        cid="$(compose ps -q "$svc" 2>/dev/null || true)"
        [[ -n "$cid" ]] || continue
        tsvc=$(date +%s)
        while :; do
            if (( $(date +%s) - tsvc > timeout )); then
                slow+=" ${svc}"
                break
            fi
            out="$(timeout 5 sudo docker exec "$cid" redis-cli ping 2>/dev/null || true)"
            if [[ -n "$out" ]]; then
                [[ "$out" == "PONG" ]] && break
                waited=1; sleep 2; continue
            fi
            out="$(timeout 5 sudo docker exec "$cid" mongo --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null || true)"
            if [[ -n "$out" ]]; then
                [[ "$out" == *1* ]] && break
                waited=1; sleep 2; continue
            fi
            break   # not a store this knows how to probe
        done
    done
    if [[ -n "$slow" ]]; then
        log "[WARN] wait-ready: still not answering after ${timeout}s —${slow}"
    else
        log "wait-ready: all stores answering after $(( $(date +%s) - t0 ))s$([[ "$waited" == 1 ]] && echo ' (waited on a load)')"
    fi
    return 0
}

cmd_rss() {
    local svc pid total=0 rss
    printf '%-14s %10s\n' SERVICE RSS_MB
    for svc in $SERVICES; do
        pid="$(_svc_pid "$svc")"
        if [[ "$pid" -le 0 || ! -r "/proc/${pid}/status" ]]; then
            printf '%-14s %10s\n' "$svc" "-"
            continue
        fi
        rss=$(( $(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status") / 1024 ))
        printf '%-14s %10s\n' "$svc" "$rss"
        total=$(( total + rss ))
    done
    printf '%-14s %10s\n' TOTAL "$total"
}

cmd_linkstats() {
    local svc pid
    printf '%-14s %-26s %10s %10s\n' SERVICE PEER RX_MB TX_MB
    for svc in $SERVICES; do
        pid="$(_svc_pid "$svc")"
        [[ "$pid" -gt 0 ]] || continue
        sudo nsenter -t "$pid" -n ss -tin 2>/dev/null | awk -v s="$svc" '
            /^ESTAB/ { peer = $5; next }
            {
                rx = 0; tx = 0
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^bytes_received:/) { split($i, a, ":"); rx = a[2] }
                    if ($i ~ /^bytes_sent:/)     { split($i, b, ":"); tx = b[2] }
                }
                if (peer != "" && (rx > 0 || tx > 0)) { RX[peer] += rx; TX[peer] += tx }
                peer = ""
            }
            END {
                for (p in RX)
                    printf "%-14s %-26s %10.2f %10.2f\n", s, p, RX[p]/1048576, TX[p]/1048576
            }'
    done
}

case "${1:-}" in
    down5)     cmd_down5 ;;
    up5)       cmd_up5 ;;
    ps)         cmd_ps ;;
    kver)       cmd_kver ;;
    sysctl-numa)     cmd_sysctl_one numa ;;
    sysctl-demotion) cmd_sysctl_one demotion ;;
    sysctl-minfree)  cmd_sysctl_one minfree ;;
    sysctl-wsf)      cmd_sysctl_one wsf ;;
    sysctl-thp)      cmd_sysctl_one thp ;;
    sysctl-htmm)     cmd_sysctl_one htmm ;;
    htmm)       shift; cmd_htmm "$@" ;;
    htmm-parent) shift; cmd_htmm_parent "$@" ;;
    cputopo)     cmd_cputopo ;;
    wait-ready)  shift; cmd_wait_ready "$@" ;;
    htmm-probe) cmd_htmm_probe ;;
    htmm-src)   cmd_htmm_src ;;
    htmm-tune)   cmd_htmm_tune ;;
    htmm-status)      cmd_htmm_status ;;
    dump)             shift; cmd_dump "$@" ;;
    why)              cmd_why ;;
    htmm-trace)       cmd_htmm_trace ;;
    htmm-trace-reset) cmd_htmm_trace_reset ;;
    maxnode0)   shift; cmd_maxnode0 "$@" ;;
    verify)    cmd_verify ;;
    prereq)    cmd_prereq ;;
    tier)            shift; cmd_tier "$@" ;;
    online)          cmd_online ;;
    memholder-start) shift; cmd_memholder_start "$@" ;;
    memholder-stop)  cmd_memholder_stop ;;
    cpuset)    shift; cmd_cpuset "$@" ;;
    numa)      shift; cmd_numa "$@" ;;
    watermark) shift; cmd_watermark "$@" ;;
    wmark)         cmd_wmark ;;
    wmark-default) cmd_wmark_default ;;
    tiering)   cmd_tiering ;;
    recvq)     cmd_recvq ;;
    meminfo)   cmd_meminfo ;;
    vmstat)    cmd_vmstat ;;
    nodefree)  cmd_nodefree ;;
    nodesize)  shift; cmd_nodesize "$@" ;;
    rss)       cmd_rss ;;
    linkstats) cmd_linkstats ;;
    restore-db) shift; cmd_restore_db "$@" ;;
    *)
        cat <<EOF
Usage: remote_b.sh <command>

  prereq                 FORWARD=ACCEPT, swapoff, governor=performance
  down5 / up5 / ps       control the services (up5 uses --no-deps)
  kver                   uname -r
  htmm-probe             is the htmm memcg interface present, and where
  htmm-src               print the kernel's write handler (KDIR= to override)
  cputopo                per-node cpulist + SMT siblings — the numbers you need
                         to pick CPUS_PER_SOCKET in include/linux/htmm.h
  htmm-parent [path]     flag docker's parent cgroup so containers inherit
                         htmm at creation — run ONCE after boot, BEFORE the
                         first up5, otherwise page tables get no metadata
  htmm <on|off> [MB]     enable/disable MEMTIS per service cgroup
                         (MEMTIS is inert until this is done)
  htmm-tune              apply the upstream run_bench.sh knob values
  htmm-status            every htmm knob, the threads, and per-cgroup state
  dump [file]            all of the above + kernel handler + dmesg, to one file
  why                    the ~10 lines that explain why ksamplingd is missing
  htmm-trace             ksamplingd's nr_sampled / nr_lost / cputime (ftrace)
  htmm-trace-reset       clear the ftrace buffer before a run
  maxnode0 <MB|max>      fast-tier cap via memory.max_at_node0, split by RSS
  verify                 assert exactly 5 running + config.json actually mounted
  tier <n0GB> [n2GB]     hot-unplug node0/node2 to the given sizes
  online                 restore both nodes to full size
  memholder-start <GB>   mlock GB on node0 (finer pressure than hot-unplug)
  memholder-stop         release it
  cpuset <mem-nodes>     docker update --cpuset-mems on the 5 services
  numa <nb> <demotion>   numa_balancing / demotion_enabled / slow_tier / zone_reclaim
  watermark <pct> <band> node0 Normal-zone watermarks at pct / pct+band
  wmark                  actual per-zone ladder (free vs min/low/high/promo), MB
  tiering                demotion prerequisites + promotion/demotion counters
  recvq                  per-service Recv-Q, container netns vs host netns
  meminfo / vmstat        collect measurements (stdout → controller run log)
  nodefree / rss          per-node free MB / per-service RSS MB
  nodesize <n>            managed size of node n, in MB
  linkstats               per-service cross-link bytes, by peer address:port
  restore-db [vol ...]    restore mongo volumes here (top3set placement only)
EOF
        exit 1
        ;;
esac
