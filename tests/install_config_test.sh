#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
export CLUSTER_NAME=t BASE_DOMAIN=example.com OCP_VERSION=stable-4.22 \
       NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       API_VIP=192.168.126.5 INGRESS_VIP=192.168.126.6 \
       CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16 \
       SSH_PUBLIC_KEY_FILE=/nonexistent.pub
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/openshift.sh"
out="$(_emit_install_config '{"auths":{}}' 'ssh-ed25519 AAAA test')"
echo "$out" | grep -A2 '^compute:' | grep -q 'replicas: 0' || { echo "FAIL compute replicas"; exit 1; }
echo "$out" | grep -q 'replicas: 3' || { echo "FAIL controlPlane replicas"; exit 1; }  # masters unchanged
echo "PASS"
# Render agent-config via os_render_configs into a temp CLUSTER_DIR and assert masters-only.
export PULL_SECRET='{"auths":{}}'
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"; export STATE_DIR="$tmp" CLUSTER_DIR="$tmp/t"
scp_to(){ :; }   # not used here
os_render_configs
grep -q 'hostname: master-0' "$tmp/t/install/agent-config.yaml" || { echo "FAIL master missing"; exit 1; }
grep -q 'hostname: worker-'  "$tmp/t/install/agent-config.yaml" && { echo "FAIL worker present in agent-config"; exit 1; }
echo "PASS agent-config"
