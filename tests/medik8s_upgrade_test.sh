#!/usr/bin/env bash
# `medik8s-upgrade`: host prep (toolchain + kubectl->oc shim + kubeconfig push),
# clone of the medik8s-cli PoC, and the on-host upgrade.sh invocation -- namespace
# passthrough, container tool, kubeconfig, and --yes injection / --rollback-only.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
export RHWA_NAMESPACE=openshift-workload-availability CLUSTER_DIR="$tmp"
source "${DIR}/../lib/common.sh"
source "${DIR}/../lib/upgrade.sh"

# common.sh derives CLUSTER_DIR/KUBECONFIG_LOCAL; pin both to our temp and create a
# dummy kubeconfig so _medik8s_upgrade_prepare's check and scp_to have something.
CLUSTER_DIR="$tmp"; KUBECONFIG_LOCAL="$tmp/kubeconfig"; echo dummy >"$KUBECONFIG_LOCAL"
# Stub AFTER sourcing: silence logs, fail loudly on die.
log(){ :; }; ok(){ :; }; warn(){ :; }; die(){ echo "DIE: $*"; exit 1; }
# Capture every host-side script (prep + clone + run, via args and stdin) and scp.
HOST="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
ssh_host(){ printf 'SSH %s\n' "$*" >>"$HOST"; cat >>"$HOST" 2>/dev/null || true; }
scp_to(){ printf 'SCP %s -> %s\n' "$1" "$2" >>"$HOST"; }

# ---- forward migration (default) -------------------------------------------
medik8s_upgrade </dev/null

# Host prepped: toolchain + docker->podman shim, kubectl->oc shim, kubeconfig push.
assert_contains "$HOST" 'dnf install -y $pkgs'
assert_contains "$HOST" "podman-docker"
assert_contains "$HOST" 'ln -sf oc "$HOME/bin/kubectl"'
assert_contains "$HOST" "SCP ${tmp}/kubeconfig -> rhwa-dev.kubeconfig"
# PoC cloned from the default repo.
assert_contains "$HOST" "git clone --depth 1"
assert_contains "$HOST" "'https://github.com/medik8s/medik8s-cli'"
# upgrade.sh run on the host with the lab's namespace, podman, pushed kubeconfig.
assert_contains "$HOST" "WAO_BACKUP_NAMESPACE='openshift-workload-availability'"
assert_contains "$HOST" "WAO_INSTALL_NAMESPACE='openshift-workload-availability'"
assert_contains "$HOST" "CONTAINER_TOOL=podman"
assert_contains "$HOST" 'KUBECONFIG="$HOME/rhwa-dev.kubeconfig"'
# Non-interactive: --yes injected; forward run carries no --rollback-only.
assert_contains "$HOST" "./scripts/poc/upgrade.sh --yes"
assert_not_contains "$HOST" "--rollback-only"

# ---- rollback-only passes through, still non-interactive --------------------
: >"$HOST"
medik8s_upgrade --rollback-only </dev/null
assert_contains "$HOST" "upgrade.sh --rollback-only --yes"

# ---- explicit --yes is not duplicated --------------------------------------
: >"$HOST"
medik8s_upgrade --yes </dev/null
assert_not_contains "$HOST" "--yes --yes"

# ---- repo + ref overrides thread into the clone ----------------------------
: >"$HOST"
MEDIK8S_CLI_REPO=https://github.com/me/fork MEDIK8S_CLI_REF=my-branch \
  medik8s_upgrade </dev/null
assert_contains "$HOST" "--branch 'my-branch'"
assert_contains "$HOST" "'https://github.com/me/fork'"

echo PASS
