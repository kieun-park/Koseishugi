#!/usr/bin/env bash
set -u

INTERVAL="${INTERVAL:-2}"          # seconds between samples
DURATION="${DURATION:-0}"          # 0 = run until interrupted
ONLY="${ONLY:-}"                   # comma-separated substrings; empty = all
LOG_DIR="${LOG_DIR:-./logs}"
REFRESH_EVERY="${REFRESH_EVERY:-30}"  # re-resolve container PIDs every N samples

if [[ "${1:-}" == "--coverage" ]]; then
    shift
    [[ $# -ge 1 ]] || { echo "usage: $0 --coverage <csv> [denylist-regex]"; exit 1; }
    DENY="${2:-nginx|frontend|jaeger|storage}"
    coverage_tmp="$(mktemp "${TMPDIR:-/tmp}/services_coverage.XXXXXX")" || exit 1
    trap 'rm -f -- "$coverage_tmp"' EXIT

    awk -F, -v deny="$DENY" 'NR>1 && $7+0 > 0 && $2 !~ deny {
        if ($3+0 > m[$1]+0) m[$1]=$3
    } END { for (t in m) print m[t]+0 }' "$1" | sort -n > "$coverage_tmp"

    total=$(wc -l < "$coverage_tmp")
    [[ "$total" -gt 0 ]] || { echo "no eligible samples"; exit 1; }

    echo "eligible sampling instants: $total   (denylist: $DENY)"
    echo
    printf "%14s %14s\n" "coverage(%)" "theta_q(KiB)"
    for c in 95 90 70 50 30 10 5 1; do
        th=$(awk -v c="$c" -v n="$total" 'NR==int((100-c)/100*n)+1 {print $1; exit}' "$coverage_tmp")
        awk -v c="$c" -v t="${th:-0}" 'BEGIN{printf "%14d %14.2f\n", c, t/1024}'
    done
    echo
    echo "coverage at current theta_q (1 KiB):"
    awk -v th=1024 -v n="$total" '$1+0 >= th {c++} END {printf "  %.1f%%\n", 100*c/n}' "$coverage_tmp"
    exit 0
fi

if [[ "${1:-}" == "--summary" ]]; then
    shift
    [[ $# -ge 1 ]] || { echo "usage: $0 --summary <csv>"; exit 1; }
    echo "== receive queue =="
    awk -F, 'NR>1 && $7+0 > 0 {
        n[$2]++
        q[$2]+=$3;   if ($3+0 > qmax[$2]+0) qmax[$2]=$3
                     if ($4+0 > smax[$2]+0) smax[$2]=$4
        if ($3+0 > 0) nz[$2]++
        e[$2]+=$5;   if ($6+0 > lmax[$2]+0) lmax[$2]=$6
    }
    END {
        printf "%-30s %8s %13s %13s %12s %8s %10s %10s\n", \
               "service", "samples", "recvq_avg(B)", "recvq_max(B)", \
               "1sock_max(B)", "nonzero%", "estab_avg", "listenq_max"
        for (k in n)
            printf "%-30s %8d %13.0f %13.0f %12.0f %8.1f %10.1f %10d\n", \
                   k, n[k], q[k]/n[k], qmax[k], smax[k], \
                   100*nz[k]/n[k], e[k]/n[k], lmax[k]
    }' "$1" | (read -r h; echo "$h"; sort -k1,1)

    echo
    echo "== memory footprint =="
    awk -F, 'NR>1 && $7+0 > 0 {
        n[$2]++
        c[$2]+=$7; if ($7+0 > cmax[$2]+0) cmax[$2]=$7
        a[$2]+=$8; if ($8+0 > amax[$2]+0) amax[$2]=$8
        f[$2]+=$9; if ($9+0 > fmax[$2]+0) fmax[$2]=$9
    }
    END {
        printf "%-30s %12s %12s %11s %11s %11s %11s\n", \
               "service", "mem_avg(MB)", "mem_max(MB)", \
               "anon_avg", "anon_max", "file_avg", "file_max"
        for (k in n)
            printf "%-30s %12.1f %12.1f %11.1f %11.1f %11.1f %11.1f\n", \
                   k, (c[k]/n[k])/1048576, cmax[k]/1048576, \
                   (a[k]/n[k])/1048576, amax[k]/1048576, \
                   (f[k]/n[k])/1048576, fmax[k]/1048576
    }' "$1" | (read -r h; echo "$h"; sort -k1,1)
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "run with sudo (nsenter requires root)"; exit 1; }

mkdir -p "$LOG_DIR"
OUT="${OUT:-$LOG_DIR/services_$(date +%Y%m%d_%H%M%S).csv}"
echo "ts,service,recvq_sum,recvq_max,estab,listenq,mem_cur,anon,file" > "$OUT"
echo "sampling every ${INTERVAL}s -> $OUT   (Ctrl-C to stop)"

declare -A PID CG

resolve_targets() {
    PID=(); CG=()
    while IFS='|' read -r id name; do
        [[ -z "$name" ]] && continue
        if [[ -n "$ONLY" ]]; then
            keep=0
            IFS=',' read -ra pats <<< "$ONLY"
            for p in "${pats[@]}"; do [[ "$name" == *"$p"* ]] && keep=1; done
            [[ $keep -eq 1 ]] || continue
        fi
        p=$(docker inspect -f '{{.State.Pid}}' "$id" 2>/dev/null) || continue
        [[ -z "$p" || "$p" == "0" ]] && continue
        PID["$name"]=$p
        cg=$(awk -F: '$1=="0"{print $3}' "/proc/$p/cgroup" 2>/dev/null)
        CG["$name"]="/sys/fs/cgroup${cg}"
    done < <(docker ps --format '{{.ID}}|{{.Names}}')
    echo "tracking ${#PID[@]} containers"
}

sample_sockets() {   # $1 = pid  ->  "recvq_sum recvq_max estab listenq"
    nsenter -t "$1" -n ss -ntaH 2>/dev/null | awk '
        $1=="ESTAB"  { s+=$2; if ($2+0 > m+0) m=$2; n++ }
        $1=="LISTEN" { l+=$2 }
        END { printf "%d %d %d %d", s+0, m+0, n+0, l+0 }'
}

sample_memory() {    # $1 = cgroup path  ->  "mem_cur anon file"
    local cur anon file
    cur=$(cat "$1/memory.current" 2>/dev/null || echo 0)
    anon=$(awk '$1=="anon"{print $2; exit}' "$1/memory.stat" 2>/dev/null || echo 0)
    file=$(awk '$1=="file"{print $2; exit}' "$1/memory.stat" 2>/dev/null || echo 0)
    echo "${cur:-0} ${anon:-0} ${file:-0}"
}

trap 'echo; echo "stopped. log: $OUT"; echo "summary: $0 --summary $OUT"; exit 0' INT TERM

resolve_targets
start=$(date +%s)
count=0

while :; do
    ts=$(date +%s)
    [[ "$DURATION" -gt 0 && $((ts - start)) -ge "$DURATION" ]] && break

    for name in "${!PID[@]}"; do
        if [[ ! -d "/proc/${PID[$name]}" ]]; then resolve_targets; break; fi
    done

    for name in "${!PID[@]}"; do
        read -r q qmax estab lq <<< "$(sample_sockets "${PID[$name]}")"
        read -r cur anon file  <<< "$(sample_memory "${CG[$name]}")"
        echo "$ts,$name,$q,$qmax,$estab,$lq,$cur,$anon,$file" >> "$OUT"
    done

    count=$((count + 1))
    if [[ $((count % REFRESH_EVERY)) -eq 0 ]]; then resolve_targets; fi
    sleep "$INTERVAL"
done

echo "done. log: $OUT"
echo "summary: $0 --summary $OUT"
