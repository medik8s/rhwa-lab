# rhwa-lab

Scripted, disposable lab for testing **Red Hat Workload Availability (RHWA)**
node remediation — the **Fence Agents Remediation (FAR)** operator driven by
**NodeHealthCheck (NHC)** using the **`fence_redfish`** fence agent — against
emulated BMCs, with no physical hardware.

It runs a "bare metal" OpenShift cluster as libvirt VMs on a single
nested-virtualization-capable AWS `m8i` instance, with
[sushy-tools](https://github.com/openstack/sushy-tools) providing an emulated
Redfish BMC per VM.

## Status

**First-draft implementation — not yet run end-to-end.** Bash syntax passes;
no live AWS test has been performed. Expect to iterate. Design spec:
[`docs/superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md`](docs/superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md).

## Prerequisites (your machine)

Runs on **Linux or macOS** (Intel or Apple Silicon). Needs `bash`, `aws` CLI
v2, `jq`, `curl`, `ssh`/`scp`, `tar`, `openssl`, `base64` (all present by
default on both) and an SSH keypair (`~/.ssh/id_rsa[.pub]` by default).
`oc`/`openshift-install` are downloaded automatically — the local `oc` matches
your OS/arch. No GNU coreutils required; macOS's stock `bash` 3.2 is fine.
An AWS account allowed to manage EC2/EIP/Route53 with enough On-Demand vCPU
quota (~48). A Red Hat pull secret with Red Hat registry entitlement.

> The lab still provisions a **Linux** EC2 host and Linux guest VMs; only the
> control CLI you run locally is cross-platform.

## Usage

```bash
# All inputs come from environment variables (no config/secrets file).
export ODF_ENABLED=false # optional. ODF is enabled by default
export OCP_VERSION=stable-4.22 # optional. Can be any OCP Release https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/ stable-4.22, 5.0.0-rc.1, etc.
export ROUTE53_ZONE_ID=
export CLUSTER_NAME=
export SSH_PUBLIC_KEY_FILE=
export PULL_SECRET=
export AWS_REGION=
export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=

Usage:
  ./rhwa-lab create     Provision everything end-to-end
  ./rhwa-lab monitor    Live, phase-aware install progress (safe any time)
  ./rhwa-lab test       Trigger + verify a fence_redfish remediation
  ./rhwa-lab status     Show endpoints, credentials, uptime
  ./rhwa-lab install-config  Print a sanitized install-config.yaml (no secrets)
  ./rhwa-lab allow [IP]  Allow another IP (or 'all') through the firewall
  ./rhwa-lab power <on|off|reset> <node>  Out-of-band power via ssh->virsh
  ./rhwa-lab vms-definitions   Print node->domain/host JSON for test power control
  ./rhwa-lab destroy    Tear everything down (incl. Route53 records)
  ./rhwa-lab help       Show this help
```

### Spare workers (for post-install tests)

`create` also defines `SPARE_WORKER_COUNT` (default **3**) extra worker VM(s)
that are **not** part of the install: excluded from install-config/agent-config
and never booted during `create`. They continue the worker numbering (with
`WORKER_COUNT=3` the spares are `worker-3`, `worker-4`, `worker-5`) — there is no
`-spare-` name prefix; "spare" just means an unconsumed `available` host. Each
gets its sushy-tools Redfish BMC plus a
provisionable, metal3-managed `BareMetalHost` in `openshift-machine-api`
(`bmc.address`/credentials set, `rootDeviceHints: /dev/vda`, **not**
externallyProvisioned) that metal3 inspects and leaves **`available`** — an
unconsumed host ready to be provisioned. To use one in a test, scale the
baremetal MachineSet up; metal3 consumes an `available` BMH and provisions it:

```bash
oc -n openshift-machine-api scale machineset <machineset> --replicas=<n>
# metal3 picks up an available BMH and provisions it onto the new Machine
```

Set `SPARE_WORKER_COUNT=0` to disable. Spares still add ~4 vCPU each *only when
provisioned* by a test.

### Reprovisionable workers

Workers are born **metal3-managed and reprovisionable**: their BMHs are created
provisionable (not externallyProvisioned) with `rootDeviceHints: /dev/vda` (the
virtio root disk; metal3 defaults to `/dev/sda`, which is absent on virtio). The
install brings up the control plane with `compute.replicas: 0`; `create` then
scales the baremetal MachineSet up to `WORKER_COUNT`, and metal3 provisions the
worker BMHs onto Machines. This means a test can delete a worker Machine (or use
MDR) and have metal3 reprovision it. Masters are **never** reprovisioned — a
master BMH stays `externallyProvisioned: true` with BMC only.

### Out-of-band power control

`./rhwa-lab power <on|off|reset> <node>` power-cycles a node's VM over an
out-of-band channel (ssh → EC2 host → `virsh`), independent of the cluster API,
so it survives quorum loss (e.g. powering off multiple control-plane nodes in a
test). `<node>` is the node hostname.

### VM definitions for the test suite

`./rhwa-lab vms-definitions` prints `vms_definitions.json` (node → libvirt
domain/host mapping) to stdout, which the test suite consumes to drive power
control against the lab VMs.

`create` is resumable-ish: it records AWS resource IDs to `state/<cluster>.state`
as it goes, so `destroy` always cleans up what was created even after a partial
run. The agent ISO is built **exactly once** per lab (`agent_image_built` marker)
because rebuilding regenerates the cluster's certs — see rough edge #7.

### OpenShift Data Foundation (external Ceph)

`create` also stands up **OpenShift Data Foundation (ODF) in external mode**,
backed by a single-node **Ceph** cluster (`lib/odf.sh`). Enabled by default; set
`ODF_ENABLED=false` to skip the whole feature.

An extra libvirt VM (`<cluster>-ceph-0`, IP `192.168.126.10`, a CentOS-Stream
cloud image) is created on the same `rhwa` network as the cluster — it is **not**
an OpenShift node (no BMH, no fencing, not in `compute_nodes`). It gets
`CEPH_OSD_COUNT` (default **3**) blank virtio data disks; `cephadm bootstrap
--single-host-defaults` brings up a one-host Ceph and adds **one OSD per disk**.
A replicated RBD pool (`CEPH_RBD_POOL`, default `ocs-storagepool`) is created at
`size = CEPH_POOL_REPLICA` (default **3**), and `--single-host-defaults` sets the
CRUSH failure domain to OSD so all replicas fit on the one host.

**200 GB usable:** with a replicated pool, `usable ≈ raw / replica`. The per-OSD
disk size is *derived* from the target so the pool's `MAX AVAIL` clears it:

```
CEPH_OSD_DISK_GB = CEPH_POOL_USABLE_GB * CEPH_POOL_REPLICA / CEPH_OSD_COUNT * 1.18
                 = 200 * 3 / 3 * 1.18  ≈  236 GB per disk   (3 disks = 708 GB raw)
```

The ×1.18 is headroom for Ceph's full-ratio (~0.95) + BlueStore overhead, so
`MAX AVAIL` on the pool lands comfortably above 200 GB. Because the qcow2 OSD
files are sparse, `EC2_VOLUME_SIZE_GB` is bumped by the raw OSD footprint
(`1000 + 3×236 ≈ 1708 GB` by default) so the host disk can actually hold a full
pool; nothing is consumed up front. Override any of `CEPH_OSD_COUNT`,
`CEPH_POOL_REPLICA`, `CEPH_POOL_USABLE_GB`, or `CEPH_OSD_DISK_GB` to resize.

ODF itself is the `odf-operator` from the Red Hat catalog (channel `ODF_CHANNEL`,
derived from `OCP_VERSION`) in `openshift-storage`. The external Ceph connection
is wired the same way the OCP console does it: the
`ceph-external-cluster-details-exporter.py` script runs on the Ceph VM and emits
the connection JSON (mons, fsid, CSI keys, monitoring endpoint), which `create`
materializes as the `rook-ceph-*` Secrets/ConfigMaps and then creates an
external-mode `StorageCluster` (`ocs-external-storagecluster`). ODF then creates
the `ocs-external-storagecluster-ceph-rbd` StorageClass automatically.

`destroy` removes the Ceph VM (and its OSD disks) with the instance, like every
other domain.

### Watching the install

`create` prints live, phase-aware progress and blocks until the cluster is up.
`./rhwa-lab monitor` shows the same view on demand. It reads ground truth from a
master node's recovery kubeconfig (booted-node count → control-plane rollout
revisions → clusterversion/operators/nodes), so it stays informative even during
the window where `openshift-install`'s own log is stuck on "Agent Rest API never
initialized. Bootstrap Kube API never initialized" (that message is expected: the
agent REST API has shut down and the admin kubeconfig isn't accepted yet).

## Known rough edges (search the code for `# ITERATE:`)

These are the spots most likely to need a fix on the first real run:

1. **Nested-virt L2 performance** on `m8i.12xlarge` — installs may be slow;
   bump `INSTANCE_TYPE` (incl. `m8i.metal-*`) if flaky.
2. **RHCOS NIC name** — agent-config assumes `enp1s0`; may differ by machine
   type (nmstate matches by MAC as a hedge).
3. **cdrom target dev** for the agent ISO in libvirt (`sda` vs `hda`).
4. **`fence_redfish` valueless flags** — `--ssl-insecure` is passed with an
   empty value; FAR's parameter handling may need adjustment (check FAR pod
   logs during `test`).
5. **Operator package names/channels** in the Red Hat catalog
   (`node-healthcheck-operator`, `fence-agents-remediation`,
   `self-node-remediation`, `node-maintenance-operator`, channel `stable`).
8. **BareMetalHost BMC wiring** — each node's BMH is populated with its
   sushy-tools `bmc.address` (`redfish-virtualmedia://…`) + credentials Secret,
   so metal3/ironic power-manages it in addition to FAR. Both drive the same
   Redfish endpoint; if you see unexpected power actions, this is the place to
   look. Masters keep `externallyProvisioned: true` (BMC only — never
   `bootMACAddress`/`rootDeviceHints`) so ironic power-manages but never
   re-provisions the running control plane; workers/spares are born
   provisionable (see "Reprovisionable workers" below). The virtual-media driver
   needs UEFI + a cdrom (both present). `SUSHY_EMULATOR_IGNORE_BOOT_DEVICE=False`
   is required so ironic's per-device boot override is honored during
   provisioning. Fencing stays safe because existing nodes boot disk first (boot
   order 1) and `fence_redfish` sends `ForceRestart` with **no** boot-device
   override, so a fence reboot returns to disk, not to the attached media.
6. **Host distro** — the EC2 host runs **Fedora Cloud Base** (owner
   `125523088429`, release `FEDORA_RELEASE`, default 44), which ships the full
   virtualization stack; AL2023 does not. Override the image with `HOST_AMI`
   (and set `HOST_SSH_USER` to that image's default cloud user).
7. **Agent ISO is built once (cert generation)** — every `openshift-install
   agent create image` mints a *fresh* set of cluster certs, and `work/auth/`
   holds the only copy of the matching kubeconfig + kubeadmin password.
   Rebuilding after the nodes have booted orphans those credentials (`oc` gets
   "must provide credentials"; `openshift-install wait-for` hangs on its own
   dead kubeconfig). `os_build_image` therefore builds once and reuses; to
   rebuild, `destroy` and `create` again. As a safety net, `os_wait_install`
   verifies the fetched kubeconfig actually authenticates and, if not, recovers
   a working cluster-admin kubeconfig from a master's recovery kubeconfig.
9. **ODF operator channel** — `ODF_CHANNEL` is derived from `OCP_VERSION`
   (`stable-4.NN`). Confirm that channel actually exists for the `odf-operator`
   package in the redhat-operators catalog on your cluster; ODF channels can lag
   the OCP release. Override `ODF_CHANNEL` if needed.
10. **External-details exporter** (`lib/odf.sh`) — the path of
   `ceph-external-cluster-details-exporter.py` inside the Ceph container and its
   exact flag names move between ceph/ODF versions; `odf_ceph_export` tries a
   couple of in-container paths and falls back to the upstream rook script. The
   `odf_import_external` jq mapping mirrors the OCP console's importer (every
   `Secret`/`ConfigMap` element → that object in `openshift-storage`); a newer
   ODF that expects extra objects would need the mapping extended.
11. **Ceph VM cloud image** — `CEPH_CLOUD_IMAGE_URL` (CentOS-Stream GenericCloud)
   and `CEPH_SSH_USER` (`cloud-user`) must match; `--os-variant centos-stream9`
   likewise. cephadm is installed from the CentOS Storage SIG **release-specific**
   package (`centos-release-ceph-${CEPH_RELEASE}`, default `squid`, in
   `extras-common`) so the cephadm binary matches the `CEPH_IMAGE` it bootstraps
   (both derived from `CEPH_RELEASE`: `squid`→`v19`, `reef`→`v18`, …). The VM
   needs outbound internet (it has it via the host bridge). **Do not use the
   release-agnostic `centos-release-ceph-umbrella` package** — it can hand back a
   *development* cephadm whose default image is a dev/tip ceph, and ODF's rook
   then can't parse its `mgr dump` (`cannot unmarshal … mgr.map.standbys`). Set
   `CEPH_RELEASE` to the ceph version your ODF release supports.
