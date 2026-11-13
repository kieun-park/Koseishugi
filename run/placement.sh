#!/bin/bash
set -Eeuo pipefail


_REAL_USER="${SUDO_USER:-${USER}}"
_REAL_HOME="$(getent passwd "${_REAL_USER}" | cut -d: -f6 2>/dev/null || echo "${HOME}")"

REMOTE_B="${REMOTE_B:-}"
HOST_A_IP="${HOST_A_IP:-}"
HOST_B_IP="${HOST_B_IP:-}"
DSB_DIR="${DSB_DIR:-${_REAL_HOME}/DeathStarBench/hotelReservation}"
REMOTE_DSB_DIR="${REMOTE_DSB_DIR:-\$HOME/DeathStarBench/hotelReservation}"
_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
PLACEMENT_ENV="${PLACEMENT_ENV:-${_SCRIPT_DIR}/placement.env}"

log() { echo "[placement] $*"; }
die() { echo "[placement][FATAL] $*" >&2; exit 1; }

_ssh() {
    local opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
    if [[ "${EUID:-$(id -u)}" -eq 0 && "$_REAL_USER" != "root" ]]; then
        sudo -u "$_REAL_USER" ssh "${opts[@]}" "$@"
    else
        ssh "${opts[@]}" "$@"
    fi
}

_stamp() { date '+%Y%m%d_%H%M%S'; }

backup_both() {
    local s; s="$(_stamp)"
    cp "${DSB_DIR}/config.json" "${DSB_DIR}/config.json.bak.${s}"
    [[ -f "${DSB_DIR}/docker-compose.override.yml" ]] && \
        cp "${DSB_DIR}/docker-compose.override.yml" "${DSB_DIR}/docker-compose.override.yml.bak.${s}"
    _ssh "$REMOTE_B" "cd ${REMOTE_DSB_DIR} && cp config.json config.json.bak.${s} && \
        [ -f docker-compose.override.yml ] && cp docker-compose.override.yml docker-compose.override.yml.bak.${s} || true"
    log "backed up both hosts with suffix .bak.${s}"
}

_jq_a_base='
  del(.GeoIP, .ProfileIP, .RateIP, .ReserveIP, .SearchIP)
| .consulAddress        = "consul:8500"
| .jaegerAddress        = "jaeger:6831"
| .GeoMongoAddress      = "mongodb-geo:27017"
| .ProfileMongoAddress  = "mongodb-profile:27017"
| .ProfileMemcAddress   = "memcached-profile:11211"
| .RateMongoAddress     = "mongodb-rate:27017"
| .RateMemcAddress      = "memcached-rate:11211"
| .ReserveMongoAddress  = "mongodb-reservation:27017"
| .ReserveMemcAddress   = "memcached-reserve:11211"
'

apply_top5() {
    backup_both

    jq "$_jq_a_base" "${DSB_DIR}/config.json" > "${DSB_DIR}/config.json.new"
    mv "${DSB_DIR}/config.json.new" "${DSB_DIR}/config.json"

    cat > "${DSB_DIR}/docker-compose.override.yml" <<'YAML'
services:
  mongodb-geo:
    ports:
      - "27021:27017"
  mongodb-profile:
    ports:
      - "27022:27017"
  mongodb-rate:
    ports:
      - "27023:27017"
  mongodb-reservation:
    ports:
      - "27024:27017"
  memcached-profile:
    ports:
      - "11221:11211"
  memcached-rate:
    ports:
      - "11222:11211"
  memcached-reserve:
    ports:
      - "11223:11211"
YAML

    _ssh "$REMOTE_B" "cd ${REMOTE_DSB_DIR} && jq '
        .consulAddress        = \"${HOST_A_IP}:8500\"
      | .jaegerAddress        = \"${HOST_A_IP}:6831\"
      | .GeoMongoAddress      = \"${HOST_A_IP}:27021\"
      | .ProfileMongoAddress  = \"${HOST_A_IP}:27022\"
      | .ProfileMemcAddress   = \"${HOST_A_IP}:11221\"
      | .RateMongoAddress     = \"${HOST_A_IP}:27023\"
      | .RateMemcAddress      = \"${HOST_A_IP}:11222\"
      | .ReserveMongoAddress  = \"${HOST_A_IP}:27024\"
      | .ReserveMemcAddress   = \"${HOST_A_IP}:11223\"
      | .GeoIP = \"${HOST_B_IP}\" | .ProfileIP = \"${HOST_B_IP}\"
      | .RateIP = \"${HOST_B_IP}\" | .ReserveIP = \"${HOST_B_IP}\"
      | .SearchIP = \"${HOST_B_IP}\"
      ' config.json > config.json.new && mv config.json.new config.json"

    _ssh "$REMOTE_B" "cat > ${REMOTE_DSB_DIR}/docker-compose.override.yml" <<'YAML'
services:
  geo:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8083:8083"
  profile:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8081:8081"
  rate:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8084:8084"
  reservation:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8087:8087"
  search:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8082:8082"
YAML

    cat > "$PLACEMENT_ENV" <<'ENV'
: "${PLACEMENT:=top5}"
: "${REMOTE_SERVICES:=geo profile rate reservation search}"
: "${VERIFY_REMOTE_SVCS:=srv-geo srv-profile srv-rate srv-reservation srv-search}"
: "${REMOTE_RESTORE_VOLS:=}"
ENV
    log "placement=top5 applied"
}

apply_top5mc() {
    backup_both

    jq "$_jq_a_base" "${DSB_DIR}/config.json" > "${DSB_DIR}/config.json.new"
    mv "${DSB_DIR}/config.json.new" "${DSB_DIR}/config.json"

    cat > "${DSB_DIR}/docker-compose.override.yml" <<'YAML'
services:
  mongodb-geo:
    ports:
      - "27021:27017"
  mongodb-profile:
    ports:
      - "27022:27017"
  mongodb-rate:
    ports:
      - "27023:27017"
  mongodb-reservation:
    ports:
      - "27024:27017"
YAML

    _ssh "$REMOTE_B" "cd ${REMOTE_DSB_DIR} && jq '
        .consulAddress        = \"${HOST_A_IP}:8500\"
      | .jaegerAddress        = \"${HOST_A_IP}:6831\"
      | .GeoMongoAddress      = \"${HOST_A_IP}:27021\"
      | .ProfileMongoAddress  = \"${HOST_A_IP}:27022\"
      | .RateMongoAddress     = \"${HOST_A_IP}:27023\"
      | .ReserveMongoAddress  = \"${HOST_A_IP}:27024\"
      | .ProfileMemcAddress   = \"memcached-profile:11211\"
      | .RateMemcAddress      = \"memcached-rate:11211\"
      | .ReserveMemcAddress   = \"memcached-reserve:11211\"
      | .GeoIP = \"${HOST_B_IP}\" | .ProfileIP = \"${HOST_B_IP}\"
      | .RateIP = \"${HOST_B_IP}\" | .ReserveIP = \"${HOST_B_IP}\"
      | .SearchIP = \"${HOST_B_IP}\"
      ' config.json > config.json.new && mv config.json.new config.json"

    _ssh "$REMOTE_B" "cat > ${REMOTE_DSB_DIR}/docker-compose.override.yml" <<'YAML'
services:
  geo:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8083:8083"
  profile:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8081:8081"
  rate:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8084:8084"
  reservation:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8087:8087"
  search:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8082:8082"
YAML

    cat > "$PLACEMENT_ENV" <<'ENV'
: "${PLACEMENT:=top5mc}"
: "${REMOTE_SERVICES:=geo profile rate reservation search memcached-profile memcached-rate memcached-reserve}"
: "${VERIFY_REMOTE_SVCS:=srv-geo srv-profile srv-rate srv-reservation srv-search}"
: "${REMOTE_RESTORE_VOLS:=}"
ENV
    log "placement=top5mc applied (no DB data migration needed)"
}

apply_top3set() {
    backup_both

    jq "${_jq_a_base} | .GeoIP = \"${HOST_A_IP}\"" "${DSB_DIR}/config.json" > "${DSB_DIR}/config.json.new"
    mv "${DSB_DIR}/config.json.new" "${DSB_DIR}/config.json"

    cat > "${DSB_DIR}/docker-compose.override.yml" <<'YAML'
services:
  geo:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8083:8083"
YAML

    _ssh "$REMOTE_B" "cd ${REMOTE_DSB_DIR} && jq '
        .consulAddress        = \"${HOST_A_IP}:8500\"
      | .jaegerAddress        = \"${HOST_A_IP}:6831\"
      | .RateMongoAddress     = \"mongodb-rate:27017\"
      | .RateMemcAddress      = \"memcached-rate:11211\"
      | .ReserveMongoAddress  = \"mongodb-reservation:27017\"
      | .ReserveMemcAddress   = \"memcached-reserve:11211\"
      | .RateIP = \"${HOST_B_IP}\" | .ReserveIP = \"${HOST_B_IP}\"
      | .SearchIP = \"${HOST_B_IP}\"
      | del(.GeoIP, .ProfileIP)
      ' config.json > config.json.new && mv config.json.new config.json"

    _ssh "$REMOTE_B" "cat > ${REMOTE_DSB_DIR}/docker-compose.override.yml" <<'YAML'
services:
  search:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8082:8082"
  rate:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8084:8084"
  reservation:
    volumes:
      - ./config.json:/workspace/config.json:ro
    ports:
      - "8087:8087"
YAML

    cat > "$PLACEMENT_ENV" <<'ENV'
: "${PLACEMENT:=top3set}"
: "${REMOTE_SERVICES:=search rate reservation mongodb-rate mongodb-reservation memcached-rate memcached-reserve}"
: "${VERIFY_REMOTE_SVCS:=srv-search srv-rate srv-reservation}"
: "${REMOTE_RESTORE_VOLS:=rate reservation}"
ENV
    log "placement=top3set applied"
    cat <<EOF

[placement] One manual step remains — Server B needs the rate/reservation DB data.
  Those snapshot directories are root-owned, so tar through the home directory
  rather than rsyncing them straight across (a direct rsync loses ownership):

    sudo tar cf ~/dbsnap_rate_reserve.tar -C ~/db_snapshot_baseline_hotel rate reservation
    sudo chown ${_REAL_USER}: ~/dbsnap_rate_reserve.tar
    rsync -a --info=progress2 ~/dbsnap_rate_reserve.tar ${REMOTE_B}:~/

    mkdir -p ~/db_snapshot_baseline_hotel
    sudo tar xf ~/dbsnap_rate_reserve.tar -C ~/db_snapshot_baseline_hotel

  After that, reset_stack restores them on Server B via REMOTE_RESTORE_VOLS.
EOF
}

cmd_status() {
    echo "── placement.env"
    [[ -f "$PLACEMENT_ENV" ]] && cat "$PLACEMENT_ENV" || echo "  (none — placement never applied)"
    echo
    echo "── Server A  config.json (*IP keys and addresses)"
    grep -E '"(consulAddress|jaegerAddress|[A-Za-z]+(Mongo|Memc)Address|[A-Za-z]+IP)"' "${DSB_DIR}/config.json" || true
    echo
    echo "── Server A  running services"
    (cd "$DSB_DIR" && sudo docker compose ps --services --filter status=running 2>/dev/null | sort | tr '\n' ' '; echo)
    echo
    echo "── Server B  config.json"
    _ssh "$REMOTE_B" "grep -E '\"(consulAddress|jaegerAddress|[A-Za-z]+(Mongo|Memc)Address|[A-Za-z]+IP)\"' ${REMOTE_DSB_DIR}/config.json" || true
    echo
    echo "── Server B  running services"
    _ssh "$REMOTE_B" "cd ${REMOTE_DSB_DIR} && sudo docker compose ps --services --filter status=running 2>/dev/null | sort | tr '\n' ' '; echo" || true
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 <top5mc|top5|top3set|status>; see run/README.md for required host settings"
    exit 0
fi
[[ -n "$REMOTE_B" && -n "$HOST_A_IP" && -n "$HOST_B_IP" ]] || die "Set REMOTE_B, HOST_A_IP, and HOST_B_IP"
command -v jq >/dev/null 2>&1 || die "jq is required (sudo apt install jq)"

case "${1:-}" in
    top5)    apply_top5 ;;
    top5mc)  apply_top5mc ;;
    top3set) apply_top3set ;;
    status)  cmd_status ;;
    *)
        cat <<EOF
Usage: placement.sh <top5mc|top5|top3set|status>

  top5mc    RECOMMENDED. Server B = the RSS top-5 services plus their three
            memcached instances. MongoDB stays on Server A. Removes ~94% of the
            cross-link bytes, keeps the RSS top-5 selection unchanged, and needs
            no DB data migration (memcached has no persistent state).

  top5      The layout measured so far: Server B = geo profile rate reservation
            search, every store on Server A. Use to reproduce earlier numbers.

  top3set   Fallback. Server B = search rate reservation + mongodb-rate
            mongodb-reservation memcached-rate memcached-reserve. geo and
            profile move back to Server A with their stores; geo gets a
            published port because search calls it from Server B.
            Requires a one-time DB data copy to Server B.

  status    Show the active placement on both hosts.

After switching, bring the stack up with the new layout:
  sudo DIST_MODE=on bash hotel_run_eval.sh --setup
EOF
        exit 1
        ;;
esac
