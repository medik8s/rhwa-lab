#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
log(){ :; }; ok(){ :; }; warn(){ :; }
export CLUSTER_NAME=t NET_CIDR=192.168.126.0/24 NET_GATEWAY=192.168.126.1 \
       SUSHY_PORT=8000 SUSHY_USER=admin SUSHY_PASS=password \
       CONTROL_PLANE_COUNT=3 WORKER_COUNT=3 SPARE_WORKER_COUNT=1 \
       CP_VCPU=8 CP_RAM_GB=20 WK_VCPU=4 WK_RAM_GB=16
source "${DIR}/../lib/common.sh"
state_get(){ echo "uuid-$RANDOM"; }   # every node has a uuid
# Capture oc apply payloads + patch args.
OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
oc(){ printf '%s\n' "$*" >>"$OUT"; cat >>"$OUT" 2>/dev/null || true;
      case "$*" in *"get baremetalhost worker-"*) return 1;; *"get baremetalhost master-"*) return 0;; esac; return 0; }
source "${DIR}/../lib/rhwa.sh"
rhwa_configure_bmh
# worker BMH created with vda hint and NOT externallyProvisioned
grep -q 'deviceName: /dev/vda' "$OUT" || { echo "FAIL vda hint"; exit 1; }
grep -q 'externallyProvisioned: true' "$OUT" && { echo "FAIL worker must not be externallyProvisioned"; exit 1; }
# spare worker gets a provisionable BMH too (available/unconsumed -> OCP-51155
# scale-up). Spares continue the worker numbering: with WORKER_COUNT=3 the first
# spare is worker-3 (no "-spare-" name prefix).
grep -q 'name: worker-3' "$OUT" || { echo "FAIL spare BMH not created"; exit 1; }
# existing master BMH is patched (merge), never recreated/reprovisioned
grep -q 'patch baremetalhost master-' "$OUT" || { echo "FAIL master must be patched when present"; exit 1; }

# spare function must be gone
declare -F rhwa_configure_spare_bmh && { echo "FAIL spare fn still defined"; exit 1; }

# --- master BMH absent: self-heal by creating an externallyProvisioned host ---
OUT2="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
oc(){ printf '%s\n' "$*" >>"$OUT2"; cat >>"$OUT2" 2>/dev/null || true;
      # every get baremetalhost misses -> exercise the create fallbacks
      case "$*" in *"get baremetalhost "*) return 1;; esac; return 0; }
rhwa_configure_bmh
# master fallback creates an externallyProvisioned BMH...
grep -q 'name: master-0' "$OUT2" || { echo "FAIL master BMH not created when absent"; exit 1; }
grep -q 'externallyProvisioned: true' "$OUT2" || { echo "FAIL absent master must be externallyProvisioned"; exit 1; }
# ...and must NEVER get bootMACAddress or rootDeviceHints (masters are not reprovisioned)
awk '/^kind: BareMetalHost$/{blk=""} {blk=blk"\n"$0}
     /^  name: master-/{ if (blk ~ /bootMACAddress/ || blk ~ /rootDeviceHints/) { print "HIT" } }' "$OUT2" \
  | grep -q HIT && { echo "FAIL master BMH must not set bootMACAddress/rootDeviceHints"; exit 1; }
echo "PASS"
