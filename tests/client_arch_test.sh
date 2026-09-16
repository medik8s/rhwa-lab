#!/usr/bin/env bash
# The LOCAL oc must match the operator's OS/arch (a Linux binary won't run on
# macOS). _oc_client_tarball picks the right client tarball from uname.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OCP_VERSION=stable-4.22
source "${DIR}/../lib/openshift.sh"

# Stub uname to drive each scenario via env.
uname(){ case "$1" in -s) echo "$_S" ;; -m) echo "$_M" ;; esac; }
want(){ [[ "$(_oc_client_tarball)" == "$1" ]] || { echo "FAIL: S=$_S M=$_M -> $(_oc_client_tarball), want $1"; exit 1; }; }

_S=Linux  _M=x86_64  ; want openshift-client-linux.tar.gz       # unchanged on Linux
_S=Darwin _M=arm64   ; want openshift-client-mac-arm64.tar.gz   # Apple Silicon
_S=Darwin _M=aarch64 ; want openshift-client-mac-arm64.tar.gz
_S=Darwin _M=x86_64  ; want openshift-client-mac.tar.gz         # Intel Mac
echo "PASS"
