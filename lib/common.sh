#!/usr/bin/env bash
# common.sh - shared config, defaults, logging, and helpers.
# Sourced by the rhwa-lab dispatcher and every lib/*.sh module.

# ---------------------------------------------------------------------------
# Defaults (override by exporting the variable before running rhwa-lab)
# ---------------------------------------------------------------------------
: "${CLUSTER_NAME:=rhwa-lab}"
: "${BASE_DOMAIN:=migration.redhat.com}"
: "${OCP_VERSION:=5.0.0-rc.1}"
: "${INSTANCE_TYPE:=m8i.12xlarge}"
: "${SSH_PUBLIC_KEY_FILE:=$HOME/.ssh/id_rsa.pub}"
: "${HOST_SSH_USER:=fedora}"          # default cloud user of the host AMI (Fedora)
: "${FEDORA_RELEASE:=44}"             # host AMI: Fedora Cloud Base release
: "${CONTROL_PLANE_COUNT:=3}"
: "${WORKER_COUNT:=3}"
# Spare worker VMs: defined + BMC-configured but NOT installed with the cluster
# (excluded from install/agent config, never booted during create). Each gets a
# provisionable, metal3-managed BareMetalHost (rootDeviceHints /dev/vda) left
# available/unconsumed so a post-install test can provision an extra node by
# scaling the MachineSet onto it. Set to 0 to disable.
: "${SPARE_WORKER_COUNT:=3}"

# Per-node sizing
: "${CP_VCPU:=8}"
: "${CP_RAM_GB:=20}"
: "${WK_VCPU:=4}"
: "${WK_RAM_GB:=16}"
: "${NODE_DISK_GB:=120}"

# Lab network (on the EC2 host's libvirt bridge)
: "${LIBVIRT_NET:=rhwa}"
: "${NET_CIDR:=192.168.126.0/24}"
: "${NET_GATEWAY:=192.168.126.1}"     # also the host's bridge IP + sushy endpoint
: "${API_VIP:=192.168.126.5}"
: "${INGRESS_VIP:=192.168.126.6}"
: "${SUSHY_PORT:=8000}"
: "${SUSHY_USER:=admin}"
: "${SUSHY_PASS:=password}"           # emulated-BMC creds (dev/test only)

# RHWA
: "${RHWA_NAMESPACE:=openshift-workload-availability}"
: "${RHWA_CHANNEL:=stable}"

# ---------------------------------------------------------------------------
# ODF (OpenShift Data Foundation) in EXTERNAL mode, backed by a single-host
# Ceph cluster running on its own libvirt VM with 3 extra disks (one OSD each).
# Set ODF_ENABLED=false to skip the whole feature (no ceph VM, no ODF operator).
# ---------------------------------------------------------------------------
: "${ODF_ENABLED:=true}"
: "${ODF_NAMESPACE:=openshift-storage}"
# ODF operator channel must track the cluster's OCP minor in the redhat-operators
# catalog. Derived from OCP_VERSION (stable-4.NN -> stable-4.NN) when unset.
if [[ "${OCP_VERSION}" =~ ^[a-z]+-([0-9]+\.[0-9]+)$ ]]; then
  _odf_minor="${BASH_REMATCH[1]}"
else
  _odf_minor="4.22"
fi
: "${ODF_CHANNEL:=stable-${_odf_minor}}"   # ITERATE: confirm this channel exists in the catalog for your OCP version

# External Ceph cluster (single VM, cephadm --single-host-defaults).
: "${CEPH_ENABLED:=${ODF_ENABLED}}"        # ceph VM follows ODF_ENABLED unless overridden
# Ceph release train. Drives BOTH the CentOS Storage SIG package that installs
# cephadm (centos-release-ceph-<release>, in extras-common) AND the container
# image the cluster runs -- so the cephadm binary and the running ceph are the
# SAME release. (The release-agnostic 'centos-release-ceph-umbrella' package
# hands you a *development* cephadm whose default image is a dev/tip ceph, whose
# 'ceph mgr dump' JSON is ahead of ODF's rook -> "cannot unmarshal ...
# mgr.map.standbys".) ITERATE: match to the ceph version your ODF release
# supports (reef, squid, ...).
: "${CEPH_RELEASE:=squid}"
case "${CEPH_RELEASE}" in
  pacific)  _ceph_img_tag=v16 ;;
  quincy)   _ceph_img_tag=v17 ;;
  reef)     _ceph_img_tag=v18 ;;
  squid)    _ceph_img_tag=v19 ;;
  tentacle) _ceph_img_tag=v20 ;;
  *)        _ceph_img_tag="" ;;   # unknown -> let the release-matched cephadm pick its default
esac
# Container image the cluster runs, derived from the release so it matches the
# cephadm binary. Override CEPH_IMAGE only for a mirror/air-gapped registry.
: "${CEPH_IMAGE:=${_ceph_img_tag:+quay.io/ceph/ceph:${_ceph_img_tag}}}"
: "${CEPH_CLOUD_IMAGE_URL:=https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2}"
: "${CEPH_SSH_USER:=cloud-user}"           # default user of the ceph VM's cloud image (CentOS Stream = cloud-user)
: "${CEPH_VCPU:=4}"
: "${CEPH_RAM_GB:=16}"
: "${CEPH_ROOT_DISK_GB:=40}"               # ceph VM OS disk
: "${CEPH_OSD_COUNT:=3}"                   # extra data disks == OSDs (one per disk)
: "${CEPH_POOL_REPLICA:=3}"                # replicated pool size; usable = raw / replica
: "${CEPH_POOL_USABLE_GB:=200}"            # target usable capacity of the RBD data pool
: "${CEPH_RBD_POOL:=ocs-storagepool}"      # RBD data pool ODF external consumes
# CephFS (filesystem) StorageClass. ON by default: odf_ceph_bootstrap creates a
# CephFS + MDS on the external Ceph and the exporter advertises it, so ODF also
# creates the 'ocs-external-storagecluster-cephfs' StorageClass (RWX-capable)
# alongside the RBD (block/RWO) one. Set CEPH_FS_ENABLED=false for RBD-only. The
# CephFS data pool shares the same OSDs as the RBD pool, so both draw from
# CEPH_POOL_USABLE_GB -- raise CEPH_OSD_DISK_GB if you'll lean on both.
: "${CEPH_FS_ENABLED:=true}"
: "${CEPH_FS_NAME:=ocs-storagefs}"         # CephFS volume name (=> its data/meta pools)
# External-details exporter (rook's create-external-cluster-resources.py). Run
# INSIDE cephadm shell (has ceph + rados/rbd bindings). ITERATE: pin/override if
# the upstream layout changes.
: "${CEPH_EXPORTER_URL:=https://raw.githubusercontent.com/rook/rook/master/deploy/examples/create-external-cluster-resources.py}"
# Per-OSD raw disk size to yield CEPH_POOL_USABLE_GB usable at CEPH_POOL_REPLICA
# across CEPH_OSD_COUNT OSDs, plus ~18% headroom for Ceph's full-ratio (~0.95)
# and BlueStore overhead so the pool's MAX AVAIL comfortably reaches the target.
#   usable = raw_per_osd * osd_count / replica  ->  raw_per_osd = usable*replica/osd_count
: "${CEPH_OSD_DISK_GB:=$(( CEPH_POOL_USABLE_GB * CEPH_POOL_REPLICA * 118 / (CEPH_OSD_COUNT * 100) ))}"

# Ceph node topology (a single VM on the same libvirt network as the cluster,
# reachable only from the EC2 host). Not part of compute_nodes/compute_spares:
# it is NOT an OpenShift node and never gets a BMH or takes part in the install.
# IPs: gateway .1, VIPs .5/.6, masters .11+, workers .21+ -> ceph takes .10.
# MAC uses role byte 03 (masters 01, workers 02) so it can't collide.
CEPH_HOST="ceph-0"
CEPH_NODE_NAME="${CLUSTER_NAME}-ceph-0"
CEPH_IP="${NET_CIDR%.*}.10"
CEPH_MAC="52:54:00:6a:03:00"

# EC2 root volume. With ODF enabled, add the ceph OSDs' raw footprint on top of
# the base so the host disk can actually hold a full 200 GB pool (the qcow2 OSD
# files are sparse, so this is headroom, not up-front usage).
if [[ "${ODF_ENABLED}" == "true" ]]; then
  _ec2_vol_default=$(( 1000 + CEPH_OSD_COUNT * CEPH_OSD_DISK_GB ))
else
  _ec2_vol_default=1000
fi
: "${EC2_VOLUME_SIZE_GB:=${_ec2_vol_default}}"
# Provision-time IOPS/throughput for the gp3 root volume, applied in the launch
# block-device-mapping. Defaults to 12,000 IOPS / 500 MiB/s -- above gp3's free
# 3,000/125 baseline -- to give the shared volume headroom for Ceph + etcd + the
# node VMs (baseline contention is what surfaces BlueStore slow ops). Set either
# to empty for the free baseline, or to any value within EC2_MAX_IOPS /
# EC2_MAX_THROUGHPUT (below). To change a RUNNING instance's volume instead, use
# `./rhwa-lab set-disk-perf`.
: "${EC2_VOLUME_IOPS:=12000}"
: "${EC2_VOLUME_THROUGHPUT:=500}"
# Upper bounds for provisioned IOPS/throughput, enforced at provision time and by
# `set-disk-perf`. Capped at the m8i.12xlarge instance EBS ceiling (60,000 IOPS /
# 1,875 MB/s ≈ 1,788 MiB/s), not gp3's per-volume max (80,000 / 2,000), since the
# instance can't use more than it delivers. Override if you change INSTANCE_TYPE
# or use EBS bandwidth weighting. (Lower bounds are gp3's baseline: 3,000 / 125.)
: "${EC2_MAX_IOPS:=60000}"
: "${EC2_MAX_THROUGHPUT:=1788}"

# Derived paths
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${LAB_ROOT}/state"
BIN_DIR="${LAB_ROOT}/bin"
CLUSTER_DIR="${STATE_DIR}/${CLUSTER_NAME}"
STATE_FILE="${STATE_DIR}/${CLUSTER_NAME}.state"
KUBECONFIG_LOCAL="${CLUSTER_DIR}/kubeconfig"

# SSH: we import the user's public key into EC2 and reuse the matching
# private key both for the host and for `core@<node>`.
PRIV_KEY="${SSH_PUBLIC_KEY_FILE%.pub}"

# AWS resource names
KEYPAIR_NAME="${CLUSTER_NAME}-key"
SG_NAME="${CLUSTER_NAME}-sg"
TAG="rhwa-lab:${CLUSTER_NAME}"

export AWS_PAGER=""   # never open a pager on aws output

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_ts() { date +%H:%M:%S; }
log()  { printf '\033[1;34m[%s] %s\033[0m\n' "$(_ts)" "$*" >&2; }
ok()   { printf '\033[1;32m[%s] ✓ %s\033[0m\n' "$(_ts)" "$*" >&2; }
warn() { printf '\033[1;33m[%s] ! %s\033[0m\n' "$(_ts)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ✗ %s\033[0m\n' "$(_ts)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Env validation (never echoes secret values)
# ---------------------------------------------------------------------------
require_env() {
  local missing=() v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then missing+=("$v"); fi
  done
  if (( ${#missing[@]} )); then
    die "Missing required environment variable(s): ${missing[*]}
Set them and re-run. See README.md for the full contract."
  fi
}

require_cmds() {
  local missing=() c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then die "Missing required command(s): ${missing[*]}"; fi
}

# retry <n> <sleep> -- <cmd...>
retry() {
  local n="$1" s="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local i=1
  until "$@"; do
    (( i >= n )) && return 1
    warn "attempt $i/$n failed; retrying in ${s}s: $*"
    sleep "$s"; ((i++))
  done
}

# ---------------------------------------------------------------------------
# SSH / SCP to the EC2 host (default user set by HOST_SSH_USER; Fedora = fedora)
# ---------------------------------------------------------------------------
_ssh_opts=(-i "$PRIV_KEY" -o StrictHostKeyChecking=no
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
           -o ConnectTimeout=15
           # Keepalives so long attached commands (e.g. `wait-for` streaming
           # through the quiet "Waiting for bootkube" window) aren't dropped as
           # idle by NAT/the server: probe every 30s, give up after ~5m silent.
           -o ServerAliveInterval=30 -o ServerAliveCountMax=10)

host_ip() { state_get eip; }

ssh_host() { ssh "${_ssh_opts[@]}" "${HOST_SSH_USER}@$(host_ip)" "$@"; }
scp_to()   { scp "${_ssh_opts[@]}" "$1" "${HOST_SSH_USER}@$(host_ip):$2"; }
scp_from() { scp "${_ssh_opts[@]}" "${HOST_SSH_USER}@$(host_ip):$1" "$2"; }

# SSH to a cluster node (core@<node-ip>) by jumping through the EC2 host; the
# node network (192.168.126.0/24) is only reachable from the host. Used by the
# progress monitor and credential recovery to read ground truth on a node.
# Uses ProxyCommand (not ProxyJump) so the SAME StrictHostKeyChecking=no /
# UserKnownHostsFile=/dev/null options apply to the *jump* host too — ProxyJump
# would only apply them to the final hop and prompt to accept the host key.
ssh_node() {
  local ip="$1"; shift
  local jump="ssh ${_ssh_opts[*]} -W %h:%p ${HOST_SSH_USER}@$(host_ip)"
  ssh "${_ssh_opts[@]}" -o "ProxyCommand=${jump}" "core@${ip}" "$@"
}

# Persist the values a test needs to reach the host's virsh/sushy out-of-band.
# The SSH key is whatever the operator configured (SSH_PUBLIC_KEY_FILE); never
# assume a default key name. Recorded so lib/power.sh and any exported test
# config look it up instead of guessing.
record_ssh_channel() {
  state_set host_ip      "$(host_ip)"
  state_set host_user    "${HOST_SSH_USER}"
  state_set ssh_key_path "${PRIV_KEY}"
}

# ---------------------------------------------------------------------------
# Node topology. Populates parallel arrays used across modules.
#   NODE_NAME NODE_ROLE NODE_IP NODE_MAC NODE_VCPU NODE_RAM
# Naming: <cluster>-master-<i> / <cluster>-worker-<i>. Hostname: master-<i>.
# IPs: masters .11+, workers .21+.  MAC: 52:54:00:6a:<role>:<idx>.
# ---------------------------------------------------------------------------
declare -a NODE_NAME NODE_HOST NODE_ROLE NODE_IP NODE_MAC NODE_VCPU NODE_RAM
compute_nodes() {
  NODE_NAME=(); NODE_HOST=(); NODE_ROLE=(); NODE_IP=(); NODE_MAC=(); NODE_VCPU=(); NODE_RAM=()
  local net3 i
  net3="${NET_CIDR%.*}"   # e.g. 192.168.126
  for ((i=0; i<CONTROL_PLANE_COUNT; i++)); do
    NODE_NAME+=("${CLUSTER_NAME}-master-${i}")
    NODE_HOST+=("master-${i}")
    NODE_ROLE+=("master")
    NODE_IP+=("${net3}.$((11+i))")
    NODE_MAC+=("$(printf '52:54:00:6a:01:%02x' "$i")")
    NODE_VCPU+=("$CP_VCPU"); NODE_RAM+=("$CP_RAM_GB")
  done
  for ((i=0; i<WORKER_COUNT; i++)); do
    NODE_NAME+=("${CLUSTER_NAME}-worker-${i}")
    NODE_HOST+=("worker-${i}")
    NODE_ROLE+=("worker")
    NODE_IP+=("${net3}.$((21+i))")
    NODE_MAC+=("$(printf '52:54:00:6a:02:%02x' "$i")")
    NODE_VCPU+=("$WK_VCPU"); NODE_RAM+=("$WK_RAM_GB")
  done
  RENDEZVOUS_IP="${NODE_IP[0]}"   # first master
}

# Spare worker topology (separate from compute_nodes so nothing that feeds the
# install — install-config replicas, agent-config hosts, FAR node-params,
# cluster-node BMHs — ever sees a spare). Names/IPs/MACs continue the worker
# sequence (worker-<WORKER_COUNT>, worker-<WORKER_COUNT+1>, ...) so spares are
# indistinguishable from installed workers except that they live in these arrays
# and are left as unconsumed available BMHs; the numbering can't collide with
# cluster nodes. "Spare" is a role in the topology, not a name prefix.
declare -a SPARE_NAME SPARE_HOST SPARE_ROLE SPARE_IP SPARE_MAC SPARE_VCPU SPARE_RAM
compute_spares() {
  SPARE_NAME=(); SPARE_HOST=(); SPARE_ROLE=(); SPARE_IP=(); SPARE_MAC=(); SPARE_VCPU=(); SPARE_RAM=()
  local net3 i idx
  net3="${NET_CIDR%.*}"
  for ((i=0; i<SPARE_WORKER_COUNT; i++)); do
    idx=$((WORKER_COUNT+i))   # continue after the installed workers
    SPARE_NAME+=("${CLUSTER_NAME}-worker-${idx}")
    SPARE_HOST+=("worker-${idx}")
    SPARE_ROLE+=("worker")
    SPARE_IP+=("${net3}.$((21+idx))")
    SPARE_MAC+=("$(printf '52:54:00:6a:02:%02x' "$idx")")
    SPARE_VCPU+=("$WK_VCPU"); SPARE_RAM+=("$WK_RAM_GB")
  done
}

# Fully-qualified endpoints
api_fqdn()   { echo "api.${CLUSTER_NAME}.${BASE_DOMAIN}"; }
apps_fqdn()  { echo "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"; }
console_url(){ echo "https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"; }
