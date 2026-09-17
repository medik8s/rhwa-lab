#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export RHWA_NAMESPACE=openshift-workload-availability RHWA_CHANNEL=stable
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
# Source rhwa.sh first to get the function
source "${DIR}/../lib/rhwa.sh"
# Then override with stubs to prevent actual oc/kubectl calls
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true; }
_wait_csv(){ printf 'wait_csv %s\n' "$1" >>"$OUT"; }
_wait_snr_config(){ :; }
rhwa_install_operators
assert_contains "$OUT" "name: machine-deletion-remediation"
assert_contains "$OUT" "wait_csv machine-deletion-remediation"
# existing operators still present (no regression)
assert_contains "$OUT" "name: node-healthcheck-operator"
assert_contains "$OUT" "name: self-node-remediation"
echo "PASS"
