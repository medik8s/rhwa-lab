#!/usr/bin/env bash
# External-details import for ODF external mode:
#  - NORMALIZE: the rook exporter emits StorageClass secret refs as bare
#    '*-secret-name' with no namespace; ocs-operator then generates an invalid SC
#    (node-publish/controller-modify name without namespace) and no RBD PVC can
#    provision. The import must add a matching '*-secret-namespace' for every
#    '*-secret-name'.
#  - Apply BOTH the individual rook-ceph-* objects AND the single
#    rook-ceph-external-cluster-details blob secret (base64 of the JSON).
#  - Create the StorageCluster in external mode.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "DIE: $*"; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
export CEPH_ENABLED=true ODF_NAMESPACE=openshift-storage CLUSTER_DIR="$tmp"
cat >"$tmp/ceph-external.json" <<'JSON'
[
 {"name":"rook-ceph-mon-endpoints","kind":"ConfigMap","data":{"data":"a=192.168.126.10:6789"}},
 {"name":"rook-ceph-mon","kind":"Secret","data":{"fsid":"abc-123","mon-secret":"m"}},
 {"name":"ceph-rbd","kind":"StorageClass","data":{"pool":"ocs-storagepool","csi.storage.k8s.io/provisioner-secret-name":"rook-csi-rbd-provisioner","csi.storage.k8s.io/node-publish-secret-name":"rook-csi-rbd-node","csi.storage.k8s.io/controller-modify-secret-name":"rook-csi-rbd-provisioner"}}
]
JSON
source "${DIR}/../lib/odf.sh"
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true;
      case "$*" in *"get storagecluster"*) echo Ready;; esac; }

odf_import_external
# (a) individual objects (mon-endpoints ConfigMap essential; StorageClass NOT an object)
assert_contains     "$OUT" '"name": "rook-ceph-mon-endpoints"'
assert_contains     "$OUT" '"name": "rook-ceph-mon"'
assert_not_contains "$OUT" '"kind": "StorageClass"'
# (b) the blob secret
assert_contains "$OUT" "name: rook-ceph-external-cluster-details"

# The blob must carry NORMALIZED StorageClass secrets: every *-secret-name has a
# matching *-secret-namespace (this is the fix for the un-provisionable PVC).
B64="$(grep 'external_cluster_details:' "$OUT" | awk '{print $2}')"
DEC="$(printf '%s' "$B64" | base64 -d)"
check(){ printf '%s' "$DEC" | jq -e ".[]|select(.kind==\"StorageClass\")|.data[\"$1\"]==\"openshift-storage\"" >/dev/null \
         || { echo "FAIL: $1 not normalized to openshift-storage"; exit 1; }; }
check "csi.storage.k8s.io/provisioner-secret-namespace"
check "csi.storage.k8s.io/node-publish-secret-namespace"
check "csi.storage.k8s.io/controller-modify-secret-namespace"

: >"$OUT"
odf_create_storagecluster
assert_contains "$OUT" "kind: StorageCluster"
assert_contains "$OUT" "name: ocs-external-storagecluster"
assert_contains "$OUT" "enable: true"
echo "PASS"
