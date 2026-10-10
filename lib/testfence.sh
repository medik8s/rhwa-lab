#!/usr/bin/env bash
# testfence.sh - induce an unhealthy worker and verify NHC -> FAR ->
# fence_redfish -> sushy-tools reboots it and it rejoins.

_node_bootid() { oc get node "$1" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null; }
_node_ready()  { oc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }
_target_far() {
  oc -n "$RHWA_NAMESPACE" get fenceagentsremediation.fence-agents-remediation.medik8s.io -o json 2>/dev/null \
    | jq -r --arg node "$1" '[.items[] | select(.metadata.annotations["remediation.medik8s.io/node-name"] == $node) | .metadata.name][0] // empty'
}

test_fence() {
  [[ "$(state_get cluster_installed)" == "yes" ]] || die "No installed cluster in state; run 'create' first."
  os_local_oc
  compute_nodes
  local target="${NODE_HOST[$CONTROL_PLANE_COUNT]}"   # first worker
  [[ -n "$target" ]] || die "No worker node to target."

  log "Fencing test target: ${target}"
  oc get node "$target" >/dev/null 2>&1 || die "Node ${target} not found."
  local boot0 ready0
  boot0="$(_node_bootid "$target")"
  [[ -n "$boot0" ]] || die "Could not read ${target}'s boot ID."
  log "Current bootID: ${boot0}"
  ready0="$(_node_ready "$target")" || die "Could not read ${target}'s Ready condition."
  [[ "$ready0" == "True" ]] \
    || die "${target} is not Ready before the test; recover it before retrying."
  local existing_far
  existing_far="$(_target_far "$target")" || die "Could not check existing FenceAgentsRemediations."
  [[ -z "$existing_far" ]] \
    || die "Existing FenceAgentsRemediation ${existing_far} targets ${target}; let NHC clear it before retrying."

  log "Inducing unhealth: stopping kubelet on ${target}"
  # SSH stays up after kubelet stops; oc debug waits for its pod to time out.
  ssh_node "${NODE_IP[$CONTROL_PLANE_COUNT]}" 'sudo systemctl stop kubelet' \
    || die "Could not stop kubelet on ${target}."

  log "Waiting for ${target} to go NotReady..."
  local i
  for ((i=0; i<30; i++)); do
    [[ "$(_node_ready "$target")" != "True" ]] && { ok "${target} is NotReady"; break; }
    sleep 10
  done

  log "Waiting for NodeHealthCheck to create a FenceAgentsRemediation (unhealthy duration is 60s)..."
  local far=""
  for ((i=0; i<40; i++)); do
    far="$(_target_far "$target")" || far=""
    [[ -n "$far" ]] && { ok "FenceAgentsRemediation created: ${far}"; break; }
    sleep 15
  done
  [[ -z "$far" ]] && warn "No FenceAgentsRemediation appeared; check NHC status and FAR operator logs."

  log "Waiting for ${target} to reboot (bootID change) and return Ready..."
  local boot1 recovered=no fence_status
  for ((i=0; i<40; i++)); do
    boot1="$(_node_bootid "$target")" || boot1=""
    if [[ -n "$boot1" && "$boot1" != "$boot0" && "$(_node_ready "$target")" == "True" ]]; then
      recovered=yes; break
    fi
    if [[ -n "$far" ]]; then
      fence_status="$(oc -n "$RHWA_NAMESPACE" get fenceagentsremediation.fence-agents-remediation.medik8s.io "$far" -o json 2>/dev/null \
        | jq -r '.status.conditions[]? | select(.type == "FenceAgentActionSucceeded") | .status' 2>/dev/null)" || true
      [[ "$fence_status" == "False" ]] && break
    fi
    sleep 15
  done

  if [[ "$recovered" == "yes" ]]; then
    ok "SUCCESS: ${target} was fenced via fence_redfish and rejoined (bootID ${boot0} -> ${boot1})."
  else
    warn "Node did not confirm reboot+recovery in time. Diagnostics:"
    if [[ -n "$far" ]]; then
      echo "--- FAR status ---" >&2
      oc -n "$RHWA_NAMESPACE" get fenceagentsremediation.fence-agents-remediation.medik8s.io "$far" \
        -o jsonpath='{range .status.conditions[*]}{.type}: {.reason}: {.message}{"\n"}{end}' >&2 || true
    fi
    echo "--- FAR operator logs (tail, all pods) ---" >&2
    oc -n "$RHWA_NAMESPACE" logs deploy/fence-agents-remediation-controller-manager \
      --all-pods=true --since=1h --tail=80 >&2 || true
    echo "--- sushy-tools logs (tail) ---" >&2
    ssh_host 'sudo podman logs --tail 40 sushy' >&2 || true
    die "Fencing test did not complete successfully."
  fi
}
