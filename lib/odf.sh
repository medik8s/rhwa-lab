#!/usr/bin/env bash
# odf.sh - stand up an EXTERNAL Ceph cluster on a single libvirt VM (3 extra
# disks -> 3 OSDs) and connect OpenShift Data Foundation (ODF) to it in
# external mode.
#
# Flow (all guarded by ODF_ENABLED; ceph VM by CEPH_ENABLED):
#   odf_ceph_define_vm   - CentOS-Stream cloud VM on the rhwa net, +CEPH_OSD_COUNT
#                          blank virtio disks (the OSD devices), cloud-init'd.
#   odf_ceph_bootstrap   - cephadm --single-host-defaults; add one OSD per disk;
#                          create the replicated RBD pool sized for 200 GB usable.
#   odf_ceph_export      - run ceph-external-cluster-details-exporter.py to emit
#                          the external-connection JSON (mons, keys, endpoints).
#   odf_install_operator - OLM Subscription for the odf-operator.
#   odf_import_external  - materialize the exporter JSON as the Secrets/ConfigMaps
#                          rook expects (exactly what the OCP console importer does).
#   odf_create_storagecluster - external-mode StorageCluster; ODF then creates
#                          the ceph-rbd StorageClass automatically.
#
# The ceph VM is NOT an OpenShift node: no BMH, no fencing, not in compute_nodes.
# It is reachable only from the EC2 host, so every command hops ssh_host -> VM.

# SSH into the ceph VM the same way it works by hand: connect to the EC2 host,
# then run `ssh` to the VM FROM the host, with the operator's ssh-agent forwarded
# (-A). We deliberately do NOT use a -W/ProxyJump tunnel: that makes the host's
# sshd open the forwarded TCP connection to the VM, which this environment
# refuses ("connect failed") even though a normal host->VM ssh works. Forwarding
# the agent (rather than assuming a passwordless key, or copying a key to the
# host) means the operator's passphrase-protected key -- already unlocked in
# their local agent -- authenticates the host->VM hop. StrictHostKeyChecking=no +
# /dev/null on the inner hop so a reprovisioned VM's changed host key never blocks
# us. The node network (192.168.126.0/24) is only reachable from the host.
_ssh_ceph() {
  local inner="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 ${CEPH_SSH_USER}@${CEPH_IP}"
  ssh -A "${_ssh_opts[@]}" "${HOST_SSH_USER}@$(host_ip)" "${inner}" "$@"
}

# Wait until the ceph VM answers SSH. We deliberately do NOT gate on cloud-init
# packages here: podman & friends are installed by odf_ceph_bootstrap over SSH
# (with retries + visible errors), so a first-boot dnf/mirror hiccup surfaces as
# a real error there instead of a silent 10-minute "unreachable" here.
# On timeout, dump host-side diagnostics (is the domain running? what IP did it
# actually get? can the host reach it?) so the failure explains itself.
_ceph_wait_ssh() {
  local i
  for ((i=0; i<60; i++)); do
    if _ssh_ceph true 2>/dev/null; then
      ok "ceph VM reachable over SSH at ${CEPH_IP}"
      return 0
    fi
    sleep 10
  done
  warn "ceph VM ${CEPH_IP} unreachable; collecting host-side diagnostics:"
  ssh_host "sudo bash -c '
    echo \"domstate: \$(virsh domstate ${CEPH_NODE_NAME} 2>&1)\"
    echo \"--- interfaces (guest/lease view) ---\"
    virsh domifaddr ${CEPH_NODE_NAME} --source lease 2>&1 || true
    echo \"--- dhcp leases on ${LIBVIRT_NET} ---\"
    virsh net-dhcp-leases ${LIBVIRT_NET} 2>&1 || true
    echo \"--- can the host reach ${CEPH_IP}? ---\"
    ping -c1 -W2 ${CEPH_IP} 2>&1 || true'" >&2 || true
  die "ceph VM ${CEPH_IP} did not become reachable over SSH (see diagnostics above)"
}

# Comma-free list of OSD device paths (vdb, vdc, ...): root is vda, so the extra
# disks start at vdb. CEPH_OSD_COUNT<=9 (single letter) is plenty for a lab.
_ceph_osd_devs() {
  local letters="bcdefghij" i
  for ((i=0; i<CEPH_OSD_COUNT; i++)); do printf 'vd%s ' "${letters:$i:1}"; done
}

# Define the ceph VM on the host: a CentOS-Stream cloud image (backing-file COW
# root) + CEPH_OSD_COUNT blank qcow2 data disks, brought up with a NoCloud
# cloud-init seed that injects our SSH key and installs podman/python3/lvm2/chrony.
#
# We build our OWN persistent seed ISO with genisoimage instead of using
# virt-install's `--cloud-init`: with the --print-xml/define/start split that the
# rest of the lab uses, virt-install's generated seed ISO is transient and gets
# discarded, so the started domain references a missing cloudinit.iso. Our seed
# lives in the images pool and persists for the domain's life.
#
# Idempotency is HEALTH-based, not marker-based, and never gratuitously
# destructive:
#   - VM up AND reachable at CEPH_IP -> left exactly as-is (the common re-run
#     case; a working ceph is never disturbed, whether or not the bootstrap
#     sequence had finished).
#   - VM exists but unhealthy AND ceph already bootstrapped -> NEVER auto-destroy
#     (its disks hold ceph data): start it if stopped, else warn and leave it for
#     the operator to inspect / tear down by hand.
#   - VM missing, or unhealthy and NOT yet bootstrapped -> (re)build with a FRESH
#     root + seed (reusing an already-booted root would make cloud-init skip and
#     ignore updated config). This is what lets a plain `create` re-run recover a
#     half-built VM (e.g. one that came up on the wrong IP) automatically.
odf_ceph_define_vm() {
  [[ "${CEPH_ENABLED}" == "true" ]] || { log "CEPH_ENABLED=false; skipping ceph VM"; return 0; }
  local bootstrapped; bootstrapped="$(state_get ceph_bootstrapped)"
  local pubkey; pubkey="$(<"${SSH_PUBLIC_KEY_FILE}")"
  local ram_mb=$(( CEPH_RAM_GB * 1024 ))
  local base="/var/lib/libvirt/images/ceph-base.qcow2"
  local root="/var/lib/libvirt/images/${CEPH_NODE_NAME}.qcow2"
  local seed="/var/lib/libvirt/images/${CEPH_NODE_NAME}-seed.iso"
  local seeddir="/tmp/${CEPH_NODE_NAME}-seed"
  local dir="${CLUSTER_DIR}/ceph"; mkdir -p "$dir"
  local osd_devs; osd_devs="$(_ceph_osd_devs)"
  local osd_disks="" dev
  for dev in ${osd_devs}; do
    osd_disks+=" --disk path=/var/lib/libvirt/images/${CEPH_NODE_NAME}-${dev}.qcow2,bus=virtio"
  done

  # Health check first, so a re-run only rebuilds when it actually needs to.
  local domstate
  domstate="$(ssh_host "sudo virsh domstate '${CEPH_NODE_NAME}' 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1 || true)"
  if [[ -n "$domstate" ]]; then
    if [[ "$domstate" == "running" ]] && _ssh_ceph true 2>/dev/null; then
      ok "ceph VM ${CEPH_NODE_NAME} is up and reachable at ${CEPH_IP}; leaving it unchanged"
      return 0
    fi
    if [[ "$bootstrapped" == "yes" ]]; then
      # A bootstrapped ceph lives on this VM's disks -- never auto-destroy it.
      if [[ "$domstate" != "running" ]]; then
        log "Starting existing (bootstrapped) ceph VM ${CEPH_NODE_NAME}"
        ssh_host "sudo virsh start '${CEPH_NODE_NAME}'" >/dev/null 2>&1 || true
      else
        warn "ceph VM is running but unreachable at ${CEPH_IP}, and ceph is already bootstrapped -- NOT recreating (would destroy ceph data). Inspect it, or 'virsh destroy/undefine' it by hand to force a rebuild."
      fi
      return 0
    fi
    warn "ceph VM ${CEPH_NODE_NAME} exists but is unusable (state=${domstate}, unreachable) and ceph is not bootstrapped; rebuilding it"
  fi

  # Render the NoCloud seed inputs locally (correct filenames for the ISO), then
  # ship them to the host and build the ISO there.
  cat > "${dir}/meta-data" <<EOF
instance-id: ${CEPH_NODE_NAME}
local-hostname: ${CEPH_HOST}
EOF
  # Minimal cloud-init: identity + SSH key only. Packages are installed later by
  # odf_ceph_bootstrap over SSH (with retries + visible errors) rather than here,
  # so we don't depend on a working dnf mirror at first boot and don't race
  # cloud-init's dnf against ours for the RPM lock.
  cat > "${dir}/user-data" <<EOF
#cloud-config
hostname: ${CEPH_HOST}
fqdn: ${CEPH_HOST}.${BASE_DOMAIN}
ssh_pwauth: false
ssh_authorized_keys:
  - ${pubkey}
EOF
  chmod 600 "${dir}/user-data"
  # Static IP via cloud-init (matched by MAC, so the NIC name doesn't matter).
  # This is what pins the VM to CEPH_IP -- we do NOT rely on the libvirt DHCP
  # reservation, which host_libvirt_network only writes when it first defines
  # the network (a network that predates ODF would never get the .10 entry, and
  # restarting it to add one would disrupt the running cluster nodes).
  cat > "${dir}/network-config" <<EOF
version: 2
ethernets:
  ceph0:
    match:
      macaddress: "${CEPH_MAC}"
    set-name: ceph0
    dhcp4: false
    addresses:
      - ${CEPH_IP}/24
    routes:
      - to: default
        via: ${NET_GATEWAY}
    nameservers:
      addresses:
        - ${NET_GATEWAY}
EOF

  log "Defining external-Ceph VM ${CEPH_NODE_NAME} (${CEPH_VCPU} vCPU, ${CEPH_RAM_GB} GB, ${CEPH_OSD_COUNT}x${CEPH_OSD_DISK_GB} GB OSD disks)"
  ssh_host "mkdir -p ${seeddir}"
  scp_to "${dir}/user-data"      "${seeddir}/user-data"
  scp_to "${dir}/meta-data"      "${seeddir}/meta-data"
  scp_to "${dir}/network-config" "${seeddir}/network-config"

  ssh_host "sudo bash -s" <<EOS
set -euo pipefail
# We only get here to (re)build. Drop any leftover definition and rebuild a FRESH
# root + seed so cloud-init re-runs and applies the current config; OSD data disks
# are left in place (blank until ceph consumes them). Harmless if nothing exists.
virsh destroy '${CEPH_NODE_NAME}' 2>/dev/null || true
virsh undefine '${CEPH_NODE_NAME}' 2>/dev/null || true
rm -f '${root}' '${seed}'
# CentOS-Stream GenericCloud base image (cached once; reused as a COW backing file).
if [[ ! -f '${base}' ]]; then
  curl -fsSL '${CEPH_CLOUD_IMAGE_URL}' -o '${base}.tmp'
  mv '${base}.tmp' '${base}'
fi
# Root (COW off base) + one blank data disk per OSD. Created only if missing so a
# retry reuses what a previous attempt already built.
[[ -f '${root}' ]] || qemu-img create -f qcow2 -F qcow2 -b '${base}' '${root}' ${CEPH_ROOT_DISK_GB}G >/dev/null
for dev in ${osd_devs}; do
  f="/var/lib/libvirt/images/${CEPH_NODE_NAME}-\${dev}.qcow2"
  [[ -f "\$f" ]] || qemu-img create -f qcow2 "\$f" ${CEPH_OSD_DISK_GB}G >/dev/null
done
# Build the NoCloud seed (label 'cidata'; user-data + meta-data + network-config).
genisoimage -quiet -output '${seed}' -volid cidata -joliet -rock \
  ${seeddir}/user-data ${seeddir}/meta-data ${seeddir}/network-config
# Import the cloud image (BIOS boot; no UEFI override) with the OSD disks and the
# seed cdrom. print-xml/define/start mirrors vms.sh, but every referenced file
# (root, OSD disks, seed ISO) is persistent, so 'virsh start' won't miss media.
virt-install \
  --name '${CEPH_NODE_NAME}' \
  --memory ${ram_mb} \
  --vcpus ${CEPH_VCPU} \
  --cpu host-passthrough \
  --os-variant centos-stream9 \
  --disk path='${root}',bus=virtio${osd_disks} \
  --disk path='${seed}',device=cdrom \
  --network network=${LIBVIRT_NET},mac='${CEPH_MAC}',model=virtio \
  --graphics none --noautoconsole --import --print-xml 1 > /tmp/${CEPH_NODE_NAME}.xml
virsh define /tmp/${CEPH_NODE_NAME}.xml >/dev/null
virsh start '${CEPH_NODE_NAME}' >/dev/null
echo "ceph VM defined + started"
EOS
  ok "External-Ceph VM ${CEPH_NODE_NAME} defined and booting"
  # ITERATE: os-variant (centos-stream9) and the cloud image's default user
  # (CEPH_SSH_USER=cloud-user) must match CEPH_CLOUD_IMAGE_URL; verify on first run.
}

# Bootstrap a single-host Ceph cluster and carve out the RBD data pool. Runs on
# the ceph VM (via _ssh_ceph). Fully CONVERGENT/idempotent: the cephadm bootstrap
# itself runs only if ceph isn't already up (never re-bootstraps a live cluster),
# but the OSD/pool/prometheus steps run every time and are VERIFIED -- a missing
# pool or absent OSDs is fatal, so we never print a false "Ceph up". The
# ceph_bootstrapped marker is set only after that verification passes.
odf_ceph_bootstrap() {
  [[ "${CEPH_ENABLED}" == "true" ]] || return 0
  _ceph_wait_ssh
  # PGs for a small single-pool lab; the autoscaler tunes from here.
  local pgnum=64
  log "Bootstrapping single-host Ceph on ${CEPH_IP} and adding ${CEPH_OSD_COUNT} OSDs"
  _ssh_ceph "sudo bash -s" <<EOS
set -euo pipefail
# cephadm's host prerequisites. Installed here (not via cloud-init) with retries
# and VISIBLE errors, so a first-boot dnf/mirror problem is reported plainly
# instead of hiding as an "unreachable" timeout. chrony is needed for the time
# sync ceph requires; jq is used below to poll OSD state.
if ! command -v podman >/dev/null 2>&1; then
  ok=""
  for attempt in 1 2 3; do
    if dnf install -y podman lvm2 chrony python3 jq; then ok=1; break; fi
    echo "dnf install attempt \${attempt} failed; retrying in 15s..." >&2
    sleep 15
  done
  if [[ -z "\$ok" ]]; then
    echo "ERROR: could not install podman/prereqs on the ceph VM. Check its" >&2
    echo "outbound internet / DNS (dnf must reach the CentOS mirrors)." >&2
    exit 1
  fi
fi
systemctl enable --now chronyd 2>/dev/null || true
# Install cephadm from the CentOS Storage SIG, RELEASE-SPECIFIC package so the
# cephadm binary matches the ${CEPH_RELEASE} container image the cluster runs
# (the release-agnostic 'umbrella' package can hand back a dev cephadm/image ODF
# can't parse). Resolve cephadm's ABSOLUTE path via 'command -v' and always call
# it that way -- under 'sudo bash' /usr/sbin/usr/local/bin may be off PATH, which
# is what caused "cephadm: command not found".
CEPHADM="\$(command -v cephadm || true)"
if [[ -z "\$CEPHADM" ]]; then
  dnf install -y 'centos-release-ceph-${CEPH_RELEASE}' >/dev/null 2>&1 || true
  dnf install -y cephadm >/dev/null 2>&1 || true
  CEPHADM="\$(command -v cephadm || true)"
fi
[[ -n "\$CEPHADM" && -x "\$CEPHADM" ]] || { echo "ERROR: could not install cephadm (dnf install centos-release-ceph-${CEPH_RELEASE} + cephadm, from extras-common / the CentOS Storage SIG). Check the ceph VM's internet/DNS and the release name '${CEPH_RELEASE}'." >&2; exit 1; }
echo "using cephadm at \$CEPHADM"
# --single-host-defaults sets the CRUSH failure domain to OSD so a replicated
# pool of size ${CEPH_POOL_REPLICA} places all copies on this one host's OSDs.
# --image pins the ${CEPH_RELEASE} ceph image (matches the cephadm we installed),
# so the running ceph's mgr-dump format is one ODF's rook can parse.
if ! "\$CEPHADM" shell -- ceph -s </dev/null >/dev/null 2>&1; then
  "\$CEPHADM" ${CEPH_IMAGE:+--image '${CEPH_IMAGE}'} bootstrap \
    --mon-ip '${CEPH_IP}' \
    --single-host-defaults \
    --allow-fqdn-hostname \
    --skip-dashboard \
    --skip-monitoring-stack \
    --allow-overwrite </dev/null
fi
# CRITICAL: </dev/null on every cephadm shell. cephadm shell reads stdin, and this
# whole script is fed to 'sudo bash -s' ON stdin -- without the redirect the first
# cephadm shell swallows the rest of the script, bash hits EOF and exits 0, and
# pool creation/verification silently never run (false "Ceph up").
CEPH() { "\$CEPHADM" shell -- "\$@" </dev/null; }
# One OSD per blank data disk. --all-available-devices consumes every unused
# device on the host (exactly our ${CEPH_OSD_COUNT} blank virtio disks; the root
# disk has a filesystem and is skipped), so there's no hostname:device coupling.
# One OSD per blank data disk. --all-available-devices consumes every unused
# device on the host (exactly our ${CEPH_OSD_COUNT} blank virtio disks; the root
# disk has a filesystem and is skipped), so there's no hostname:device coupling.
CEPH ceph orch apply osd --all-available-devices || true
# Wait for the OSDs to come up (up to ~10m; cephadm provisions them async).
for i in \$(seq 1 60); do
  up=\$(CEPH ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds' 2>/dev/null || echo 0)
  [[ "\${up}" -ge ${CEPH_OSD_COUNT} ]] && break
  sleep 10
done
up=\$(CEPH ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds' 2>/dev/null || echo 0)
[[ "\${up}" -ge ${CEPH_OSD_COUNT} ]] || { echo "ERROR: only \${up}/${CEPH_OSD_COUNT} OSDs are up; check 'ceph orch device ls' / 'ceph -s' on the ceph VM." >&2; exit 1; }
# Replicated RBD data pool for ODF external. size=${CEPH_POOL_REPLICA} -> usable
# = raw/${CEPH_POOL_REPLICA}; the OSD disks are sized so MAX AVAIL >= ${CEPH_POOL_USABLE_GB} GB.
# 'pool create' tolerates "already exists" (|| true) but we VERIFY existence below
# and fail hard if it's really missing -- retrying, since the mgr can be briefly
# unready right after bootstrap.
for i in 1 2 3; do
  CEPH ceph osd pool create '${CEPH_RBD_POOL}' ${pgnum} ${pgnum} replicated 2>&1 || true
  CEPH ceph osd pool ls 2>/dev/null | grep -qx '${CEPH_RBD_POOL}' && break
  echo "pool ${CEPH_RBD_POOL} not present yet (attempt \${i}); retrying..." >&2
  sleep 10
done
CEPH ceph osd pool ls | grep -qx '${CEPH_RBD_POOL}' || { echo "ERROR: RBD pool '${CEPH_RBD_POOL}' could not be created (see errors above)." >&2; exit 1; }
CEPH ceph osd pool set '${CEPH_RBD_POOL}' size ${CEPH_POOL_REPLICA}
CEPH ceph osd pool set '${CEPH_RBD_POOL}' min_size 2
CEPH ceph osd pool application enable '${CEPH_RBD_POOL}' rbd 2>&1 || true
CEPH rbd pool init '${CEPH_RBD_POOL}'
# Enable ceph-mgr's prometheus module (port 9283) -- the external-details
# exporter requires it to record ODF's monitoring endpoint. Verify it registers.
CEPH ceph mgr module enable prometheus
for i in \$(seq 1 18); do
  CEPH ceph mgr services 2>/dev/null | grep -q prometheus && break
  sleep 5
done
CEPH ceph mgr services 2>/dev/null | grep -q prometheus || echo "WARN: prometheus mgr endpoint not reported yet; the exporter may retry." >&2
echo "--- ceph status ---"; CEPH ceph -s || true
echo "--- pool usable (MAX AVAIL) ---"; CEPH ceph df detail || true
EOS
  state_set ceph_bootstrapped yes
  ok "Ceph up; RBD pool '${CEPH_RBD_POOL}' (replica ${CEPH_POOL_REPLICA}) verified, sized for ~${CEPH_POOL_USABLE_GB} GB usable"
}

# Run the external-cluster-details exporter on the ceph VM and capture its JSON.
# This is the same script the OCP console tells you to run on the external Ceph;
# it creates the least-privilege client keyrings and prints the connection JSON
# (mon endpoints, fsid, csi user keys, monitoring endpoint) to stdout.
#
# Fetch the rook exporter to the VM, then run it INSIDE cephadm shell (which has
# the ceph CLI + rados/rbd bindings + admin keyring) by PIPING it over stdin
# (python3 -). We do NOT use `cephadm shell --mount`: file mounts aren't reliable
# across cephadm builds and mis-parsing --mount made cephadm report "no container
# engine binary found". JSON goes to stdout (-> $out); the script's own
# diagnostics go to stderr, which we CAPTURE and surface on failure so this can
# never fail blind again.
odf_ceph_export() {
  [[ "${CEPH_ENABLED}" == "true" ]] || return 0
  local out="${CLUSTER_DIR}/ceph-external.json"
  local err; err="$(mktemp "${TMPDIR:-/tmp}/rhwa-lab.XXXXXX")"
  log "Exporting external Ceph connection details (rbd pool ${CEPH_RBD_POOL})"
  _ssh_ceph "sudo bash -s" >"${out}" 2>"${err}" <<EOS
set -euo pipefail
CEPHADM="\$(command -v cephadm)"
curl -fsSL '${CEPH_EXPORTER_URL}' -o /tmp/exporter.py
[[ -s /tmp/exporter.py ]] || { echo "ERROR: failed to download the exporter from ${CEPH_EXPORTER_URL}" >&2; exit 1; }
"\$CEPHADM" shell -- python3 - \
  --rbd-data-pool-name '${CEPH_RBD_POOL}' \
  --namespace '${ODF_NAMESPACE}' \
  --monitoring-endpoint '${CEPH_IP}' \
  --monitoring-endpoint-port 9283 \
  --format json < /tmp/exporter.py
EOS
  if ! jq -e 'type == "array" and length > 0' "${out}" >/dev/null 2>&1; then
    warn "external Ceph exporter did not produce a JSON array; its stderr was:"
    sed 's/^/    /' "${err}" >&2 || true
    rm -f "${err}"
    die "external Ceph export failed (captured output: ${out})"
  fi
  rm -f "${err}"
  chmod 600 "${out}"
  ok "External Ceph details captured ($(jq 'length' "${out}") items -> ${out})"
  # ITERATE: the exporter's flag names / output shape move between rook/ODF
  # versions; CEPH_EXPORTER_URL pins the source.
}

# Install the ODF operator from the Red Hat catalog via OLM (AllNamespaces via
# the standard openshift-storage OperatorGroup that ODF ships with).
odf_install_operator() {
  log "Installing ODF operator (channel ${ODF_CHANNEL}) into ${ODF_NAMESPACE}"
  oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ODF_NAMESPACE}
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage-operatorgroup
  namespace: ${ODF_NAMESPACE}
spec:
  targetNamespaces:
  - ${ODF_NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: odf-operator
  namespace: ${ODF_NAMESPACE}
spec:
  channel: ${ODF_CHANNEL}
  name: odf-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
  _odf_wait_csv "odf-operator" || true
  _odf_wait_csv "ocs-operator" || true
}

# Wait for a CSV whose name starts with <prefix> to reach Succeeded (mirror of
# rhwa.sh's _wait_csv, scoped to the ODF namespace).
_odf_wait_csv() {
  local prefix="$1" i phase
  for ((i=0; i<60; i++)); do
    phase="$(oc -n "${ODF_NAMESPACE}" get csv -o json 2>/dev/null \
      | jq -r --arg p "$prefix" '.items[] | select(.metadata.name|startswith($p)) | .status.phase' \
      | head -1)"
    [[ "$phase" == "Succeeded" ]] && { ok "CSV ${prefix}* Succeeded"; return 0; }
    sleep 15
  done
  warn "CSV ${prefix}* did not reach Succeeded (last: ${phase:-none})"
  return 1
}

# Import the exporter JSON the way the OCP console does for EXTERNAL mode, which
# requires BOTH:
#   (a) the individual rook-ceph-* objects from the exporter array -- each
#       {kind:Secret} as a Secret, each {kind:ConfigMap} as a ConfigMap. The
#       rook-ceph-mon-endpoints ConfigMap in particular is NOT recreated by
#       ocs-operator, and without it rook has no mon address -> the StorageCluster
#       hangs on "waiting for Ceph FSID".
#   (b) the single rook-ceph-external-cluster-details blob secret
#       (external_cluster_details = base64 of the whole JSON array) that the
#       StorageCluster's external controller ingests. Its absence blocks the
#       StorageCluster on "missing secret rook-ceph-external-cluster-details".
# Creating only one of the two leaves the operator stuck in one of those states.
odf_import_external() {
  [[ "${CEPH_ENABLED}" == "true" ]] || return 0
  local raw="${CLUSTER_DIR}/ceph-external.json"
  [[ -s "${raw}" ]] || die "no external Ceph details at ${raw}; run odf_ceph_export first"
  jq -e 'type == "array" and length > 0' "${raw}" >/dev/null 2>&1 \
    || die "external Ceph details at ${raw} are not a non-empty JSON array"

  # NORMALIZE the exporter output before import. The rook exporter emits each
  # StorageClass secret ref as a bare '*-secret-name' with NO '*-secret-namespace'.
  # ocs-operator auto-namespaces only the classic secrets (provisioner /
  # controller-expand / node-stage) and passes newer ones (controller-modify /
  # node-publish) through name-only, so the StorageClass it generates is invalid
  # ("either name and namespace for ... secrets specified, Both must be specified")
  # and no RBD PVC (incl. NooBaa's DB) can provision. Add the matching
  # '*-secret-namespace' (=ODF_NAMESPACE) for EVERY '*-secret-name' so the SC ODF
  # generates from these details is complete. This is the permanent fix -- ODF
  # regenerates the SC from this data, so it can't be undone by editing the SC.
  local src; src="$(mktemp "${TMPDIR:-/tmp}/rhwa-lab.XXXXXX")"
  jq --arg ns "${ODF_NAMESPACE}" '
    map(if .kind=="StorageClass" and (.data|type=="object") then
          .data += ( .data | to_entries
                     | map(select(.key|endswith("-secret-name")))
                     | map({ key:(.key|sub("-secret-name$";"-secret-namespace")), value:$ns })
                     | from_entries )
        else . end)
  ' "${raw}" > "${src}"
  jq -e 'type=="array" and length>0' "${src}" >/dev/null 2>&1 \
    || { rm -f "${src}"; die "failed to normalize external Ceph details from ${raw}"; }

  log "Importing external Ceph details into ${ODF_NAMESPACE} (rook-ceph-* objects + blob secret)"
  # (a) the individual Secret/ConfigMap objects the exporter emitted.
  jq --arg ns "${ODF_NAMESPACE}" '
    {apiVersion:"v1", kind:"List", items:[
      .[] |
      if .kind=="Secret" then
        {apiVersion:"v1", kind:"Secret",
         metadata:{name:.name, namespace:$ns},
         stringData:(.data|map_values(tostring))}
      elif .kind=="ConfigMap" then
        {apiVersion:"v1", kind:"ConfigMap",
         metadata:{name:.name, namespace:$ns},
         data:(.data|map_values(tostring))}
      else empty end
    ]}' "${src}" | oc apply -f -
  # (b) the blob secret. .data values are base64, so base64(JSON) -> operator decodes it.
  # `base64 | tr -d '\n'` is portable (GNU wraps at 76 by default; macOS/BSD
  # base64 has no `-w0`), giving one unwrapped line on both.
  local b64; b64="$(base64 "${src}" | tr -d '\n')"
  oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rook-ceph-external-cluster-details
  namespace: ${ODF_NAMESPACE}
type: Opaque
data:
  external_cluster_details: ${b64}
EOF
  rm -f "${src}"
  ok "External Ceph details imported (secret namespaces normalized; objects + blob)"
}

# Create the external-mode StorageCluster. With the imported details present,
# ocs-operator connects rook to the external Ceph and creates the ceph-rbd
# StorageClass (ocs-external-storagecluster-ceph-rbd) automatically.
odf_create_storagecluster() {
  log "Creating external-mode StorageCluster in ${ODF_NAMESPACE}"
  oc apply -f - <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-external-storagecluster
  namespace: ${ODF_NAMESPACE}
spec:
  externalStorage:
    enable: true
  labelSelector: {}
EOF
  # Wait for the StorageCluster to report Ready (external connection established).
  local i phase
  for ((i=0; i<60; i++)); do
    phase="$(oc -n "${ODF_NAMESPACE}" get storagecluster ocs-external-storagecluster \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Ready" ]] && { ok "StorageCluster Ready (external Ceph connected)"; return 0; }
    sleep 20
  done
  warn "StorageCluster not Ready yet (last phase: ${phase:-none}); check 'oc -n ${ODF_NAMESPACE} describe storagecluster'"
  return 1
}

# Orchestrate the whole ODF-external feature. No-op when ODF_ENABLED=false.
odf_setup() {
  [[ "${ODF_ENABLED}" == "true" ]] || { log "ODF_ENABLED=false; skipping ODF/Ceph setup"; return 0; }
  log "Setting up ODF (external) backed by single-host Ceph"
  odf_ceph_define_vm
  odf_ceph_bootstrap
  odf_ceph_export
  odf_install_operator
  odf_import_external
  odf_create_storagecluster
  ok "ODF external + Ceph setup complete"
}
