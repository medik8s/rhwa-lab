#!/usr/bin/env bash
# Ceph SSH must use the configured local key for both hops without requiring
# an agent, and tolerate changed host keys after reprovisioning.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t OCP_VERSION=stable-4.22 NET_CIDR=192.168.126.0/24 \
       SSH_PUBLIC_KEY_FILE="/tmp/ceph key.pub" HOST_SSH_USER=fedora \
       CEPH_SSH_USER=cloud-user CEPH_IP=192.168.126.10
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/odf.sh"
host_ip(){ echo 203.0.113.9; }
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
STDIN="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
unset SSH_AUTH_SOCK
ssh(){ SSH_ARGS=("$@"); printf '%s\n' "$*" >>"$OUT"; cat >"$STDIN"; }
_ssh_ceph "sudo bash -s" <<'EOS'
echo bootstrap
EOS

assert_contains     "$OUT" "fedora@203.0.113.9"
assert_contains     "$OUT" "cloud-user@192.168.126.10"
assert_contains     "$OUT" "sudo bash -s"
assert_contains     "$OUT" "StrictHostKeyChecking=no"
assert_contains     "$OUT" "UserKnownHostsFile=/dev/null"
assert_contains     "$OUT" "ProxyCommand="
assert_not_contains "$OUT" "-A "
assert_contains     "$STDIN" "echo bootstrap"
[[ "${SSH_ARGS[0]}" == "-i" && "${SSH_ARGS[1]}" == "/tmp/ceph key" ]]

# Execute the proxy command against the stub to verify its shell quoting, too.
proxy=""
for arg in "${SSH_ARGS[@]}"; do
  case "$arg" in ProxyCommand=*) proxy="${arg#ProxyCommand=}";; esac
done
[[ -n "$proxy" ]]
: >"$OUT"
eval "$proxy" </dev/null
[[ "${SSH_ARGS[0]}" == "-i" && "${SSH_ARGS[1]}" == "/tmp/ceph key" ]]
assert_contains "$OUT" "-W %h:%p fedora@203.0.113.9"
assert_contains "$OUT" "StrictHostKeyChecking=no"
assert_contains "$OUT" "UserKnownHostsFile=/dev/null"

# A timeout must expose the SSH error rather than only the VM's network state.
if (
  _ssh_ceph(){ echo "Permission denied (publickey)." >&2; return 255; }
  ssh_host(){ echo "domstate: running"; }
  sleep(){ :; }
  warn(){ :; }
  _ceph_wait_ssh
) >"$OUT" 2>&1; then
  echo "FAIL: readiness succeeded despite SSH authentication failure"
  exit 1
fi
assert_contains "$OUT" "Permission denied (publickey)."
assert_contains "$OUT" "domstate: running"
assert_contains "$OUT" "did not become reachable over SSH"

# A VM that becomes reachable on the diagnostic attempt still counts as ready.
(
  attempts=0
  _ssh_ceph(){ attempts=$((attempts + 1)); [[ "$attempts" -eq 61 ]]; }
  ssh_host(){ echo "FAIL: diagnostics ran after SSH succeeded"; exit 1; }
  sleep(){ :; }
  warn(){ :; }; ok(){ :; }
  _ceph_wait_ssh
)
echo "PASS"
