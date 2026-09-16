#!/usr/bin/env bash
# odf_ceph_export: fetch the rook exporter, run it INSIDE cephadm shell by piping
# over stdin (python3 -) -- NOT `cephadm shell --mount` (mis-parsed as "no
# container engine") -- with an explicit monitoring endpoint, and validate the
# JSON array it emits.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "DIE: $*"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
export CEPH_ENABLED=true CEPH_RBD_POOL=ocs-storagepool ODF_NAMESPACE=openshift-storage \
       CEPH_IP=192.168.126.10 CEPH_EXPORTER_URL=https://example.test/exporter.py \
       CLUSTER_DIR="$tmp"
source "${DIR}/../lib/odf.sh"
CAP="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
# Capture the remote script (stdin) to CAP; emit a valid JSON array on stdout so
# the function's jq validation passes (that stdout is redirected to the out file).
_ssh_ceph(){ cat >>"$CAP"; printf '%s' '[{"name":"rook-ceph-mon","kind":"Secret","data":{}}]'; }
odf_ceph_export

assert_contains     "$CAP" "curl -fsSL 'https://example.test/exporter.py'"
assert_contains     "$CAP" 'shell -- python3 -'
assert_contains     "$CAP" "--rbd-data-pool-name 'ocs-storagepool'"
assert_contains     "$CAP" "--monitoring-endpoint '192.168.126.10'"
assert_contains     "$CAP" "< /tmp/exporter.py"     # piped, not mounted
assert_not_contains "$CAP" "--mount"
# The captured JSON array landed in the state file.
jq -e 'length == 1' "${tmp}/ceph-external.json" >/dev/null || { echo "FAIL: JSON not captured"; exit 1; }
echo "PASS"
