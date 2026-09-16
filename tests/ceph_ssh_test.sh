#!/usr/bin/env bash
# _ssh_ceph must reach the VM the way that works by hand: ssh to the host and ssh
# to the VM FROM there, with the agent forwarded (-A) so a passphrase-protected
# key authenticates the inner hop -- NOT a -W/ProxyCommand tunnel (which this
# environment refuses). Inner hop must ignore host-key changes (reprovision).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t OCP_VERSION=stable-4.22 NET_CIDR=192.168.126.0/24 \
       SSH_PUBLIC_KEY_FILE=/tmp/nope.pub HOST_SSH_USER=fedora \
       CEPH_SSH_USER=cloud-user CEPH_IP=192.168.126.10
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/odf.sh"
host_ip(){ echo 203.0.113.9; }
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
ssh(){ printf '%s\n' "$*" >>"$OUT"; }   # capture the argv _ssh_ceph builds
_ssh_ceph "sudo bash -s" </dev/null

assert_contains     "$OUT" "-A "                            # agent forwarding
assert_contains     "$OUT" "fedora@203.0.113.9"             # outer hop: the EC2 host
assert_contains     "$OUT" "cloud-user@192.168.126.10"      # inner hop: the ceph VM
assert_contains     "$OUT" "sudo bash -s"                   # command carried through
assert_contains     "$OUT" "StrictHostKeyChecking=no"       # tolerate reprovisioned host key
assert_contains     "$OUT" "UserKnownHostsFile=/dev/null"
assert_not_contains "$OUT" "ProxyCommand"                   # not the -W tunnel
assert_not_contains "$OUT" "-W "
echo "PASS"
