#!/bin/bash
set -euo pipefail


DEFAULT_MEM_NODE="${DEFAULT_MEM_NODE:-0}"
TARGET_MEM_NODE="${TARGET_MEM_NODE:-2}"

_cpulist_of() {
  local cpulist
  cpulist="$(cat "/sys/devices/system/node/node${1}/cpulist" 2>/dev/null || echo '')"
  if [[ -z "$cpulist" ]]; then
    cpulist="$(cat /sys/devices/system/node/node0/cpulist 2>/dev/null || echo '0')"
  fi
  echo "$cpulist"
}
DEFAULT_CPUSET="${DEFAULT_CPUSET:-$(_cpulist_of "${DEFAULT_MEM_NODE}")}"
TARGET_CPUSET="${TARGET_CPUSET:-$(_cpulist_of "${TARGET_MEM_NODE}")}"

TARGET_SPECS=()

usage() {
  cat <<EOF
Usage: $0 [--<container-name-or-glob> ...] [--svc:<compose-service> ...]

Env:
  DEFAULT_MEM_NODE  default: ${DEFAULT_MEM_NODE}
  TARGET_MEM_NODE   default: ${TARGET_MEM_NODE}

Examples:
  $0 --socialnetwork-home-timeline-redis-1   # by container name
  $0 --socialnetwork-home-timeline-redis-*   # by glob
  $0 --svc:home-timeline-redis               # by compose service label
EOF
}

for a in "$@"; do
  if [[ "$a" == "--help" || "$a" == "-h" ]]; then
    usage; exit 0
  fi
  if [[ "$a" == --* ]]; then
    spec="${a:2}"
    TARGET_SPECS+=("$spec")
    [[ "${spec//_/-}" != "$spec" ]] && TARGET_SPECS+=("${spec//_/-}")
  fi
done

echo "[numa_bind] Applying NUMA bindings..."
echo "[numa_bind] DEFAULT : CPUSET=${DEFAULT_CPUSET} MEM=${DEFAULT_MEM_NODE}"

if [[ ${#TARGET_SPECS[@]} -eq 0 ]]; then
  echo "[numa_bind] (no target specs — all containers → DEFAULT)"
else
  echo "[numa_bind] TARGET  : CPUSET=${TARGET_CPUSET} MEM=${TARGET_MEM_NODE}"
  echo "[numa_bind] TARGETS : ${TARGET_SPECS[*]}"
fi

compose_service_of() {
  local id="$1"
  docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null || true
}

is_target() {
  local cname="$1"
  local svc="$2"
  local spec
  for spec in "${TARGET_SPECS[@]}"; do
    if [[ "$spec" == svc:* ]]; then
      local wanted="${spec#svc:}"
      [[ -n "$svc" ]] || continue
      if [[ "$svc" == $wanted ]]; then
        return 0
      fi
    else
      if [[ "$cname" == $spec ]]; then
        return 0
      fi
    fi
  done
  return 1
}

container_ids="$(docker compose ps --status running -q)"
[[ -n "$container_ids" ]] || { echo "[numa_bind] No running containers in this Compose project" >&2; exit 1; }
while read -r cid; do
  cname="$(docker inspect -f '{{.Name}}' "$cid")"
  cname="${cname#/}"
  [[ -n "$cid" && -n "$cname" ]] || continue
  svc="$(compose_service_of "$cid")"

  if is_target "$cname" "$svc"; then
    echo "[numa_bind] ▶ [Target]  ${cname} (svc=${svc}) -> CPU=${TARGET_CPUSET} MEM=${TARGET_MEM_NODE}"
    docker update --cpuset-cpus="${TARGET_CPUSET}" --cpuset-mems="${TARGET_MEM_NODE}" "$cid" >/dev/null
  else
    echo "[numa_bind] ▶ [Default] ${cname} (svc=${svc}) -> CPU=${DEFAULT_CPUSET} MEM=${DEFAULT_MEM_NODE}"
    docker update --cpuset-cpus="${DEFAULT_CPUSET}" --cpuset-mems="${DEFAULT_MEM_NODE}" "$cid" >/dev/null
  fi
done <<< "$container_ids"

echo "[numa_bind] Done."
