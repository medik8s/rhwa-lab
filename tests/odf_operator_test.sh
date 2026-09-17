#!/usr/bin/env bash
# ODF operator install: openshift-storage namespace + OperatorGroup + odf-operator
# Subscription on the configured channel from the Red Hat catalog.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export ODF_NAMESPACE=openshift-storage ODF_CHANNEL=stable-4.22
source "${DIR}/../lib/odf.sh"
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true; }
_odf_wait_csv(){ printf 'wait_csv %s\n' "$1" >>"$OUT"; }
odf_install_operator

assert_contains "$OUT" "name: ${ODF_NAMESPACE}"
assert_contains "$OUT" 'openshift.io/cluster-monitoring: "true"'
assert_contains "$OUT" "name: odf-operator"
assert_contains "$OUT" "channel: stable-4.22"
assert_contains "$OUT" "source: redhat-operators"
assert_contains "$OUT" "wait_csv odf-operator"
assert_contains "$OUT" "wait_csv ocs-operator"
echo "PASS"
