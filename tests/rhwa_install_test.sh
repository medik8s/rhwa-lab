#!/usr/bin/env bash
# RHWA operator install dispatch: 'make' deploys each supported operator from
# source on the host via its own tools/dev.mk `make dev-olm-deploy` (clone +
# operator-sdk run bundle into RHWA_NAMESPACE); operators without that flow
# (machine-deletion-remediation) fall back to an OLM Subscription. A global
# catalog override puts everyone back on OLM.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
export RHWA_NAMESPACE=openshift-workload-availability RHWA_CHANNEL=stable \
       CLUSTER_DIR="$tmp" \
       RHWA_OPERATORS="node-healthcheck-operator machine-deletion-remediation"
source "${DIR}/../lib/common.sh"   # defaults (RHWA_INSTALL_METHOD=make, etc.)
source "${DIR}/../lib/rhwa.sh"

# common.sh DERIVES CLUSTER_DIR (state/<cluster>) and KUBECONFIG_LOCAL from it;
# pin both to our temp and create a dummy kubeconfig so _dev_olm_prepare's check
# and scp_to have something to push.
CLUSTER_DIR="$tmp"; KUBECONFIG_LOCAL="$tmp/kubeconfig"; echo dummy >"$KUBECONFIG_LOCAL"
# Stub AFTER sourcing (common.sh/rhwa.sh define these): silence logs and don't
# actually poll the cluster for readiness.
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "DIE: $*"; exit 1; }
_wait_csv(){ :; }; _wait_snr_config(){ :; }; sleep(){ :; }
# Capture every host-side script (dev-olm + prep), every scp, and every oc apply.
HOST="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
OC="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
ssh_host(){ printf 'SSH %s\n' "$*" >>"$HOST"; cat >>"$HOST" 2>/dev/null || true; }
scp_to(){ printf 'SCP %s -> %s\n' "$1" "$2" >>"$HOST"; }
# Reads used by _ensure_olm_auto_approve get canned answers; `oc image info`
# resolves a digest (NHC related images); everything else is an apply/patch we capture.
oc(){ case "$*" in
        *"image info"*)                 echo "Digest: sha256:$(printf '%064d' 0)"; return 0;;
        *"get subscription -o name"*)   echo "subscription.operators.coreos.com/far-v0-0-1-sub"; return 0;;
        *"get installplan -o name"*)    echo "installplan/install-abc"; return 0;;
        *"jsonpath={.spec.approved}"*)  echo "false"; return 0;;
      esac; printf 'OC %s\n' "$*" >>"$OC"; cat >>"$OC" 2>/dev/null || true; }

# ---- default (make) : NHC via dev-olm-deploy, MDR via catalog ---------------
rhwa_install_operators

# Host is prepped once: toolchain + docker->podman shim installed, tools cloned +
# run-bundle timeout patched, kubeconfig pushed.
assert_contains "$HOST" 'dnf install -y $pkgs'
assert_contains "$HOST" "podman-docker"
assert_contains "$HOST" "git clone --depth 1 https://github.com/medik8s/tools"
assert_contains "$HOST" "--timeout=10m"
assert_contains "$HOST" "SCP ${tmp}/kubeconfig -> rhwa-dev.kubeconfig"
# NHC is cloned and deployed from source via its own dev-olm-deploy target.
assert_contains "$HOST" "git clone --depth 1"
assert_contains "$HOST" "https://github.com/medik8s/node-healthcheck-operator"
assert_contains "$HOST" "make dev-olm-deploy"
assert_contains "$HOST" "SKIP_KIND=true"
assert_contains "$HOST" "KUBECTL=oc"
assert_contains "$HOST" "DEV_OLM_OPERATOR_NAMESPACE='openshift-workload-availability'"
assert_contains "$HOST" 'KUBECONFIG="$HOME/rhwa-dev.kubeconfig"'
# Force podman (some operator Makefiles default CONTAINER_TOOL=docker, absent on host).
assert_contains "$HOST" "CONTAINER_TOOL=podman"
# Point at the pre-patched tools repo (longer run-bundle timeout; no re-download).
assert_contains "$HOST" 'TOOLS_DIR="$HOME/rhwa-tools"'
# On failure, capture pod diagnostics BEFORE undeploy (cleanup deletes the pods),
# then undeploy so the catalog fallback doesn't stack a 2nd subscription.
assert_contains "$HOST" "diagnostics before cleanup"
assert_contains "$HOST" "get events --sort-by=.lastTimestamp"
assert_contains "$HOST" "make dev-olm-undeploy"
# NHC's related images are auto-resolved to digests (no manual _DEV_ENV needed).
assert_contains "$HOST" "CONSOLE_PLUGIN_IMAGE=quay.io/medik8s/node-remediation-console@sha256:"
assert_contains "$HOST" "MUST_GATHER_IMAGE=quay.io/medik8s/must-gather@sha256:"
# No leftovers from the old kustomize-render approach.
assert_not_contains "$HOST" "kustomize"
assert_not_contains "$HOST" "podman run"
# MDR has no make flow -> not cloned; subscribed via OLM instead.
assert_not_contains "$HOST" "machine-deletion-remediation"
# Namespace + AllNamespaces OperatorGroup created; MDR is a Subscription.
assert_contains "$OC" "kind: OperatorGroup"
assert_contains "$OC" "kind: Subscription"
assert_contains "$OC" "name: machine-deletion-remediation"
# operator-sdk leaves Manual subscriptions: flip them Automatic + approve plans,
# else MDR/FAR sit on unapproved install plans and never roll out.
assert_contains "$OC" 'patch subscription.operators.coreos.com/far-v0-0-1-sub'
assert_contains "$OC" '"installPlanApproval":"Automatic"'
assert_contains "$OC" 'patch installplan/install-abc'
assert_contains "$OC" '"approved":true'

# ---- per-operator override : point NHC at a branch + pass extra dev env -----
: >"$HOST"; : >"$OC"
NODE_HEALTHCHECK_OPERATOR_REF=my-pr \
  NODE_HEALTHCHECK_OPERATOR_DEV_ENV="CONSOLE_PLUGIN_IMAGE=x@sha256:aa MUST_GATHER_IMAGE=y@sha256:bb" \
  rhwa_install_operators
assert_contains "$HOST" "--branch 'my-pr'"
assert_contains "$HOST" "CONSOLE_PLUGIN_IMAGE=x@sha256:aa MUST_GATHER_IMAGE=y@sha256:bb"

# ---- registry + version overrides are threaded into the make command --------
: >"$HOST"; : >"$OC"
RHWA_DEV_REGISTRY=ttl.sh RHWA_DEV_VERSION=0.0.1 rhwa_install_operators
assert_contains "$HOST" "DEV_REGISTRY='ttl.sh'"
assert_contains "$HOST" "VERSION='0.0.1'"

# ---- storage-based-remediation defaults to make (dev-olm-deploy) ------------
: >"$HOST"; : >"$OC"
RHWA_OPERATORS="storage-based-remediation" rhwa_install_operators
assert_contains "$HOST" "https://github.com/medik8s/storage-based-remediation"
assert_contains "$HOST" "make dev-olm-deploy"
# ...and is overridable to catalog like any other operator.
: >"$HOST"; : >"$OC"
STORAGE_BASED_REMEDIATION_INSTALL_METHOD=catalog RHWA_OPERATORS="storage-based-remediation" rhwa_install_operators
assert_not_contains "$HOST" "storage-based-remediation"   # not cloned/built
assert_contains     "$OC"   "name: storage-based-remediation"

# ---- per-operator override : force NHC to catalog ---------------------------
: >"$HOST"; : >"$OC"
NODE_HEALTHCHECK_OPERATOR_INSTALL_METHOD=catalog rhwa_install_operators
assert_not_contains "$HOST" "dev-olm-deploy"           # NHC not built from source
assert_contains     "$OC"   "name: node-healthcheck-operator"

# ---- global catalog : nobody uses make, no host prep at all -----------------
: >"$HOST"; : >"$OC"
RHWA_INSTALL_METHOD=catalog rhwa_install_operators
assert_not_contains "$HOST" "dev-olm-deploy"
assert_not_contains "$HOST" "dnf install"
assert_contains     "$OC" "name: node-healthcheck-operator"
assert_contains     "$OC" "name: machine-deletion-remediation"

echo "PASS"
