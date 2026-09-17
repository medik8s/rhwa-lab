#!/usr/bin/env bash
# The external-Ceph VM is defined with a COW root off a cached base image plus
# one blank virtio data disk PER OSD at the derived size, and a NoCloud seed ISO
# (built by us, not virt-install's transient one) injects the operator's SSH key
# + host packages. It must NOT be an OpenShift node.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
# A readable public key file (odf_ceph_define_vm reads it to inject via cloud-init).
KEY="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"; echo "ssh-ed25519 AAAATESTKEY ceph-test" >"$KEY"
export CLUSTER_NAME=t BASE_DOMAIN=example.com OCP_VERSION=stable-4.22 \
       NET_CIDR=192.168.126.0/24 LIBVIRT_NET=rhwa SSH_PUBLIC_KEY_FILE="$KEY" \
       CEPH_OSD_COUNT=3 CEPH_OSD_DISK_GB=236 CEPH_ROOT_DISK_GB=40 \
       CEPH_VCPU=4 CEPH_RAM_GB=16
source "${DIR}/../lib/common.sh"
CLUSTER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")/t"   # seed inputs are rendered under CLUSTER_DIR/ceph
source "${DIR}/../lib/odf.sh"
state_get(){ echo ""; }   # ceph not yet bootstrapped -> (re)create path
stub_ssh_host
host_ip(){ echo x; }
scp_to(){ :; }   # seed files are shipped to the host; no-op in the test
odf_ceph_define_vm

# 3 blank OSD data disks at the derived size, one per device (vdb/vdc/vdd).
assert_contains "$STUB_OUT" "t-ceph-0-vdb.qcow2"
assert_contains "$STUB_OUT" "t-ceph-0-vdc.qcow2"
assert_contains "$STUB_OUT" "t-ceph-0-vdd.qcow2"
assert_contains "$STUB_OUT" "236G"
# COW root off a cached base image (not a full copy).
assert_contains "$STUB_OUT" "-b '/var/lib/libvirt/images/ceph-base.qcow2'"
# Our own persistent NoCloud seed ISO (cidata), attached as a cdrom.
assert_contains "$STUB_OUT" "genisoimage"
assert_contains "$STUB_OUT" "-volid cidata"
assert_contains "$STUB_OUT" "t-ceph-0-seed.iso',device=cdrom"
# NOT virt-install's transient cloud-init (the bug we're avoiding).
assert_not_contains "$STUB_OUT" "--cloud-init"
# rhwa network with the pinned MAC.
assert_contains "$STUB_OUT" "52:54:00:6a:03:00"
assert_contains "$STUB_OUT" "network=rhwa"
# It is NOT an OpenShift node: no agent ISO, no BMH/BMC wiring here.
assert_not_contains "$STUB_OUT" "agent.iso"
assert_not_contains "$STUB_OUT" "redfish"

# The seed's user-data carries our SSH key + hostname. Packages are NOT here --
# they're installed by odf_ceph_bootstrap over SSH (see ceph_pool_test).
UD="${CLUSTER_DIR}/ceph/user-data"
assert_contains     "$UD" "ssh-ed25519 AAAATESTKEY ceph-test"
assert_contains     "$UD" "hostname: ceph-0"
assert_not_contains "$UD" "packages:"
# The seed pins a STATIC IP (matched by MAC) rather than trusting a DHCP
# reservation, so the VM lands on CEPH_IP regardless of the libvirt net state.
NC="${CLUSTER_DIR}/ceph/network-config"
assert_contains "$NC" "192.168.126.10/24"
assert_contains "$NC" "52:54:00:6a:03:00"
assert_contains "$NC" "dhcp4: false"
# ...and network-config is baked into the seed ISO.
assert_contains "$STUB_OUT" "network-config"

# Non-destructive re-run: an already up + reachable VM is left untouched
# (no rebuild), regardless of the bootstrap marker.
: >"$STUB_OUT"
ssh_host(){ printf '%s\n' "$*" >>"$STUB_OUT"; case "$*" in *"virsh domstate"*) echo running;; esac; }
_ssh_ceph(){ return 0; }   # reachable at CEPH_IP
odf_ceph_define_vm
assert_not_contains "$STUB_OUT" "virt-install"
assert_not_contains "$STUB_OUT" "virsh destroy"
assert_not_contains "$STUB_OUT" "genisoimage"

# CEPH_ENABLED=false is a no-op (nothing emitted).
: >"$STUB_OUT"
CEPH_ENABLED=false odf_ceph_define_vm
[[ -s "$STUB_OUT" ]] && { echo "FAIL: define ran with CEPH_ENABLED=false"; exit 1; }
echo "PASS"
