#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [config.yaml]"
    exit 0
fi
[[ $# -le 1 ]] || { echo "Usage: $0 [config.yaml]" >&2; exit 2; }
CFG="${1:-${ROOT_DIR}/config.yaml}"
[[ -r "$CFG" ]] || { echo "Configuration not readable: $CFG" >&2; exit 1; }
CFG="$(readlink -f "$CFG")"
[[ "$EUID" -eq 0 ]] || { echo "Run the agent with sudo; kernel and namespace access require root." >&2; exit 1; }

mkdir -p "$ROOT_DIR/bin"
"${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra -pthread -I"$ROOT_DIR" \
    "$ROOT_DIR"/app/*.cpp "$ROOT_DIR"/core/*.cpp "$ROOT_DIR"/pkg/*.cpp \
    -o "$ROOT_DIR/bin/agent"
cd "$ROOT_DIR"
echo "[RUN] ${ROOT_DIR}/bin/agent ${CFG}"
exec "${ROOT_DIR}/bin/agent" "$CFG"
