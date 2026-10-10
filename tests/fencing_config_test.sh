#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
trap 'rm -f "$STUB_OUT"' EXIT
export CLUSTER_NAME=t CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=3
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/rhwa.sh"
log(){ :; }; ok(){ :; }
state_get(){ printf '%s\n' "$1"; }
oc(){ cat >>"$STUB_OUT"; }

rhwa_configure_fencing
for host in master-0 master-1 master-2 worker-0 worker-1 worker-2 worker-3 worker-4 worker-5; do
  assert_contains "$STUB_OUT" "\"${host}\": \"/redfish/v1/Systems/uuid_t-${host}\""
done

: >"$STUB_OUT"
SPARE_WORKER_COUNT=0 rhwa_configure_fencing
assert_contains "$STUB_OUT" '"worker-2": "/redfish/v1/Systems/uuid_t-worker-2"'
assert_not_contains "$STUB_OUT" '"worker-3"'
echo 'PASS fencing includes all worker hosts'
