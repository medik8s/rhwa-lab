#!/usr/bin/env bash
# upgrade.sh - migrate the lab's six individual medik8s operators (NHC, FAR, SNR,
# NMO, MDR, SBR) to the single Workload Availability Operator (WAO), using the
# medik8s-cli upgrade proof-of-concept (github.com/medik8s/medik8s-cli,
# scripts/poc/upgrade.sh). The PoC backs up every medik8s CR to a PVC, deletes
# the source operators (CRs -> operands -> OLM Subscription/CSV), then builds and
# installs WAO and restores the CRs as WAO operands; --rollback-only undoes it
# (remove WAO, reinstall the originals from the backup).
#
# The whole flow runs ON THE EC2 HOST, exactly like the lab's `make dev-olm-deploy`
# install path: the PoC's install-wao.sh clones the WAO repo and runs its Makefile
# (go/make + podman) to build operator/bundle/catalog images and push them to
# ttl.sh, from which the cluster then pulls -- so it needs the same build toolchain
# and cluster egress the host already provides. It talks to the cluster with
# `kubectl` (we add a kubectl->oc shim) against the lab's pushed kubeconfig.
#
# Runs non-interactively (passes --yes to the PoC's destructive delete/rollback
# steps): this lab targets disposable dev clusters, and the ssh invocation has no
# reliable TTY for the PoC's confirmation prompts.

# Canonical defaults + docs live in common.sh; repeated here so the lib is usable
# when sourced standalone (e.g. tests) under `set -u`.
_medik8s_upgrade_defaults() {
  : "${RHWA_NAMESPACE:=openshift-workload-availability}"
  : "${RHWA_DEV_KUBECONFIG:=rhwa-dev.kubeconfig}"
  : "${MEDIK8S_CLI_REPO:=https://github.com/medik8s/medik8s-cli}"
  : "${MEDIK8S_CLI_REF:=}"
  : "${MEDIK8S_CLI_DIR:=rhwa-medik8s-cli}"
}

# Prepare the host to run the PoC: the build toolchain (go/make/git/tar + the
# docker->podman shim the WAO Makefile expects), a kubectl->oc shim (the PoC calls
# `kubectl` directly; the host ships kubectl-compatible `oc` in ~/bin), and the
# lab's verified kubeconfig pushed to ~/${RHWA_DEV_KUBECONFIG} for the on-host run.
_medik8s_upgrade_prepare() {
  log "Preparing host for the medik8s->WAO upgrade PoC (go/make/git + docker->podman + kubectl shim + kubeconfig)"
  ssh_host "sudo bash -s" <<'EOS'
set -euo pipefail
pkgs=""
command -v go   >/dev/null 2>&1 || pkgs="$pkgs golang"
command -v make >/dev/null 2>&1 || pkgs="$pkgs make"
command -v git  >/dev/null 2>&1 || pkgs="$pkgs git"
command -v tar  >/dev/null 2>&1 || pkgs="$pkgs tar"
# WAO's Makefile (like the operators') hardcodes `docker`; podman-docker installs
# a /usr/bin/docker shim over podman so those targets work on the host.
command -v docker >/dev/null 2>&1 || pkgs="$pkgs podman-docker"
[ -n "$pkgs" ] && dnf install -y $pkgs >/dev/null
mkdir -p /etc/containers && touch /etc/containers/nodocker
EOS
  # kubectl->oc shim in ~/bin (where the host's oc lives). The PoC scripts invoke
  # `kubectl`; oc is a drop-in for the apply/wait/exec/get calls they make.
  ssh_host "bash -s" <<'EOS'
set -euo pipefail
export PATH="$HOME/bin:$PATH"
mkdir -p "$HOME/bin"
command -v kubectl >/dev/null 2>&1 || ln -sf oc "$HOME/bin/kubectl"
EOS
  [[ -s "$KUBECONFIG_LOCAL" ]] || die "no local kubeconfig at ${KUBECONFIG_LOCAL}; run create first"
  scp_to "$KUBECONFIG_LOCAL" "${RHWA_DEV_KUBECONFIG}"
}

# Clone (or refresh) the medik8s-cli PoC on the host. MEDIK8S_CLI_REF applies on a
# fresh clone; an existing checkout is reset and fast-forwarded.
_medik8s_upgrade_clone() {
  log "Cloning medik8s-cli (${MEDIK8S_CLI_REPO}${MEDIK8S_CLI_REF:+@${MEDIK8S_CLI_REF}}) to ~/${MEDIK8S_CLI_DIR} on host"
  ssh_host "bash -s" <<EOS
set -euo pipefail
d="\$HOME/${MEDIK8S_CLI_DIR}"
if [ -d "\$d/.git" ]; then
  git -C "\$d" checkout -- . 2>/dev/null || true
  git -C "\$d" pull --ff-only -q 2>/dev/null || true
else
  git clone --depth 1 ${MEDIK8S_CLI_REF:+--branch '${MEDIK8S_CLI_REF}'} '${MEDIK8S_CLI_REPO}' "\$d"
fi
chmod +x "\$d"/scripts/poc/*.sh 2>/dev/null || true
EOS
}

# The PoC backup PVC uses the cluster DEFAULT StorageClass; the lab's ODF external
# StorageClasses are not marked default. Warn (non-fatal) with the fix so the
# backup step doesn't fail on a Pending PVC.
_medik8s_upgrade_check_default_sc() {
  if ssh_host "bash -lc 'export PATH=\$HOME/bin:\$PATH; export KUBECONFIG=\$HOME/${RHWA_DEV_KUBECONFIG}; oc get sc'" 2>/dev/null \
       | grep -q '(default)'; then
    log "A default StorageClass is set (PoC backup PVC will bind)."
  else
    warn "No default StorageClass on the cluster; the PoC backup PVC needs one."
    warn "Set one first, e.g.:  oc patch sc <name> -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
  fi
}

# Run the medik8s-cli upgrade PoC on the host. Extra args (e.g. --rollback-only)
# pass straight through; --yes is injected once for non-interactive runs unless the
# caller already supplied it.
medik8s_upgrade() {
  _medik8s_upgrade_defaults
  local a yes=1
  for a in "$@"; do [[ "$a" == "--yes" || "$a" == "-y" ]] && yes=0; done
  local pocargs=("$@")
  (( yes )) && pocargs+=("--yes")

  _medik8s_upgrade_prepare
  _medik8s_upgrade_clone
  _medik8s_upgrade_check_default_sc

  mkdir -p "${CLUSTER_DIR}/upgrade"
  local logf="${CLUSTER_DIR}/upgrade/medik8s-upgrade-$(date +%Y%m%d-%H%M%S).log"
  log "Running medik8s->WAO upgrade PoC on host (builds+pushes WAO images to ttl.sh; slow) -> ${logf}"
  # --yes injected, so the PoC needs no stdin/TTY; run as a remote command (not a
  # stdin heredoc, which the PoC's own `read` prompts would otherwise consume) and
  # tee the combined output to a per-run log.
  local remote="export PATH=\"\$HOME/bin:\$PATH\"; \
export KUBECONFIG=\"\$HOME/${RHWA_DEV_KUBECONFIG}\"; \
export CONTAINER_TOOL=podman; \
export WAO_BACKUP_NAMESPACE='${RHWA_NAMESPACE}'; \
export WAO_INSTALL_NAMESPACE='${RHWA_NAMESPACE}'; \
cd \"\$HOME/${MEDIK8S_CLI_DIR}\" && ./scripts/poc/upgrade.sh ${pocargs[*]}"
  if ssh_host "$remote" 2>&1 | tee "$logf"; then
    ok "medik8s->WAO upgrade complete (see ${logf})"
  else
    die "medik8s->WAO upgrade failed; see ${logf}"
  fi
}
