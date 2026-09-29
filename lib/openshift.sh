#!/usr/bin/env bash
# openshift.sh - render agent-based install configs, build the agent ISO on
# the host, and drive the install to completion. `oc`/`openshift-install`
# for the cluster run on the HOST (node IPs are only reachable there);
# a local `oc` is fetched too for the RHWA/test phases (via public API).

MIRROR="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OCP_VERSION}"

# Fail fast on a bad OCP_VERSION. os_host_tools/os_local_oc download the
# installer and client from ${MIRROR}; an invalid version otherwise surfaces as
# a curl 404 deep into create -- after the EC2 instance is already running and
# billing. Probe the exact artifact the install will fetch (public mirror,
# reachable from the operator's machine) and die with a clear message if the
# version does not resolve to a real release.
validate_ocp_version() {
  log "Validating OCP version '${OCP_VERSION}'"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --head --max-time 30 \
    "${MIRROR}/openshift-install-linux.tar.gz" 2>/dev/null || true)"
  if [[ "$code" != "200" ]]; then
    die "OCP_VERSION '${OCP_VERSION}' is not valid: no OpenShift release found on the mirror (HTTP ${code:-no response}).
    Looked for: ${MIRROR}/openshift-install-linux.tar.gz
    Set OCP_VERSION to a version that exists under
    https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/
    e.g. a release (4.22.13, 5.0.0-rc.2) or a channel alias (stable-4.22, latest-4.22)."
  fi
  ok "OCP version '${OCP_VERSION}' available on the mirror"
}

# Download openshift-install + oc onto the EC2 host.
os_host_tools() {
  log "Fetching openshift-install + oc (${OCP_VERSION}) on host"
  ssh_host 'bash -s' <<EOS
set -euo pipefail
mkdir -p ~/bin
cd ~/bin
curl -fsSL '${MIRROR}/openshift-install-linux.tar.gz' | tar xz openshift-install
curl -fsSL '${MIRROR}/openshift-client-linux.tar.gz'  | tar xz oc kubectl
./openshift-install version
EOS
  ok "Installer tools present on host"
}

# Fetch a local oc for RHWA/test phases (talks to the public API endpoint).
# This oc runs on the OPERATOR's machine (not the EC2 host), so pick the client
# for the local OS/arch -- a Linux binary won't execute on macOS. os_host_tools
# always fetches the Linux client because that one runs on the Linux EC2 host.
_oc_client_tarball() {
  case "$(uname -s)" in
    Darwin)
      case "$(uname -m)" in
        arm64|aarch64) echo "openshift-client-mac-arm64.tar.gz" ;;
        *)             echo "openshift-client-mac.tar.gz" ;;
      esac ;;
    *) echo "openshift-client-linux.tar.gz" ;;
  esac
}

os_local_oc() {
  mkdir -p "$BIN_DIR"
  [[ -x "${BIN_DIR}/oc" ]] && return 0
  local tb; tb="$(_oc_client_tarball)"
  log "Fetching local oc (${OCP_VERSION}, ${tb})"
  curl -fsSL "${MIRROR}/${tb}" | tar xz -C "$BIN_DIR" oc kubectl
  ok "Local oc at ${BIN_DIR}/oc"
}

# Emit install-config.yaml to stdout.
#   $1 = pullSecret value to embed; pass a placeholder (e.g. '{"auths":{}}')
#        for a sanitized, secret-free config.
#   $2 = sshKey value to embed (optional). If omitted, the real public key
#        from SSH_PUBLIC_KEY_FILE is used (what a real cluster needs). Pass an
#        explicit placeholder to keep even the public key out of sanitized
#        output — it identifies the operator and isn't needed to validate the
#        config's schema/topology.
# Keeping this the single source of the install-config keeps the real render
# and the sanitized `install-config` command from drifting.
_emit_install_config() {
  local pull="$1" sshkey="${2:-}"
  if [[ -z "$sshkey" ]]; then
    if [[ -r "$SSH_PUBLIC_KEY_FILE" ]]; then
      sshkey="$(<"$SSH_PUBLIC_KEY_FILE")"
    else
      sshkey="ssh-ed25519 AAAA...placeholder... sanitized@rhwa-lab"
    fi
  fi
  cat <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: ${NET_CIDR}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
# Workers are provisioned post-install by a MachineSet via metal3 (Approach A1).
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: ${CONTROL_PLANE_COUNT}
platform:
  baremetal:
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
pullSecret: '${pull}'
sshKey: '${sshkey}'
EOF
}

# Print a sanitized install-config.yaml to stdout for external test suites that
# require the file: both the pull secret AND the operator's public SSH key are
# replaced with placeholders. Redirect it:
#   `./rhwa-lab install-config > install-config.yaml`
os_sanitized_install_config() {
  _emit_install_config '{"auths":{}}' 'ssh-ed25519 AAAA...redacted... sanitized@rhwa-lab'
}

# Render install-config.yaml + agent-config.yaml locally, then scp to host.
os_render_configs() {
  compute_nodes
  local dir="${CLUSTER_DIR}/install"
  mkdir -p "$dir"

  _emit_install_config "$PULL_SECRET" > "${dir}/install-config.yaml"
  chmod 600 "${dir}/install-config.yaml"

  # agent-config with per-node static networking (nmstate).
  {
    cat <<EOF
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${RENDEZVOUS_IP}
hosts:
EOF
    local i
    for i in "${!NODE_NAME[@]}"; do
      [[ "${NODE_ROLE[$i]}" == "master" ]] || continue   # workers join via MachineSet, not ABI rendezvous
      cat <<EOF
- hostname: ${NODE_HOST[$i]}
  role: ${NODE_ROLE[$i]}
  interfaces:
  - name: enp1s0
    macAddress: ${NODE_MAC[$i]}
  networkConfig:
    interfaces:
    - name: enp1s0
      type: ethernet
      state: up
      mac-address: ${NODE_MAC[$i]}
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: ${NODE_IP[$i]}
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - ${NET_GATEWAY}
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: ${NET_GATEWAY}
        next-hop-interface: enp1s0
EOF
    done
  } > "${dir}/agent-config.yaml"
  ok "Rendered install-config.yaml + agent-config.yaml"
  # ITERATE: interface name enp1s0 assumed for q35+virtio; if RHCOS names it
  # differently, agent-config nmstate should match by mac-address identifier.
}

# Build the agent ISO on the host and stage it for libvirt.
#
# IDEMPOTENCY IS A CORRECTNESS REQUIREMENT, not just an optimization: each
# `agent create image` mints a fresh, unique set of cluster certs, and
# work/auth/ holds the ONLY copy of the matching kubeconfig + kubeadmin
# password. If we rebuild after the nodes have already booted the previous
# ISO, the new credentials can NEVER authenticate to the running cluster
# (openssl verify fails; oc gets "must provide credentials"), and even
# `openshift-install wait-for` hangs forever on its own orphaned kubeconfig.
# So we build exactly once per lab and reuse thereafter. To rebuild, destroy
# and recreate.
os_build_image() {
  local dir="${CLUSTER_DIR}/install"
  if [[ "$(state_get agent_image_built)" == "yes" ]] \
     && ssh_host "test -f ~/oc-install/work/auth/kubeconfig && test -f /var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso" 2>/dev/null; then
    ok "Reusing existing agent ISO + auth (rebuild would orphan the running cluster's credentials)"
    return 0
  fi
  log "Uploading configs and building agent ISO on host"
  ssh_host 'mkdir -p ~/oc-install/orig'
  scp_to "${dir}/install-config.yaml" '~/oc-install/orig/install-config.yaml'
  scp_to "${dir}/agent-config.yaml"   '~/oc-install/orig/agent-config.yaml'
  ssh_host 'bash -s' <<EOS
set -euo pipefail
cd ~/oc-install
# openshift-install consumes its input configs and caches state; start clean
# so re-runs don't reuse stale/partial assets.
rm -rf work && mkdir -p work
cp -f orig/install-config.yaml orig/agent-config.yaml work/
~/bin/openshift-install --dir work agent create image --log-level=info
sudo cp work/agent.x86_64.iso /var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso
sudo chmod 644 /var/lib/libvirt/images/${CLUSTER_NAME}-agent.iso
echo "agent ISO staged"
EOS
  state_set agent_image_built yes
  ok "Agent ISO built and staged"
}

# Path to the always-trusted recovery kubeconfig baked into every master.
# Unlike work/auth/kubeconfig (whose client cert is invalidated if the ISO is
# ever rebuilt), the apiserver ALWAYS trusts this one, so it is our source of
# truth for progress and completion regardless of cert-generation issues.
RECOVERY_KC='/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig'

# Tail the *real* openshift-install log from the host — the authoritative
# record of install progress (base ISO extraction, host stages, bootstrap,
# operator rollout). `--log-level=info` output goes here and to stderr; this is
# the log to look at, not any synthesized view. Debug lines are filtered so the
# meaningful info/warn/error messages stand out. Prints to stderr.
os_installer_log_tail() {
  local n="${1:-25}"
  ssh_host "grep -vi 'level=debug' ~/oc-install/work/.openshift_install.log 2>/dev/null | tail -n ${n}" >&2 \
    || printf '  (installer log not present yet)\n' >&2
}

# If the cluster API is already serving, print real `oc get co`/`nodes` output
# from a master's recovery kubeconfig (always trusted, immune to the cert-
# generation problem) and return 0 iff ClusterVersion Available=True. Silent
# and returns 1 if the API is not up yet. This is genuine cluster state, used
# to confirm completion and for the tail end of the monitor view.
os_cluster_status_via_recovery() {
  compute_nodes
  local out
  out="$(ssh_node "${RENDEZVOUS_IP}" 'sudo bash -s' 2>/dev/null <<NODE || true
set +e
OC="/usr/bin/oc --kubeconfig=${RECOVERY_KC}"
avail=\$(\$OC get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
[ -z "\$avail" ] && exit 0
echo "__AVAIL__ \$avail"
echo "operators not yet done (Available/Progressing/Degraded):"
\$OC get co --no-headers 2>/dev/null | awk '\$3!="True"||\$4!="False"||\$5!="False"{printf "  %-32s A=%s P=%s D=%s\n",\$1,\$3,\$4,\$5}'
echo "nodes:"
\$OC get nodes --no-headers 2>/dev/null | awk '{printf "  %-24s %s\n",\$1,\$2}'
NODE
)"
  [[ -z "$out" ]] && return 1
  printf '%s\n' "$out" | grep -v '^__AVAIL__' | sed 's/^/  /' >&2
  [[ "$(printf '%s\n' "$out" | sed -n 's/^__AVAIL__ //p' | head -1)" == "True" ]]
}

# Fetch a working kubeconfig + kubeadmin password for the running cluster.
# Prefers the installer-generated pair, but VERIFIES the kubeconfig actually
# authenticates; if it doesn't (orphaned by an ISO rebuild), it recovers a
# working kubeconfig from a master's recovery kubeconfig, repointed at the
# public API. This makes the tool self-heal instead of handing back creds
# that silently don't work.
os_fetch_creds() {
  compute_nodes
  if ssh_host 'export KUBECONFIG=~/oc-install/work/auth/kubeconfig; ~/bin/oc get clusterversion >/dev/null 2>&1'; then
    scp_from '~/oc-install/work/auth/kubeconfig' "$KUBECONFIG_LOCAL"
    scp_from '~/oc-install/work/auth/kubeadmin-password' "${CLUSTER_DIR}/kubeadmin-password"
    ok "Fetched installer kubeconfig + kubeadmin password"
  else
    warn "Installer kubeconfig does not authenticate (cert generation mismatch); recovering from ${RENDEZVOUS_IP}"
    ssh_node "${RENDEZVOUS_IP}" "sudo cat ${RECOVERY_KC}" 2>/dev/null \
      | sed -e "s#server: https://localhost:6443#server: https://$(api_fqdn):6443#" \
            -e "s#^\( *\)certificate-authority-data:.*#\1insecure-skip-tls-verify: true#" \
            -e "/tls-server-name:/d" > "$KUBECONFIG_LOCAL"
    [[ -s "$KUBECONFIG_LOCAL" ]] || die "failed to recover a working kubeconfig from ${RENDEZVOUS_IP}"
    printf '%s\n' "<unavailable — kubeconfig was regenerated after node boot; use the recovered kubeconfig for oc access>" \
      > "${CLUSTER_DIR}/kubeadmin-password"
    ok "Recovered a working kubeconfig from ${RENDEZVOUS_IP} (cluster-admin via recovery cert)"
  fi
  chmod 600 "$KUBECONFIG_LOCAL" "${CLUSTER_DIR}/kubeadmin-password"
}

# Wait for the install to finish by running openshift-install's OWN `agent
# wait-for` on the host and streaming its logs straight through to the user —
# these are the real installer messages (host stages, bootstrap, operators),
# not a synthesized view. `wait-for` has its own internal timeout, so we
# re-attach across those until bootstrap/install actually completes or our
# overall budget runs out. As a safety net (in case wait-for wedges on an
# orphaned kubeconfig), between attempts we check the cluster directly via a
# master's recovery kubeconfig and break out if it is already up.
os_wait_install() {
  compute_nodes
  local deadline=$(( $(date +%s) + ${INSTALL_TIMEOUT:-7200} ))

  # Resumability: once the cluster is up, assisted-service is gone and
  # `wait-for bootstrap-complete` can never succeed again — it would spin to
  # the deadline. So if a prior run already finished, or the API is already
  # serving, just (re)fetch creds and return instead of re-waiting.
  if [[ "$(state_get cluster_installed)" == "yes" ]] || os_cluster_status_via_recovery; then
    ok "Cluster already installed; skipping install wait"
    os_fetch_creds
    state_set cluster_installed yes
    return 0
  fi

  log "Waiting for bootstrap — streaming openshift-install log (~20-40m on nested virt)"
  while ! ssh_host 'cd ~/oc-install && ~/bin/openshift-install --dir work agent wait-for bootstrap-complete --log-level=info'; do
    (( $(date +%s) < deadline )) || die "bootstrap did not complete within budget; inspect with './rhwa-lab monitor'."
    warn "wait-for bootstrap-complete returned early; re-attaching to the installer..."
    sleep 5
  done
  ok "Bootstrap complete"

  log "Waiting for install to complete — streaming openshift-install log"
  while ! ssh_host 'cd ~/oc-install && ~/bin/openshift-install --dir work agent wait-for install-complete --log-level=info'; do
    if os_cluster_status_via_recovery; then
      warn "wait-for exited nonzero but the cluster reports Available=True; proceeding"
      break
    fi
    (( $(date +%s) < deadline )) || die "install did not complete within budget; inspect with './rhwa-lab monitor'."
    warn "wait-for install-complete returned early; re-attaching to the installer..."
    sleep 5
  done

  os_fetch_creds
  state_set cluster_installed yes
  ok "OpenShift install complete; kubeconfig at ${KUBECONFIG_LOCAL}"
}

# Convenience wrapper for local oc calls against the installed cluster.
oc() { KUBECONFIG="$KUBECONFIG_LOCAL" "${BIN_DIR}/oc" "$@"; }

os_wait_cluster_ready() {
  log "Waiting for cluster operators to stabilize"
  local i
  for ((i=0; i<60; i++)); do
    if oc get clusterversion version >/dev/null 2>&1 \
       && oc wait --for=condition=Available=True clusterversion/version --timeout=30s >/dev/null 2>&1; then
      ok "ClusterVersion Available"; return 0
    fi
    sleep 20
  done
  warn "Cluster did not report Available in time; check 'oc get co'."
}

# Provision the metal3-managed workers post-install: scale the baremetal
# MachineSet up to WORKER_COUNT (consuming the provisionable worker BMHs) and
# wait for that many worker Nodes to be Ready. Scale is used ONLY to add
# workers; targeted removal in tests must delete a specific Machine instead.
os_provision_workers() {
  local mapi="openshift-machine-api" ms i ready
  ms="$(oc -n "$mapi" get machineset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  [[ -n "$ms" ]] || die "no baremetal MachineSet found; cannot provision workers"
  log "Scaling MachineSet ${ms} to ${WORKER_COUNT} workers"
  oc -n "$mapi" scale machineset "$ms" --replicas="${WORKER_COUNT}"
  log "Waiting for ${WORKER_COUNT} worker nodes to reach Ready (metal3 provisioning)"
  for ((i=0; i<120; i++)); do
    # Count ONLY dedicated workers. With compute.replicas:0 the installer marks
    # the control plane schedulable, so masters carry the worker role too; the
    # `!control-plane` term excludes them, otherwise the 3 masters alone satisfy
    # WORKER_COUNT and this returns instantly with zero real workers.
    # Non-fatal under `set -o pipefail`: a transient `oc get nodes` failure
    # yields 0 (retry next poll) instead of aborting the whole run.
    ready="$( { oc get nodes -l 'node-role.kubernetes.io/worker=,!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null \
             | awk '$2=="Ready"' | wc -l; } || echo 0)"
    if (( ready >= WORKER_COUNT )); then
      ok "${ready} worker nodes Ready"
      os_unschedule_masters
      return 0
    fi
    sleep 30
  done
  warn "workers did not all reach Ready; check 'oc get bmh -n ${mapi}' and metal3 logs"
  return 1
}

# Take the control plane out of the schedulable pool once dedicated workers
# exist. compute.replicas:0 makes the installer set mastersSchedulable:true, so
# masters carry the worker role; with real workers up we want the standard
# control-plane/worker split so test workloads (and the nodes tests fence) land
# on workers, not masters. Only called after WORKER_COUNT workers are Ready, so
# the cluster is never left with nothing schedulable.
os_unschedule_masters() {
  log "Removing worker role from masters (mastersSchedulable=false)"
  if oc patch schedulers.config.openshift.io/cluster --type=merge \
       -p '{"spec":{"mastersSchedulable":false}}' >/dev/null 2>&1; then
    ok "Control plane set non-schedulable"
    os_evict_stranded_daemons
  else
    warn "could not set mastersSchedulable=false; masters keep the worker role"
  fi
}

# Flipping mastersSchedulable=false adds a node-role.kubernetes.io/master:NoSchedule
# taint to the control plane. DaemonSet pods placed on the masters while they were
# still schedulable (e.g. ingress-canary, insights-runtime-extractor) do not tolerate
# that taint, but NoSchedule never evicts running pods -- so they linger as orphans and
# trip KubeDaemonSetMisScheduled / KubeDaemonSetRolloutStuck indefinitely. Delete those
# stranded pods once the taint is in place; the DaemonSet controller will not recreate
# them on the tainted masters, while taint-tolerating daemons (ovn-kube, mcd,
# node-exporter, ...) are left untouched.
os_evict_stranded_daemons() {
  local masters node ns name i tainted count found=0

  masters="$(oc get nodes -l node-role.kubernetes.io/master \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)" || return 0
  [[ -n "$masters" ]] || return 0
  count="$(wc -w <<<"$masters")"

  # Wait (up to ~60s) for the control-plane NoSchedule taint so evicted pods are
  # not immediately rescheduled onto a still-schedulable master.
  for ((i=0; i<20; i++)); do
    tainted=0
    for node in $masters; do
      if oc get node "$node" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null \
           | grep -q 'node-role.kubernetes.io/master'; then
        tainted=$((tainted + 1))
      fi
    done
    [[ "$tainted" -eq "$count" ]] && break
    sleep 3
  done

  log "Clearing DaemonSet pods stranded on the control plane"
  for node in $masters; do
    while read -r ns name; do
      [[ -n "$ns" && -n "$name" ]] || continue
      if oc -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1; then
        ok "evicted stranded ${ns}/${name}"
        found=1
      fi
    done < <(oc get pods -A --field-selector "spec.nodeName=${node}" -o json 2>/dev/null \
      | jq -r '.items[]
          | select(any(.metadata.ownerReferences[]?; .kind == "DaemonSet"))
          | select( ( [ .spec.tolerations[]?
                | select(
                    ( (.key == "node-role.kubernetes.io/master"
                       or .key == "node-role.kubernetes.io/control-plane")
                      and (.effect == null or .effect == "" or .effect == "NoSchedule") )
                    or ( (.key == null or .key == "") and .operator == "Exists" )
                  ) ] | length ) == 0 )
          | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null)
  done
  [[ "$found" -eq 0 ]] && log "No stranded DaemonSet pods found on the control plane"
  return 0
}
