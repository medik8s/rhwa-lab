#!/usr/bin/env bash
# rhwa.sh - install RHWA operators (Node Health Check, Fence Agents
# Remediation, Self Node Remediation, Node Maintenance, Machine Deletion
# Remediation, Storage Based Remediation), then wire fence_redfish against the
# sushy-tools emulated BMCs.
#
# Each operator installs by its resolved method (see RHWA_INSTALL_METHOD): 'make'
# deploys from source via the operator's own medik8s tools/dev.mk target
# `make dev-olm-deploy` (build the operator + OLM bundle images from the cloned
# repo, push to a registry, and `operator-sdk run bundle` into RHWA_NAMESPACE so
# OLM manages it and injects webhook certs) -- the default, since this lab targets
# development work; 'catalog' subscribes via OLM from redhat-operators. The make
# targets run on the EC2 host (go/make/podman/oc). Operators without the dev.mk
# flow (and any make install that fails) fall back to the catalog automatically.

# Wait for a CSV whose name starts with <prefix> to reach Succeeded.
_wait_csv() {
  local prefix="$1" i phase
  for ((i=0; i<60; i++)); do
    phase="$(oc -n "$RHWA_NAMESPACE" get csv -o json 2>/dev/null \
      | jq -r --arg p "$prefix" '.items[] | select(.metadata.name|startswith($p)) | .status.phase' \
      | head -1)"
    [[ "$phase" == "Succeeded" ]] && { ok "CSV ${prefix}* Succeeded"; return 0; }
    sleep 15
  done
  warn "CSV ${prefix}* did not reach Succeeded (last: ${phase:-none})"
  return 1
}

# Per-operator defaults: "method|repo". method is the operator's OWN capability
# (make = deploy-from-source via its tools/dev.mk `dev-olm-deploy`; catalog
# otherwise). The global RHWA_INSTALL_METHOD and per-operator overrides layer on
# in _op_method/_op_field.
_op_defaults() {
  local b=https://github.com/medik8s
  case "$1" in
    node-healthcheck-operator)    echo "make|${b}/node-healthcheck-operator";;
    fence-agents-remediation)     echo "make|${b}/fence-agents-remediation";;
    self-node-remediation)        echo "make|${b}/self-node-remediation";;
    node-maintenance-operator)    echo "make|${b}/node-maintenance-operator";;
    machine-deletion-remediation) echo "catalog|${b}/machine-deletion-remediation";;
    storage-based-remediation)    echo "make|${b}/storage-based-remediation";;
    *)                            echo "catalog|";;
  esac
}

# <OP>_<FIELD> env override, else the table default. FIELD REPO has a table
# default; REF (branch/tag/SHA) and DEV_ENV (extra `make` env, e.g. NHC's
# CONSOLE_PLUGIN_IMAGE/MUST_GATHER_IMAGE) default empty.
_op_field() {
  local op="$1" field="$2" key ov
  key="$(printf '%s' "$op" | tr '[:lower:]-' '[:upper:]_')"
  ov="${key}_${field}"; ov="${!ov:-}"
  [[ -n "$ov" ]] && { printf '%s' "$ov"; return; }
  [[ "$field" == REPO ]] && { _op_defaults "$op" | cut -d'|' -f2; return; }
  printf ''
}

# Resolved install method for an operator: explicit <OP>_INSTALL_METHOD wins;
# else a global RHWA_INSTALL_METHOD=catalog forces catalog; else the operator's
# own default (so global 'make' still leaves not-yet-supported ones on catalog).
_op_method() {
  local op="$1" key ov
  key="$(printf '%s' "$op" | tr '[:lower:]-' '[:upper:]_')"
  ov="${key}_INSTALL_METHOD"; ov="${!ov:-}"
  [[ -n "$ov" ]] && { printf '%s' "$ov"; return; }
  [[ "${RHWA_INSTALL_METHOD:-make}" == "catalog" ]] && { printf 'catalog'; return; }
  _op_defaults "$op" | cut -d'|' -f1
}

# Namespace + AllNamespaces OperatorGroup (OLM needs the OG for catalog installs;
# harmless for make). NHC and FAR are AllNamespaces-only, so the OG spec is empty
# -- a targetNamespaces OG makes OLM reject their CSVs.
_ensure_rhwa_namespace() {
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHWA_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhwa-operatorgroup
  namespace: ${RHWA_NAMESPACE}
spec: {}
EOF
}

# Prepare the EC2 host to run the operators' `make dev-olm-deploy`: ensure the
# go/make/git toolchain (podman + oc are already on the host), and push the lab's
# verified kubeconfig so the on-host make talks to THIS cluster. OLM injects the
# webhook certs for a bundle install, so no cert-manager wiring is needed.
_dev_olm_prepare() {
  log "Preparing host for dev-olm-deploy (go/make/git + docker->podman shim + kubeconfig)"
  ssh_host "sudo bash -s" <<'EOS'
set -euo pipefail
pkgs=""
command -v go   >/dev/null 2>&1 || pkgs="$pkgs golang"
command -v make >/dev/null 2>&1 || pkgs="$pkgs make"
command -v git  >/dev/null 2>&1 || pkgs="$pkgs git"
# Several operator Makefiles hardcode `docker` (not $(CONTAINER_TOOL)), so a make
# variable can't redirect them; podman-docker installs a /usr/bin/docker shim
# over podman so those targets work on the host.
command -v docker >/dev/null 2>&1 || pkgs="$pkgs podman-docker"
[ -n "$pkgs" ] && dnf install -y $pkgs >/dev/null
# Silence podman-docker's "Emulate Docker CLI using podman" notice on stderr.
mkdir -p /etc/containers && touch /etc/containers/nodocker
EOS
  # Clone the medik8s tools repo once and patch dev.mk's `run bundle` to use a
  # longer --timeout (default 2m is too short here); operators then use this via
  # TOOLS_DIR instead of re-downloading tools. Runs as the host user.
  ssh_host "bash -s" <<EOS
set -euo pipefail
export PATH="\$HOME/bin:\$PATH"
td="\$HOME/${RHWA_DEV_TOOLS_DIR}"
if [ -d "\$td/.git" ]; then
  git -C "\$td" checkout -- . 2>/dev/null || true
  git -C "\$td" pull --ff-only -q 2>/dev/null || true
else
  git clone --depth 1 https://github.com/medik8s/tools "\$td"
fi
if ! grep -q 'run bundle "\$(DEV_OLM_BUNDLE_IMAGE)" --timeout' "\$td/dev/dev.mk"; then
  sed -i 's|run bundle "\$(DEV_OLM_BUNDLE_IMAGE)"|& --timeout=${RHWA_DEV_BUNDLE_TIMEOUT}|' "\$td/dev/dev.mk"
fi
grep -q 'run bundle "\$(DEV_OLM_BUNDLE_IMAGE)" --timeout' "\$td/dev/dev.mk" \
  || echo "WARN: could not patch dev.mk run-bundle timeout (layout changed?)" >&2
EOS
  [[ -s "$KUBECONFIG_LOCAL" ]] || die "no local kubeconfig at ${KUBECONFIG_LOCAL}; run create first"
  scp_to "$KUBECONFIG_LOCAL" "${RHWA_DEV_KUBECONFIG}"
}

# Catalog (OLM) install of one operator: a Subscription in RHWA_NAMESPACE. The
# package name matches the operator name for the RHWA set.
_install_operator_catalog() {
  local op="$1"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${op}
  namespace: ${RHWA_NAMESPACE}
spec:
  channel: ${RHWA_CHANNEL}
  name: ${op}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
}

# Resolve a tag pullspec to its immutable digest (linux/amd64) via `oc image
# info`, without pulling. Prints "sha256:..." or nothing. Used to pin NHC's
# related images (below); the registries are public (quay.io/medik8s).
_image_digest() {
  oc image info --filter-by-os=linux/amd64 "$1" 2>/dev/null \
    | sed -n 's/^Digest:[[:space:]]*//p' | head -1
}

# NHC's bundle build (dev-olm-validate-inputs) demands CONSOLE_PLUGIN_IMAGE and
# MUST_GATHER_IMAGE as DIGEST pullspecs. Those are separate PUBLISHED images (not
# the operator we build), so we can't get their digest from our own push -- but
# we can resolve the published tags to digests automatically. Override the source
# tags with NHC_CONSOLE_PLUGIN_REF / NHC_MUST_GATHER_REF, or the whole thing with
# NODE_HEALTHCHECK_OPERATOR_DEV_ENV. Returns non-zero if either can't be resolved
# (caller then leaves DEV_ENV empty -> NHC falls back to catalog).
_nhc_auto_dev_env() {
  local cpref="${NHC_CONSOLE_PLUGIN_REF:-quay.io/medik8s/node-remediation-console:latest}"
  local mgref="${NHC_MUST_GATHER_REF:-quay.io/medik8s/must-gather:latest}"
  local cpd mgd
  cpd="$(_image_digest "$cpref")"; mgd="$(_image_digest "$mgref")"
  [[ "$cpd" == sha256:* && "$mgd" == sha256:* ]] || return 1
  printf 'CONSOLE_PLUGIN_IMAGE=%s@%s MUST_GATHER_IMAGE=%s@%s' "${cpref%:*}" "$cpd" "${mgref%:*}" "$mgd"
}

# Deploy one operator from source via its own `make dev-olm-deploy` (medik8s
# tools/dev.mk): clone the repo on the host, build the operator + OLM bundle
# images, push to DEV_REGISTRY (default ttl.sh for external clusters), and
# `operator-sdk run bundle` into RHWA_NAMESPACE so OLM installs and manages it
# (webhook certs included). Runs on the host against the pushed kubeconfig; all
# output is captured to a per-operator log. Returns non-zero (caller falls back
# to catalog) on any failure -- e.g. NHC without its required
# NODE_HEALTHCHECK_OPERATOR_DEV_ENV (CONSOLE_PLUGIN_IMAGE/MUST_GATHER_IMAGE).
_install_operator_make() {
  local op="$1" repo ref devenv rc=0
  repo="$(_op_field "$op" REPO)"; ref="$(_op_field "$op" REF)"; devenv="$(_op_field "$op" DEV_ENV)"
  [[ -n "$repo" ]] || { warn "no repo known for ${op}; cannot deploy from source"; return 1; }
  # NHC needs its related images as digests; resolve them unless the user pinned
  # them via NODE_HEALTHCHECK_OPERATOR_DEV_ENV.
  if [[ "$op" == "node-healthcheck-operator" && -z "$devenv" ]]; then
    if devenv="$(_nhc_auto_dev_env)"; then
      log "Resolved NHC related-image digests (${devenv})"
    else
      warn "could not resolve NHC console-plugin/must-gather digests; dev-olm-deploy will fail -> catalog fallback"
      devenv=""
    fi
  fi
  mkdir -p "${CLUSTER_DIR}/rhwa"
  local logf="${CLUSTER_DIR}/rhwa/${op}-dev-olm.log"
  # Force podman: some operator Makefiles default CONTAINER_TOOL to docker, which
  # the host doesn't have (a command-line make var overrides the Makefile default
  # everywhere $(CONTAINER_TOOL) is used). Common args are reused by undeploy.
  local margs="SKIP_KIND=true CONTAINER_TOOL=podman KUBECTL=oc DEV_OLM_OPERATOR_NAMESPACE='${RHWA_NAMESPACE}'"
  local deployargs="${margs}${RHWA_DEV_REGISTRY:+ DEV_REGISTRY='${RHWA_DEV_REGISTRY}'}${RHWA_DEV_VERSION:+ VERSION='${RHWA_DEV_VERSION}'}${devenv:+ ${devenv}}"
  log "Deploying ${op} from ${repo}${ref:+@${ref}} via 'make dev-olm-deploy' on host (builds+pushes images via ${RHWA_DEV_REGISTRY:-ttl.sh}; slow) -> ${logf}"
  ssh_host "bash -s" >"$logf" 2>&1 <<EOS || rc=$?
set -euo pipefail
export PATH="\$HOME/bin:\$PATH"                     # host oc/kubectl live in ~/bin
export KUBECONFIG="\$HOME/${RHWA_DEV_KUBECONFIG}"
wd="\$(mktemp -d "\${TMPDIR:-/tmp}/rhwa-op.XXXXXX")"
trap 'rm -rf "\$wd"' EXIT
git clone --depth 1 ${ref:+--branch '${ref}'} '${repo}' "\$wd/src"
cd "\$wd/src"
if make dev-olm-deploy TOOLS_DIR="\$HOME/${RHWA_DEV_TOOLS_DIR}" ${deployargs}; then exit 0; fi
# Capture WHY it failed BEFORE cleanup deletes the pods. operator-sdk's timeout
# message doesn't say whether the deployment was merely slow (Pending/pulling ->
# a bigger timeout helps) or actually broken (CrashLoop/ImagePull/unschedulable
# -> it won't), so dump the operator's pods, their events, logs, and namespace
# events. This lands in the per-operator log (${logf}).
echo "### dev-olm-deploy failed for ${op}; diagnostics before cleanup ###"
oc -n '${RHWA_NAMESPACE}' get pods -o wide || true
for pod in \$(oc -n '${RHWA_NAMESPACE}' get pods -o name 2>/dev/null | grep -- '${op}' || true); do
  echo "--- \$pod events ---"; oc -n '${RHWA_NAMESPACE}' describe "\$pod" 2>/dev/null | sed -n '/Events:/,\$p' || true
  echo "--- \$pod logs ---";   oc -n '${RHWA_NAMESPACE}' logs "\$pod" --all-containers --tail=40 2>/dev/null || true
done
echo "--- recent namespace events ---"
oc -n '${RHWA_NAMESPACE}' get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
# Remove any partial operator-sdk install (CatalogSource/Subscription/CSV) so the
# catalog fallback doesn't stack a second subscription for this op.
echo "### cleaning up partial OLM install before catalog fallback ###"
make dev-olm-undeploy TOOLS_DIR="\$HOME/${RHWA_DEV_TOOLS_DIR}" ${margs} >/dev/null 2>&1 || true
exit 1
EOS
  if (( rc != 0 )); then
    warn "dev-olm-deploy for ${op} failed (rc=${rc}); see ${logf}. Tail (incl. pod diagnostics):"
    tail -n 45 "$logf" 2>/dev/null | sed 's/^/    /' >&2 || true
    return 1
  fi
  ok "${op} deployed from source (OLM-managed in ${RHWA_NAMESPACE})"
}

# Keep every Subscription in RHWA_NAMESPACE on Automatic approval, and approve any
# pending install plan. `operator-sdk run bundle` (the dev-olm-deploy path) creates
# Manual-approval subscriptions and self-approves only their FIRST plan; as more
# operators are added, OLM re-resolves the namespace and generates new plans (for
# the just-added operator AND existing ones, plus the Automatic catalog subs like
# MDR) that then sit unapproved and block rollout -- or stall a later operator's
# install into a catalog fallback. This is called after EVERY install (not just at
# the end) so the namespace stays Automatic as plans appear: a single, idempotent,
# fast pass -- once a subscription is Automatic, OLM auto-approves its later plans.
_ensure_olm_auto_approve() {
  local sub ip
  for sub in $(oc -n "$RHWA_NAMESPACE" get subscription -o name 2>/dev/null); do
    oc -n "$RHWA_NAMESPACE" patch "$sub" --type=merge \
      -p '{"spec":{"installPlanApproval":"Automatic"}}' >/dev/null 2>&1 || true
  done
  for ip in $(oc -n "$RHWA_NAMESPACE" get installplan -o name 2>/dev/null); do
    [[ "$(oc -n "$RHWA_NAMESPACE" get "$ip" -o jsonpath='{.spec.approved}' 2>/dev/null)" == "true" ]] && continue
    oc -n "$RHWA_NAMESPACE" patch "$ip" --type=merge -p '{"spec":{"approved":true}}' >/dev/null 2>&1 || true
  done
}

rhwa_install_operators() {
  # Canonical defaults + docs live in common.sh; repeated here so the lib is
  # usable when sourced standalone (e.g. tests) under `set -u`.
  : "${RHWA_INSTALL_METHOD:=make}"
  : "${RHWA_OPERATORS:=node-healthcheck-operator fence-agents-remediation self-node-remediation node-maintenance-operator machine-deletion-remediation storage-based-remediation}"
  : "${RHWA_DEV_KUBECONFIG:=rhwa-dev.kubeconfig}"
  : "${RHWA_DEV_TOOLS_DIR:=rhwa-tools}"
  : "${RHWA_DEV_BUNDLE_TIMEOUT:=10m}"
  log "Installing RHWA operators (default method: ${RHWA_INSTALL_METHOD})"
  _ensure_rhwa_namespace

  # Prep the host toolchain + kubeconfig once, only if any operator uses make.
  local op any_make=no
  for op in ${RHWA_OPERATORS}; do
    [[ "$(_op_method "$op")" == "make" ]] && any_make=yes
  done
  [[ "$any_make" == "yes" ]] && _dev_olm_prepare

  # Install each operator by its resolved method; a failed dev-olm-deploy falls
  # back to the catalog. Both paths install via OLM, so both produce a CSV.
  for op in ${RHWA_OPERATORS}; do
    if [[ "$(_op_method "$op")" == "make" ]]; then
      _install_operator_make "$op" \
        || { warn "dev-olm-deploy failed for ${op}; falling back to OLM catalog"; _install_operator_catalog "$op"; }
    else
      log "Installing ${op} via OLM catalog (channel ${RHWA_CHANNEL})"
      _install_operator_catalog "$op"
    fi
    # After EACH install: keep the namespace on Automatic approval so the next
    # operator's install doesn't stall on this one's pending (Manual) plan.
    _ensure_olm_auto_approve
  done
  _ensure_olm_auto_approve   # final sweep for any plan that appeared just now

  # Readiness (non-fatal so `test` can surface any real problem): every operator
  # is OLM-managed, so wait on its CSV reaching Succeeded.
  for op in ${RHWA_OPERATORS}; do _wait_csv "$op" || true; done
  # SNR auto-creates a default SelfNodeRemediationConfig on startup; confirm it
  # appears so consumers (and SNR test suites) find it configured.
  _wait_snr_config || true
}

# Wait for SNR's default SelfNodeRemediationConfig CR to be created by the
# operator (it manages this singleton itself; we don't create it).
_wait_snr_config() {
  local i
  for ((i=0; i<40; i++)); do
    if oc -n "$RHWA_NAMESPACE" get selfnoderemediationconfig self-node-remediation-config \
         >/dev/null 2>&1; then
      ok "SelfNodeRemediationConfig 'self-node-remediation-config' exists"
      return 0
    fi
    sleep 15
  done
  warn "SelfNodeRemediationConfig did not appear; check the self-node-remediation operator."
  return 1
}

# Build the per-node "--systems-uri" nodeparameters block (Node name -> URI).
_far_nodeparams() {
  compute_nodes
  local i uuid
  echo "        \"--systems-uri\":"
  for i in "${!NODE_NAME[@]}"; do
    uuid="$(state_get "uuid_${NODE_NAME[$i]}")"
    # Key is the Kubernetes Node name (= hostname we assigned).
    echo "          \"${NODE_HOST[$i]}\": \"/redfish/v1/Systems/${uuid}\""
  done
}

rhwa_configure_fencing() {
  log "Creating FenceAgentsRemediationTemplate (fence_redfish) + NodeHealthCheck"
  oc apply -f - <<EOF
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  name: fenceagentsremediationtemplate-default
  namespace: ${RHWA_NAMESPACE}
spec:
  template:
    spec:
      agent: fence_redfish
      remediationStrategy: ResourceDeletion
      sharedparameters:
        "--ip": "${NET_GATEWAY}"
        "--ipport": "${SUSHY_PORT}"
        "--username": "${SUSHY_USER}"
        "--password": "${SUSHY_PASS}"
        "--ssl-insecure": "1"
      nodeparameters:
$(_far_nodeparams)
EOF

  oc apply -f - <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: rhwa-nhc
spec:
  minHealthy: "51%"
  selector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
    - key: node-role.kubernetes.io/control-plane
      operator: DoesNotExist
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: fenceagentsremediationtemplate-default
    namespace: ${RHWA_NAMESPACE}
  unhealthyConditions:
  - type: Ready
    status: "False"
    duration: 60s
  - type: Ready
    status: Unknown
    duration: 60s
EOF
  ok "RHWA fencing configured (fence_redfish -> https://${NET_GATEWAY}:${SUSHY_PORT})"
}

# Emit a provisionable worker BMH (+ its BMC secret). Shared by cluster workers
# and spares: NOT externallyProvisioned; rootDeviceHints pins the virtio root
# disk (/dev/vda — metal3 defaults to /dev/sda, which is absent on virtio).
_apply_worker_bmh() {
  local name="$1" mac="$2" uuid="$3" mapi="openshift-machine-api"
  local addr="redfish-virtualmedia://${NET_GATEWAY}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
  local secret="${name}-bmc-secret"
  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${mapi}
type: Opaque
stringData:
  username: "${SUSHY_USER}"
  password: "${SUSHY_PASS}"
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${mapi}
spec:
  online: true
  bootMACAddress: ${mac}
  rootDeviceHints:
    deviceName: /dev/vda
  bmc:
    address: ${addr}
    credentialsName: ${secret}
    disableCertificateVerification: true
EOF
  ok "BMH ${name} (worker): provisionable -> ${addr}"
}

rhwa_configure_bmh() {
  compute_nodes; compute_spares
  local mapi="openshift-machine-api"
  log "Configuring BareMetalHost BMC (+ provisionable workers/spares)"
  local i name role uuid addr secret
  for i in "${!NODE_HOST[@]}"; do
    name="${NODE_HOST[$i]}"; role="${NODE_ROLE[$i]}"
    uuid="$(state_get "uuid_${NODE_NAME[$i]}")"
    if [[ -z "$uuid" ]]; then warn "no libvirt UUID for ${name}; skipping"; continue; fi
    if [[ "$role" == "master" ]]; then
      addr="redfish-virtualmedia://${NET_GATEWAY}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
      secret="${name}-bmc-secret"
      oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret}
  namespace: ${mapi}
type: Opaque
stringData:
  username: "${SUSHY_USER}"
  password: "${SUSHY_PASS}"
EOF
      # Masters install via ABI and must NEVER be reprovisioned: add BMC only,
      # leave externallyProvisioned / bootMACAddress untouched. If the installer
      # BMH is missing, self-heal by creating an externallyProvisioned:true
      # master BMH (BMC + credentials ONLY) so ironic power-manages it without
      # ever provisioning it -- never set bootMACAddress/rootDeviceHints/online
      # provisioning fields on a master.
      if oc -n "$mapi" get baremetalhost "$name" >/dev/null 2>&1; then
        oc -n "$mapi" patch baremetalhost "$name" --type merge -p \
          "{\"spec\":{\"online\":true,\"bmc\":{\"address\":\"${addr}\",\"credentialsName\":\"${secret}\",\"disableCertificateVerification\":true}}}"
        ok "BMH ${name} (master): BMC set -> ${addr}"
      else
        warn "BareMetalHost ${name} (master) not found; creating an externally-provisioned one"
        oc apply -f - <<EOF
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${mapi}
spec:
  online: true
  externallyProvisioned: true
  bmc:
    address: ${addr}
    credentialsName: ${secret}
    disableCertificateVerification: true
EOF
        ok "BMH ${name} (master): created externallyProvisioned -> ${addr}"
      fi
    else
      _apply_worker_bmh "$name" "${NODE_MAC[$i]}" "$uuid"
    fi
  done
  # Spare workers: provisionable BMHs left available (unconsumed) so a scale-up
  # test (OCP-51155) can grow the MachineSet onto them.
  for i in "${!SPARE_HOST[@]}"; do
    uuid="$(state_get "uuid_${SPARE_NAME[$i]}")"
    if [[ -z "$uuid" ]]; then warn "no libvirt UUID for spare ${SPARE_HOST[$i]}; skipping"; continue; fi
    _apply_worker_bmh "${SPARE_HOST[$i]}" "${SPARE_MAC[$i]}" "$uuid"
  done
}


rhwa_setup() {
  rhwa_install_operators
  rhwa_configure_fencing
  rhwa_configure_bmh
}
