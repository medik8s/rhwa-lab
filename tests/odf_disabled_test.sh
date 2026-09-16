#!/usr/bin/env bash
# ODF_ENABLED=false makes the whole feature a no-op: no ceph VM, no oc calls.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export ODF_ENABLED=false CEPH_ENABLED=false
source "${DIR}/../lib/odf.sh"
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
ssh_host(){ printf 'ssh_host %s\n' "$*" >>"$OUT"; }
_ssh_ceph(){ printf 'ssh_ceph %s\n' "$*" >>"$OUT"; }
oc(){ printf 'oc %s\n' "$*" >>"$OUT"; }
odf_setup
[[ -s "$OUT" ]] && { echo "FAIL: odf_setup did work while ODF_ENABLED=false"; cat "$OUT"; exit 1; }
echo "PASS"
