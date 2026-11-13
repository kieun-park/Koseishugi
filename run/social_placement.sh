#!/bin/bash
set -Eeuo pipefail


_REAL_USER="${SUDO_USER:-${USER}}"
_REAL_HOME="$(getent passwd "${_REAL_USER}" | cut -d: -f6 2>/dev/null || echo "${HOME}")"
_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

DSB_DIR_A="${DSB_DIR_A:-${_REAL_HOME}/DeathStarBench/socialNetwork}"
DSB_DIR_B="${DSB_DIR_B:-${DSB_DIR_A}}"
REMOTE_B="${REMOTE_B:-}"
HOST_A_IP="${HOST_A_IP:-}"
HOST_B_IP="${HOST_B_IP:-}"
HOST_B_IP2="${HOST_B_IP2:-}"
REMOTE_AGENT="${REMOTE_AGENT:-}"
IP_ALIAS_DEV="${IP_ALIAS_DEV:-}"
IP_ALIAS_PREFIX="${IP_ALIAS_PREFIX:-24}"
REMOTE_DB_SNAPSHOT_DIR="${REMOTE_DB_SNAPSHOT_DIR:-}"
ENV_OUT="${ENV_OUT:-${_SCRIPT_DIR}/social_placement.env}"

log() { echo "[social_placement] $(date '+%H:%M:%S') $*"; }
die() { echo "[social_placement][FATAL] $*" >&2; exit 1; }

_ssh() {
    local opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${_REAL_USER:-}" && "$_REAL_USER" != "root" ]]; then
        sudo -u "$_REAL_USER" ssh "${opts[@]}" "$@"
    else
        ssh "${opts[@]}" "$@"
    fi
}

B_SERVICES="home-timeline-service social-graph-service home-timeline-redis social-graph-redis post-storage-mongodb url-shorten-mongodb user-timeline-mongodb"

B_SUPPORT="jaeger-agent"

B_EXPORTS=(
    "home-timeline-service:${HOST_B_IP}:9090:9090"
    "social-graph-service:${HOST_B_IP2}:9090:9090"
    "post-storage-mongodb:${HOST_B_IP}:27019:27017"
    "user-timeline-mongodb:${HOST_B_IP}:27020:27017"
    "url-shorten-mongodb:${HOST_B_IP}:27021:27017"
)

A_EXPORTS=(
    "post-storage-service:${HOST_A_IP}:10002:9090:nopublish"
    "user-service:${HOST_A_IP}:10005:9090:publish"
    "social-graph-mongodb:${HOST_A_IP}:27018:27017:publish"
)

NGINX_EXTRA_HOSTS=(
    "home-timeline-service:${HOST_B_IP}"
    "social-graph-service:${HOST_B_IP2}"
)

_assert_on_server_a() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 -o addr show 2>/dev/null | grep -q " ${HOST_A_IP}/" && return 0
    die "run this on Server A (${HOST_A_IP}). This host does not hold that address — on Server B use 'rbs' instead."
}

_field() { cut -d: -f"$2" <<<"$1"; }

_PY_REWRITE='
import json, sys
path, mapping = sys.argv[1], json.loads(sys.argv[2])
with open(path) as f:
    cfg = json.load(f)
missing = []
for svc in sorted(mapping):
    addr, port = mapping[svc]
    if svc not in cfg:
        missing.append(svc)
        continue
    cfg[svc]["addr"] = addr
    cfg[svc]["port"] = int(port)
    print("  %-24s -> %s:%s" % (svc, addr, port))
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
if missing:
    print("[WARN] absent from service-config.json: " + " ".join(missing))
'

_PY_READ='
import json, sys
cfg = json.load(open(sys.argv[1]))
for svc in sys.argv[2:]:
    e = cfg.get(svc)
    print("   %-24s %s" % (svc, "%s:%s" % (e["addr"], e["port"]) if e else "ABSENT"))
'

_map_json() {
    local e first=1 out="{"
    for e in "$@"; do
        [[ $first -eq 1 ]] || out+=","
        first=0
        out+="\"$(_field "$e" 1)\":[\"$(_field "$e" 2)\",$(_field "$e" 3)]"
    done
    printf '%s}' "$out"
}

_gen_cfg_script() {
    local cfg="$1"; shift
    local b64 map
    b64="$(printf '%s' "$_PY_REWRITE" | base64 -w0)"
    map="$(_map_json "$@")"
    cat <<EOF
set -Eeuo pipefail
cfg='${cfg}'
command -v python3 >/dev/null 2>&1 || { echo "[FATAL] python3 is required" >&2; exit 1; }
[ -f "\$cfg" ] || { echo "[FATAL] \$cfg not found" >&2; exit 1; }
[ -f "\$cfg.orig" ] || cp -a "\$cfg" "\$cfg.orig"
cp -a "\$cfg.orig" "\$cfg"
echo '${b64}' | base64 -d | python3 - "\$cfg" '${map}'
echo "service-config.json rewritten"
EOF
}

_PY_LUA='
import os, re, sys
root = sys.argv[1]
mapping = dict(a.split("=", 1) for a in sys.argv[2:])
changed, leftover = [], []
for dirpath, _, files in os.walk(root):
    for fn in files:
        if not fn.endswith(".lua"):
            continue
        p = os.path.join(dirpath, fn)
        src = open(p, encoding="utf-8", errors="replace").read()
        out = src
        for name, ip in mapping.items():
            out = re.sub(r"\"%s\"\s*\.\.\s*k8s_suffix" % re.escape(name),
                         "\"%s\"" % ip, out)
        if out != src:
            if not os.path.exists(p + ".orig"):
                open(p + ".orig", "w", encoding="utf-8").write(src)
            open(p, "w", encoding="utf-8").write(out)
            changed.append(os.path.relpath(p, root))
        for name in mapping:
            if ("\"%s\"" % name) in out:
                leftover.append("%s (%s)" % (os.path.relpath(p, root), name))
for c in sorted(set(changed)):
    print("  patched  " + c)
for l in sorted(set(leftover)):
    print("  [WARN] still refers to the name by hand: " + l)
if not changed:
    print("  (nothing to patch — already done, or the lua tree moved)")
'

_patch_nginx_lua() {
    local root="${DSB_DIR_A}/nginx-web-server/lua-scripts"
    [[ -d "$root" ]] || { log "[WARN] lua tree not at ${root} — skipped"; return 0; }
    local b64 args=() h
    for h in "${NGINX_EXTRA_HOSTS[@]}"; do args+=("${h%%:*}=${h##*:}"); done
    b64="$(printf '%s' "$_PY_LUA" | base64 -w0)"
    echo "$b64" | base64 -d | python3 - "$root" "${args[@]}"
    return 0
}

_restore_nginx_lua() {
    local root="${DSB_DIR_A}/nginx-web-server/lua-scripts"
    [[ -d "$root" ]] || return 0
    find "$root" -name '*.lua.orig' -print0 2>/dev/null | while IFS= read -r -d '' f; do
        mv -f "$f" "${f%.orig}" && echo "  restored ${f%.orig}"
    done
    return 0
}

_gen_override_b() {
    local e
    echo "# generated by social_placement.sh — do not edit by hand"
    echo "services:"
    for e in "${B_EXPORTS[@]}"; do
        printf '  %s:\n    ports:\n      - "%s:%s:%s"\n' \
            "$(_field "$e" 1)" "$(_field "$e" 2)" "$(_field "$e" 3)" "$(_field "$e" 4)"
    done
}

_gen_override_a() {
    local e h
    echo "# generated by social_placement.sh — do not edit by hand"
    echo "services:"
    for e in "${A_EXPORTS[@]}"; do
        [[ "$(_field "$e" 5)" == "publish" ]] || continue
        printf '  %s:\n    ports:\n      - "%s:%s:%s"\n' \
            "$(_field "$e" 1)" "$(_field "$e" 2)" "$(_field "$e" 3)" "$(_field "$e" 4)"
    done
    printf '  nginx-thrift:\n    extra_hosts:\n'
    for h in "${NGINX_EXTRA_HOSTS[@]}"; do printf '      - "%s"\n' "$h"; done
}

cmd_top7() {
    _assert_on_server_a
    local e args=() tmp
    log "Server A: rewriting config/service-config.json"
    args=()
    for e in "${B_EXPORTS[@]}"; do
        args+=("$(_field "$e" 1):$(_field "$e" 2):$(_field "$e" 3)")
    done
    args+=("home-timeline-redis:${HOST_B_IP}:6379" "social-graph-redis:${HOST_B_IP}:6379")
    _gen_cfg_script "${DSB_DIR_A}/config/service-config.json" "${args[@]}" | bash

    log "Server A: writing docker-compose.override.yml"
    _gen_override_a > "${DSB_DIR_A}/docker-compose.override.yml"

    log "Server A: pointing nginx's lua at Server B by address"
    _patch_nginx_lua

    log "Server B: rewriting config/service-config.json"
    args=()
    for e in "${A_EXPORTS[@]}"; do
        args+=("$(_field "$e" 1):$(_field "$e" 2):$(_field "$e" 3)")
    done
    _gen_cfg_script "${DSB_DIR_B}/config/service-config.json" "${args[@]}" \
        | _ssh "$REMOTE_B" "bash -s"

    log "Server B: writing docker-compose.override.yml"
    tmp="$(mktemp)"; _gen_override_b > "$tmp"
    _ssh "$REMOTE_B" "cat > '${DSB_DIR_B}/docker-compose.override.yml'" < "$tmp"
    rm -f "$tmp"

    log "Server B: installing the rbs wrapper"
    tmp="$(mktemp)"
    {
        printf '#!/bin/bash\n# Generated socialNetwork context.\nexec '
        printf '%q ' env APP_KIND=social "SERVICES=${B_SERVICES} ${B_SUPPORT}" \
            "DSB_DIR=$DSB_DIR_B" "DB_SNAPSHOT_DIR=$REMOTE_DB_SNAPSHOT_DIR" \
            "HOST_A_IP=$HOST_A_IP" "HOST_B_IP=$HOST_B_IP" \
            "IP_ALIAS=${HOST_B_IP2}/${IP_ALIAS_PREFIX}" "IP_ALIAS_DEV=$IP_ALIAS_DEV" \
            bash "$REMOTE_AGENT"
        printf ' "$@"\n'
    } > "$tmp"

    local wrapper; printf -v wrapper '%q' "${REMOTE_AGENT%/*}/rbs"
    _ssh "$REMOTE_B" "cat > $wrapper && chmod +x $wrapper" < "$tmp"
    rm -f "$tmp"

    log "Server B: ensuring the ${HOST_B_IP2} alias exists"
    local prereq_cmd
    printf -v prereq_cmd '%q ' env APP_KIND=social "IP_ALIAS=${HOST_B_IP2}/${IP_ALIAS_PREFIX}" "IP_ALIAS_DEV=$IP_ALIAS_DEV" bash "$REMOTE_AGENT" prereq
    _ssh "$REMOTE_B" "$prereq_cmd"


    cat > "$ENV_OUT" <<EOF
REMOTE_SERVICES="${B_SERVICES} ${B_SUPPORT}"
REMOTE_MEASURED="${B_SERVICES}"
REMOTE_RESTORE_VOLS="post-storage-mongodb-data url-shorten-mongodb-data user-timeline-mongodb-data social-graph-redis-data home-timeline-redis-data"
LOCAL_RESTORE_VOLS="social-graph-mongodb-data user-mongodb-data media-mongodb-data user-timeline-redis-data"
: "\${HOST_B_IP:=${HOST_B_IP}}"
: "\${HOST_B_IP2:=${HOST_B_IP2}}"
EOF
    log "wrote ${ENV_OUT}"
    log "placement top7 applied. Run 'social_placement.sh check' once both stacks are up."
}

cmd_single() {
    _assert_on_server_a
    log "restoring nginx's lua scripts"
    _restore_nginx_lua
    log "reverting both hosts to the pristine service-config.json"
    for h in A B; do
        local d s
        if [[ "$h" == "A" ]]; then d="$DSB_DIR_A"; else d="$DSB_DIR_B"; fi
        s="set -e; [ -f '${d}/config/service-config.json.orig' ] && cp -a '${d}/config/service-config.json.orig' '${d}/config/service-config.json' && echo restored || echo '[WARN] no .orig'; rm -f '${d}/docker-compose.override.yml'"
        if [[ "$h" == "A" ]]; then bash -c "$s"; else _ssh "$REMOTE_B" "$s"; fi
    done
    rm -f "$ENV_OUT"
    log "reverted. Everything now resolves on the local compose network."
}

cmd_status() {
    _assert_on_server_a
    local e names b64 script
    b64="$(printf '%s' "$_PY_READ" | base64 -w0)"

    names=""; for e in "${B_EXPORTS[@]}"; do names+=" $(_field "$e" 1)"; done
    names+=" home-timeline-redis social-graph-redis"
    echo "-- Server A resolves these to (should be Server B):"
    script="echo '${b64}' | base64 -d | python3 - '${DSB_DIR_A}/config/service-config.json'${names}"
    bash -c "$script" 2>/dev/null || echo "   (cannot read ${DSB_DIR_A}/config/service-config.json)"

    names=""; for e in "${A_EXPORTS[@]}"; do names+=" $(_field "$e" 1)"; done
    echo "-- Server B resolves these to (should be Server A):"
    script="echo '${b64}' | base64 -d | python3 - '${DSB_DIR_B}/config/service-config.json'${names}"
    _ssh "$REMOTE_B" "$script" 2>/dev/null || echo "   (cannot read Server B's service-config.json)"

    echo "-- overrides"
    printf '   A %s\n' "$([[ -f ${DSB_DIR_A}/docker-compose.override.yml ]] && echo present || echo MISSING)"
    printf '   B %s\n' "$(_ssh "$REMOTE_B" "[ -f '${DSB_DIR_B}/docker-compose.override.yml' ] && echo present || echo MISSING" 2>/dev/null || echo '?')"
    printf '   B alias %s\n' "$(_ssh "$REMOTE_B" "ip -br addr show 2>/dev/null | grep -c ${HOST_B_IP2} || echo 0" 2>/dev/null || echo '?')"
}

cmd_check() {
    _assert_on_server_a
    local e host port fail=0
    echo "-- Server A host -> Server B"
    for e in "${B_EXPORTS[@]}"; do
        host="$(_field "$e" 2)"; port="$(_field "$e" 3)"
        if timeout 3 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
            printf '   OK    %-24s %s:%s\n' "$(_field "$e" 1)" "$host" "$port"
        else
            printf '   FAIL  %-24s %s:%s\n' "$(_field "$e" 1)" "$host" "$port"; fail=1
        fi
    done

    echo "-- nginx lua targets   ★ the lua must carry addresses, not names"
    local n root
    root="${DSB_DIR_A}/nginx-web-server/lua-scripts"
    for n in "${NGINX_EXTRA_HOSTS[@]}"; do
        if grep -rqs -- "\"${n##*:}\"" "$root" 2>/dev/null; then
            printf '   OK    %-24s -> %s in lua\n' "${n%%:*}" "${n##*:}"
        elif grep -rqs -- "\"${n%%:*}\"" "$root" 2>/dev/null; then
            printf '   FAIL  %-24s still called by NAME in lua — run top7\n' "${n%%:*}"; fail=1
        else
            printf '   --    %-24s not referenced by any lua script\n' "${n%%:*}"
        fi
    done
    local probe
    probe="$(_ssh "$REMOTE_B" "sudo docker ps -qf name=post-storage-mongodb | head -1" 2>/dev/null || true)"

    echo "-- Server B host -> Server A"
    for e in "${A_EXPORTS[@]}"; do
        host="$(_field "$e" 2)"; port="$(_field "$e" 3)"
        if _ssh "$REMOTE_B" "timeout 3 bash -c '</dev/tcp/${host}/${port}'" 2>/dev/null; then
            printf '   OK    %-24s %s:%s\n' "$(_field "$e" 1)" "$host" "$port"
        else
            printf '   FAIL  %-24s %s:%s\n' "$(_field "$e" 1)" "$host" "$port"; fail=1
        fi
    done

    if [[ -z "$probe" ]]; then
        echo "-- Server B CONTAINER -> Server A   (skipped: no container to probe from;"
        echo "   bring Server B's stack up and re-run — this is the check that matters)"
    else
        echo "-- Server B CONTAINER -> Server A   ★ this is the one that matters"
        for e in "${A_EXPORTS[@]}"; do
            host="$(_field "$e" 2)"; port="$(_field "$e" 3)"
            if _ssh "$REMOTE_B" "sudo docker exec ${probe} timeout 3 bash -c '</dev/tcp/${host}/${port}'" 2>/dev/null; then
                printf '   OK    %-24s %s:%s\n' "$(_field "$e" 1)" "$host" "$port"
            else
                printf '   FAIL  %-24s %s:%s\n' "$(_field "$e" 1)" "$host" "$port"; fail=1
            fi
        done
        echo "   (probed from the post-storage-mongodb container on Server B)"
    fi
    [[ "$fail" -eq 0 ]] && echo "-- all endpoints reachable" || echo "-- SOME ENDPOINTS ARE CLOSED (see FAIL above)"
    return 0
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 <top7|single|status|check>; see run/README.md for required host settings"
    exit 0
fi
[[ -n "$REMOTE_B" && -n "$HOST_A_IP" && -n "$HOST_B_IP" && -n "$HOST_B_IP2" ]] || die "Set REMOTE_B, HOST_A_IP, HOST_B_IP, and HOST_B_IP2"
if [[ "${1:-}" == "top7" ]]; then
    [[ "$REMOTE_AGENT" == /* && -n "$IP_ALIAS_DEV" && "$REMOTE_DB_SNAPSHOT_DIR" == /* ]] || die "Set absolute REMOTE_AGENT/REMOTE_DB_SNAPSHOT_DIR and IP_ALIAS_DEV"
fi
case "${1:-}" in
    top7)   cmd_top7 ;;
    single) cmd_single ;;
    status) cmd_status ;;
    check)  cmd_check ;;
    *) cat <<EOF
Usage: social_placement.sh <top7|single|status|check>

  top7    move 7 services to Server B and rewrite both hosts' wiring
  single  revert to the pristine single-host configuration
  status  show what addr:port each host resolves its peers to
  check   TCP-connect every exported endpoint from the host that dials it
EOF
    exit 1 ;;
esac
