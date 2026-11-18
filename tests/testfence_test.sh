#!/usr/bin/env bash
# Exercise fencing against live-node fixtures without touching a cluster.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/testfence.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-testfence.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "$STUB_OUT"' EXIT
log(){ echo "$*"; }; ok(){ echo "$*"; }; warn(){ echo "$*" >&2; }
die(){ echo "$*" >&2; exit 1; }
state_get(){ [[ "$1" == cluster_installed ]] && echo yes; }
os_local_oc(){ :; }
ssh_node(){ printf '%s\n' "$*" >>"$tmp/ssh"; touch "$tmp/stopped"; }
sleep(){ touch "$tmp/recovered"; }

# worker-0 is absent; worker-1 is unhealthy; worker-3 is a provisioned spare.
jq -n '{items: [
  {metadata:{name:"worker-1"},status:{conditions:[{type:"Ready",status:"False"}],addresses:[{type:"InternalIP",address:"192.168.126.22"}]}},
  {metadata:{name:"worker-3"},status:{conditions:[{type:"Ready",status:"True"}],addresses:[{type:"InternalIP",address:"192.168.126.24"}]}},
  {metadata:{name:"worker-4"},status:{conditions:[{type:"Ready",status:"True"}],addresses:[{type:"InternalIP",address:"192.168.126.25"}]}}
]}' >"$tmp/nodes"
oc(){
  printf '%s\n' "$*" >>"$STUB_OUT"
  case "$*" in
    'get nodes '*)
      if [[ "$scenario" == api-error ]]; then echo 'connection refused' >&2; return 1; fi
      case "$scenario" in
        no-ready) jq '.items |= map(.status.conditions[0].status = "False")' "$tmp/nodes" ;;
        no-ip) jq 'del(.items[].status.addresses)' "$tmp/nodes" ;;
        *) cat "$tmp/nodes" ;;
      esac ;;
    'get node '*)
      [[ "$3" == worker-3 ]] || { echo "Node $3 not found" >&2; return 1; }
      case "$*" in
        *bootID*) if [[ -f "$tmp/recovered" ]]; then echo boot-after; else echo boot-before; fi ;;
        *conditions*)
          if [[ -f "$tmp/stopped" && ! -f "$tmp/recovered" ]]; then echo False; else echo True; fi ;;
      esac ;;
    *'get fenceagentsremediationtemplate '*)
      if [[ "$scenario" == no-mapping ]]; then
        echo '{"spec":{"template":{"spec":{"nodeparameters":{}}}}}'
      else
        echo '{"spec":{"template":{"spec":{"nodeparameters":{"--systems-uri":{"worker-3":"/redfish/v1/Systems/uuid-worker-3"}}}}}}'
      fi ;;
    *'get fenceagentsremediation.fence-agents-remediation.medik8s.io -o json')
      if [[ -f "$tmp/stopped" ]]; then
        echo '{"items":[{"metadata":{"name":"worker-3-far","annotations":{"remediation.medik8s.io/node-name":"worker-3"}}}]}'
      else
        echo '{"items":[]}'
      fi ;;
    *) echo "Unexpected oc call: $*" >&2; return 1 ;;
  esac
}

scenario=success
(test_fence) >"$tmp/log" 2>&1 || { cat "$tmp/log"; echo 'FAIL: fencing a provisioned spare'; exit 1; }
assert_contains "$tmp/ssh" '192.168.126.24 sudo systemctl stop kubelet'
assert_contains "$tmp/log" 'SUCCESS: worker-3 was fenced'
assert_contains "$STUB_OUT" 'node-role.kubernetes.io/worker=,!node-role.kubernetes.io/control-plane'
assert_not_contains "$STUB_OUT" 'get node worker-0'

# Discovery/preflight errors must not stop kubelet or mask the API error.
for scenario in api-error no-ready no-ip no-mapping; do
  rm -f "$tmp/ssh" "$tmp/stopped" "$tmp/recovered"
  rc=0
  (test_fence) >"$tmp/log" 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "FAIL: accepted $scenario"; exit 1; }
  [[ ! -f "$tmp/ssh" ]] || { echo "FAIL: stopped kubelet after $scenario"; exit 1; }
  case "$scenario" in
    api-error) assert_contains "$tmp/log" 'connection refused' ;;
    no-ready) assert_contains "$tmp/log" 'No Ready worker node' ;;
    no-ip) assert_contains "$tmp/log" 'InternalIP' ;;
    no-mapping) assert_contains "$tmp/log" 'No fencing systems URI for worker-3' ;;
  esac
done
echo 'PASS fencing live worker selection'
