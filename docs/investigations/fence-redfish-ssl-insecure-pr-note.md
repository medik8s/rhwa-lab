# PR note: fencing test fails because `--ssl-insecure` has a value

Observed on 2026-09-24 in `jmatthews-rhwa-lab`. This note preserves the
incident, the evidence gathered from the cluster and upstream code, and the
proposed change for a future issue and PR. Times below are America/New_York
unless marked UTC.

## Problem and impact

`./rhwa-lab test` stopped kubelet on `worker-0` and detected that the node was
unhealthy. NodeHealthCheck (NHC) created a `FenceAgentsRemediation` (FAR)
resource, but FAR could not execute `fence_redfish`: the agent rejected
`--ssl-insecure=1` as an invalid argument. The worker did not reboot or return
Ready, and the test failed. Because the test stopped kubelet, a failed fence
also left the target worker needing recovery before another test.

The user-visible output was:

```text
[08:30:31] Fencing test target: worker-0
[08:30:31] Current bootID: aa69b504-2029-4986-964f-cb3afb56dd68
[08:30:31] Inducing unhealth: stopping kubelet on worker-0
[08:45:32] Waiting for worker-0 to go NotReady...
[08:45:32] ✓ worker-0 is NotReady
[08:45:34] ✓ FenceAgentsRemediation created: worker-0-652xz
[08:55:57] ! Node did not confirm reboot+recovery in time. Diagnostics:
--- FAR pods ---
--- FAR operator logs (tail) ---
--- sushy-tools logs (tail) ---
[08:55:59] ✗ Fencing test did not complete successfully.
```

The 15-minute gap after "Inducing unhealth" was a separate test-harness
problem. The version of [the test script](../lib/testfence.sh) used for this
run invoked `oc debug node/worker-0` and stopped kubelet inside its debug pod.
Stopping kubelet also prevented that debug pod from completing normally, so
the local `oc debug` call waited until it timed out. FAR had already attempted
and failed fencing at **08:32:35–08:32:55**, before the local script resumed
at 08:45. The delay was not a 15-minute `fence_redfish` operation.

## Environment and execution path

The lab runs OpenShift VMs under libvirt on a Fedora EC2 host. `sushy-tools`
runs in a Podman container on that host and exposes the VMs through an HTTPS
Redfish endpoint at `192.168.126.1:8000`; the lab generates a self-signed
certificate for it. See [VM and sushy setup](../lib/vms.sh) and the
[lab design](superpowers/specs/2026-08-19-rhwa-redfish-lab-design.md).

The [fencing configuration](../lib/rhwa.sh) creates a
`FenceAgentsRemediationTemplate` with `agent: fence_redfish`, endpoint and
credential parameters, `--ssl-insecure`, and a per-node `--systems-uri`. It
also creates an NHC that watches worker Ready conditions and points to that
template. The expected sequence is:

```text
./rhwa-lab test on the user's Mac
  -> stop kubelet on worker-0
  -> NHC observes worker-0 NotReady and creates FAR worker-0-652xz
  -> FAR controller pod runs fence_redfish for worker-0
  -> fence_redfish calls sushy-tools over HTTPS
  -> sushy-tools resets the libvirt VM
  -> worker-0 gets a new boot ID and becomes Ready
```

The `fence_redfish` process runs **inside the FAR controller container**, not
on the Mac, `worker-0`, or the EC2 host. The pod that logged this failure was
`fence-agents-remediation-controller-manager-f7849fc9d-vvhgm` in namespace
`openshift-workload-availability`, scheduled on `master-2`. FAR upstream code
constructs the command from the FAR parameters, calls its asynchronous
executor, and uses Go's `exec.CommandContext` to run it in the container.
See the [FAR controller](https://github.com/medik8s/fence-agents-remediation/blob/main/internal/controller/fenceagentsremediation_controller.go)
and [CLI executor](https://github.com/medik8s/fence-agents-remediation/blob/main/pkg/cli/cliexecuter.go).
FAR's [README](https://github.com/medik8s/fence-agents-remediation#how-does-far-work)
also describes NHC creating a FAR resource and FAR running the fence agent.

## Why an earlier run worked

The local Git history identifies a regression, rather than a macOS-specific
fence-agent behavior:

- Commit `64683379` (2026-08-21) records a successful end-to-end
  `fence_redfish` remediation: `worker-0` rebooted through sushy-tools and FAR
  logged `Success: Rebooted`. At that commit, the template supplied
  `"--ssl-insecure": ""`.
- Commit `c1ef0ec6` (2026-08-25, "Harden security and reliability") changed
  that value from `""` to `"1"`. Its commit message says this was intended to
  make the agent disable certificate verification, but the option actually
  takes no value. The change was merged in PR #1 (`1ba2c5f`).
- The later macOS compatibility commit `9e8171f` did not change
  `lib/rhwa.sh` or `lib/testfence.sh`. macOS runs the orchestration client;
  `fence_redfish` still runs in the Linux FAR controller pod.

These facts explain how an earlier Linux-client run could succeed. A later
run using the same deployed `"1"` value and the same fence-agent parsing
behavior should hit the same error from either macOS or Linux. We do not
have evidence that anyone ran the full fencing test after the regression
and before this incident.

This history is reproducible from the local repository with
`git show 64683379:lib/rhwa.sh`, `git show c1ef0ec6 -- lib/rhwa.sh`, and
`git show 64683379 --format=fuller --no-patch`.

## Evidence and root cause

Read-only cluster queries on 2026-09-24 confirmed that the **deployed**
`fenceagentsremediationtemplate-default` still held
`sharedparameters["--ssl-insecure"] = "1"`. The local source at the parent
commit likewise used `"--ssl-insecure": "1"`; the working-tree change now
uses an empty value. The live template has not yet received that change.

The FAR controller log from 2026-09-24 at 12:32 UTC contains these lines
(selected; parameter values, including the password, are deliberately
omitted):

```text
12:32:35  Build fence agent command line  {"Fence Agent":"fence_redfish","Node Name":"worker-0"}
12:32:35  `action` parameter is missing, so we add it with the default value of `reboot`
12:32:35  Execute the fence agent  {"Parameters":["--action","--password","--ssl-insecure","--username","--ip","--ipport","--systems-uri"]}
12:32:35  fence agent start  {"fence_agent":"fence_redfish","retryCount":5,"retryInterval":"5s","timeout":"1m0s"}
12:32:35  command failed  ERROR:root:Parse error: option --ssl-insecure must not have an argument
12:32:40  command failed  ERROR:root:Parse error: option --ssl-insecure must not have an argument
12:32:45  command failed  ERROR:root:Parse error: option --ssl-insecure must not have an argument
12:32:50  command failed  ERROR:root:Parse error: option --ssl-insecure must not have an argument
12:32:55  command failed  ERROR:root:Parse error: option --ssl-insecure must not have an argument
12:32:55  Updating Status Condition  {"fenceAgentActionSucceededConditionStatus":"False","reason":"FenceAgentFailed"}
```

A read-only FAR status query returned
`worker-0-652xz  False  FenceAgentFailed  2026-09-24T12:32:55Z` for the
`FenceAgentActionSucceeded` condition. At investigation time, `worker-0`
still had boot ID `aa69b504-2029-4986-964f-cb3afb56dd68` and Ready
condition `Unknown`. The parser error is sufficient to explain why no
Redfish power request or VM reboot occurred. A later NHC timeout annotation
in the controller log does not change the earlier agent failure.

The precise bad argument follows from both source trees:

1. FAR's [parameter conversion](https://github.com/medik8s/fence-agents-remediation/blob/main/internal/controller/fenceagentsremediation_controller.go)
   appends `name=value` for a nonempty value and only `name` for an empty
   value. Thus `"--ssl-insecure": "1"` becomes `--ssl-insecure=1`.
2. ClusterLabs' [fence-agent option definition](https://github.com/ClusterLabs/fence-agents/blob/main/lib/fencing.py.py)
   defines `ssl_insecure` with long option `ssl-insecure` and no argument; its
   description says it enables SSL without certificate verification.
3. The controller logs show the agent itself rejecting the supplied argument
   five times with exit status 1. This is a command-line parsing failure,
   before the agent can contact the Redfish endpoint.

The controller log records parameter names rather than the full command
values. Its relevant shape, with secrets omitted, was:

```text
fence_redfish --action=reboot --ip=192.168.126.1 --ipport=8000 \
  --username=<redacted> --password=<redacted> \
  --systems-uri=/redfish/v1/Systems/<worker-0-uuid> --ssl-insecure=1
```

FAR iterates a map to build arguments, so their actual order can differ from
this illustration. The log prints parameter names rather than the full
command.

To recapture the nonsecret evidence while the cluster and logs still exist,
use the lab kubeconfig with these read-only queries:

```bash
export KUBECONFIG=state/jmatthews-rhwa-lab/kubeconfig
bin/oc -n openshift-workload-availability get \
  fenceagentsremediationtemplate/fenceagentsremediationtemplate-default \
  -o jsonpath='{.spec.template.spec.sharedparameters.--ssl-insecure}'
bin/oc -n openshift-workload-availability get \
  fenceagentsremediation.fence-agents-remediation.medik8s.io/worker-0-652xz \
  -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{" "}{.reason}{"\n"}{end}'
bin/oc -n openshift-workload-availability get pods -o wide
bin/oc -n openshift-workload-availability logs \
  pod/fence-agents-remediation-controller-manager-f7849fc9d-vvhgm \
  --since-time=2026-09-24T12:30:00Z --tail=500 \
  | rg 'worker-0|fence agent start|command failed|FenceAgentFailed'
bin/oc get node worker-0 \
  -o jsonpath='{.status.nodeInfo.bootID}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

The log query filters the printed lines and does not retrieve or print the
FAR resource's password field. Pod names and old logs may disappear after
rollouts or cluster teardown; the excerpts above preserve the key evidence.

Before teardown, a read-only runtime check in the same FAR controller pod
ran `fence_redfish --ssl-insecure -h` and exited 0. Its help output lists
`--ssl-insecure` without an argument. This checks the installed agent's
parser against the proposed flag form; it does not exercise a power action.

## Proposed fix and PR scope

Change [the generated FAR template](../lib/rhwa.sh) to give the flag an empty
value:

```diff
-        "--ssl-insecure": "1"
+        "--ssl-insecure": ""
```

FAR will then invoke `fence_redfish` with a standalone `--ssl-insecure` flag,
which matches the ClusterLabs option definition and FAR's own documented
example of a valueless flag (`--lanplus: ""`) in its
[README](https://github.com/medik8s/fence-agents-remediation#example-fenceagentsremediation-cr).

The local working tree already contains this source change, but it is
uncommitted and has **not** been applied to the running cluster. Reapplying
the template is necessary for an existing cluster; editing the shell file
alone does not change its Kubernetes resource. Any existing FAR resource
created from the old template also needs to finish or be cleared before a
clean retest.

The same working tree also has [test-harness changes](../lib/testfence.sh)
motivated by this run: use SSH to stop kubelet so `oc debug` cannot stall,
require an initially Ready worker, select the FAR for that worker, stop
waiting as soon as FAR reports `FenceAgentActionSucceeded=False`, and collect
FAR status plus logs from all controller pods. Those changes make a future
failure faster and easier to diagnose; the one-line template change fixes
the actual `fence_redfish` parse error.

## Verification needed before claiming the fix works end to end

1. Check that the deployed template has an empty `--ssl-insecure` value.
2. Recover `worker-0` from the failed attempt, confirm Ready, and ensure the
   previous FAR resource is cleared before rerunning the test.
3. Run `./rhwa-lab test` on that worker. Verify that FAR does not log the
   parsing error, sushy-tools receives the power action, the worker boot ID
   changes, the worker returns Ready, and FAR reports success.
4. Verify the updated test script reports a FAR failure promptly if fencing
   fails for another reason, with usable controller logs and status.

`bash -n lib/rhwa.sh lib/testfence.sh` and `git diff --check` passed for the
local changes during the initial investigation. The end-to-end fencing test
has not yet been repeated with the corrected deployed template.

## Issue / PR description draft

**Title:** Pass `--ssl-insecure` as a valueless flag to `fence_redfish`

**Problem:** `./rhwa-lab test` creates a FAR resource, but the FAR controller
retries `fence_redfish` five times and gets `Parse error: option
--ssl-insecure must not have an argument`. The worker remains NotReady with
the same boot ID. The lab template supplies `"1"` for a flag that takes no
value; FAR converts it to `--ssl-insecure=1`.

**Fix:** Set the template value to `""` so FAR passes `--ssl-insecure` alone.
Improve the test's kubelet-stop path and failure diagnostics so the result is
visible without waiting through the `oc debug` timeout and a full recovery
poll.

**Validation:** Confirm the deployed template and repeat the fencing test,
checking FAR status, sushy-tools activity, boot ID change, and Ready state.
