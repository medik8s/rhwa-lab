#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       CONTROL_PLANE_COUNT=1 WORKER_COUNT=1 SPARE_WORKER_COUNT=0 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
# case-based stub (no associative arrays -> runs on macOS's stock bash 3.2).
state_get(){ case "$1" in
  host_ip)          echo 203.0.113.9 ;;
  host_user)        echo fedora ;;
  ssh_key_path)     echo /tmp/opkey ;;
  uuid_t-master-0)  echo uu-m ;;
  uuid_t-worker-0)  echo uu-w ;;
  *)                echo "" ;;
esac; }
source "${DIR}/../lib/power.sh"
json="$(emit_vms_definitions)"
echo "$json" | jq -e '.host.ssh_key_path=="/tmp/opkey"' >/dev/null || { echo "FAIL key path (no presumed default)"; exit 1; }
echo "$json" | jq -e '.host.ip=="203.0.113.9"' >/dev/null || { echo "FAIL host ip"; exit 1; }
echo "$json" | jq -e '[.nodes[].domain]|index("t-master-0")' >/dev/null || { echo "FAIL domain"; exit 1; }
echo "$json" | jq -e '.nodes[]|select(.host=="worker-0").uuid=="uu-w"' >/dev/null || { echo "FAIL uuid"; exit 1; }
echo "PASS"
