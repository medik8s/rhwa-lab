#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "die: $*"; exit 3; }
export WORKER_COUNT=3
export OCP_VERSION=4.18.0
export BIN_DIR=/tmp
export KUBECONFIG_LOCAL=/tmp/kubeconfig
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
source "${DIR}/../lib/openshift.sh"
# Stub oc AFTER sourcing openshift.sh (which defines its own oc wrapper)
oc(){
  printf '%s\n' "$*" >>"$OUT"
  case "$*" in
    *"get machineset"*) echo "t-abc-worker-0";;
    *"get nodes"*)      printf 'worker-0 Ready\nworker-1 Ready\nworker-2 Ready\n';;
  esac
}
os_provision_workers
grep -q 'scale machineset t-abc-worker-0 --replicas=3' "$OUT" || { echo "FAIL scale args"; exit 1; }
# After workers are Ready, the control plane is taken out of the schedulable pool
grep -q 'patch schedulers.config.openshift.io/cluster' "$OUT" || { echo "FAIL missing mastersSchedulable patch"; exit 1; }
grep -q '"mastersSchedulable":false' "$OUT" || { echo "FAIL mastersSchedulable not set false"; exit 1; }
echo "PASS"
