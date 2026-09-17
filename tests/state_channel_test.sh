#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

# Arrange: fake state + config. common.sh defines host_ip()=`state_get eip`, so
# seed eip in the fake state and define the state stubs AFTER sourcing common.sh
# (otherwise common.sh's host_ip would shadow a stub and record "").
export CLUSTER_NAME=t HOST_SSH_USER=fedora
export SSH_PUBLIC_KEY_FILE=/tmp/somekey.pub          # private => /tmp/somekey
source "${DIR}/../lib/common.sh" 2>/dev/null || true  # defines host_ip + record_ssh_channel
# File-backed KV stub (no associative arrays -> runs on macOS's stock bash 3.2).
_ST="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"; echo 'eip=203.0.113.9' >"$_ST"
state_set(){ printf '%s=%s\n' "$1" "$2" >>"$_ST"; }
state_get(){ local l; l="$(grep "^$1=" "$_ST" 2>/dev/null | tail -1)"; echo "${l#*=}"; }
PRIV_KEY="${SSH_PUBLIC_KEY_FILE%.pub}"

record_ssh_channel

[[ "$(state_get host_ip)"      == "203.0.113.9" ]] || { echo "FAIL host_ip"; exit 1; }
[[ "$(state_get host_user)"    == "fedora"      ]] || { echo "FAIL host_user"; exit 1; }
[[ "$(state_get ssh_key_path)" == "/tmp/somekey" ]] || { echo "FAIL ssh_key_path (must not presume id_rsa)"; exit 1; }
echo "PASS"
