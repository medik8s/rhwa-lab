#!/usr/bin/env bash
# ODF_CHANNEL derivation from OCP_VERSION in lib/common.sh: must track the
# actual OCP minor for both channel-alias (stable-4.NN) and release-version
# (4.22.13, 5.0.0-rc.1, nightly) forms of OCP_VERSION.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

derive() {
  (
    unset ODF_CHANNEL
    export OCP_VERSION="$1"
    source "${DIR}/../lib/common.sh" >/dev/null 2>&1
    printf '%s' "${ODF_CHANNEL}"
  )
}

assert_eq() {
  [[ "$2" == "$3" ]] || { echo "FAIL: OCP_VERSION='$1' -> expected '$3', got '$2'"; exit 1; }
}

v=stable-4.22;                                 assert_eq "$v" "$(derive "$v")" "stable-4.22"
v=4.22.13;                                      assert_eq "$v" "$(derive "$v")" "stable-4.22"
v=5.0.0-rc.1;                                    assert_eq "$v" "$(derive "$v")" "stable-5.0"
v=5.0.0-0.nightly-2026-10-14-152123;             assert_eq "$v" "$(derive "$v")" "stable-5.0"
v=5.0.0-ec.5;                                     assert_eq "$v" "$(derive "$v")" "stable-5.0"

echo "PASS"
