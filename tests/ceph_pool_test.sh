#!/usr/bin/env bash
# Ceph bootstrap: single-host defaults (so replica-N places copies across this
# one host's OSDs), one OSD per data disk, and a replicated RBD pool sized to
# the configured replica so usable = raw/replica reaches the target.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CEPH_ENABLED=true CEPH_RELEASE=squid CEPH_IMAGE=quay.io/ceph/ceph:v19 \
       CEPH_IP=192.168.126.10 CEPH_HOST=ceph-0 CEPH_SSH_USER=cloud-user \
       CEPH_OSD_COUNT=3 CEPH_POOL_REPLICA=3 CEPH_POOL_USABLE_GB=200 \
       CEPH_RBD_POOL=ocs-storagepool
source "${DIR}/../lib/odf.sh"
# Don't touch real state; capture what would run on the ceph VM.
state_get(){ echo ""; }   # not yet bootstrapped
state_set(){ :; }
_ceph_wait_ssh(){ :; }
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
_ssh_ceph(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true; }
odf_ceph_bootstrap

# Prereqs are installed over SSH (with retries), not left to cloud-init.
assert_contains "$OUT" "dnf install -y podman lvm2 chrony python3 jq"
assert_contains "$OUT" "systemctl enable --now chronyd"
# cephadm from the CentOS Storage SIG RELEASE-SPECIFIC package (matches the ceph
# container image), invoked by absolute path via command -v -- not the umbrella
# (dev cephadm) and not a bare 'cephadm' PATH may miss.
assert_contains     "$OUT" "centos-release-ceph-squid"
assert_not_contains "$OUT" "centos-release-ceph-umbrella"
assert_contains     "$OUT" "dnf install -y cephadm"
assert_contains     "$OUT" 'command -v cephadm'
assert_not_contains "$OUT" "download.ceph.com"   # no curl'd standalone fallback
assert_contains     "$OUT" "bootstrap"
assert_contains "$OUT" "--single-host-defaults"
# cloud-init gives the VM an FQDN hostname; cephadm rejects that without this.
assert_contains "$OUT" "--allow-fqdn-hostname"
assert_contains "$OUT" "--mon-ip '192.168.126.10'"
# Pinned STABLE ceph image (cephadm's default could be a dev/tip build whose mgr
# dump ODF's rook can't parse).
assert_contains "$OUT" "--image 'quay.io/ceph/ceph:v19'"
# One OSD per blank data disk, via --all-available-devices (no hostname:device
# coupling; the 3 blank virtio disks are the only available devices).
assert_contains "$OUT" "orch apply osd --all-available-devices"
# Replicated pool sized so usable = raw/replica (replica 3).
assert_contains "$OUT" "osd pool create 'ocs-storagepool'"
assert_contains "$OUT" "osd pool set 'ocs-storagepool' size 3"
assert_contains "$OUT" "osd pool set 'ocs-storagepool' min_size 2"
assert_contains "$OUT" "osd pool application enable 'ocs-storagepool' rbd"
assert_contains "$OUT" "rbd pool init 'ocs-storagepool'"
# ODF external monitoring endpoint needs the mgr prometheus module.
assert_contains "$OUT" "mgr module enable prometheus"
# CRITICAL: cephadm shell stdin redirected from /dev/null, else it swallows this
# script (fed to bash -s over stdin) and pool creation silently never runs.
assert_contains "$OUT" 'shell -- "$@" </dev/null'
assert_contains "$OUT" "ceph -s </dev/null"
# Convergent + VERIFIED: pool existence and OSD count are checked and fatal, so a
# silent pool-create failure can never print a false "Ceph up".
assert_contains "$OUT" "osd pool ls"
assert_contains "$OUT" "ERROR: RBD pool 'ocs-storagepool' could not be created"
assert_contains "$OUT" "OSDs are up"
# The cephadm bootstrap itself is still gated on ceph not already running.
assert_contains "$OUT" 'shell -- ceph -s'
echo "PASS"
