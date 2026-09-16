#!/usr/bin/env bash
# Shared test helpers: stub ssh_host/oc to capture what they'd send.
STUB_OUT="$(mktemp "${TMPDIR:-/tmp}/rhwa-test.XXXXXX")"
stub_ssh_host() {
  # Captures a heredoc body (stdin) AND args into $STUB_OUT.
  ssh_host() { printf '%s\n' "$*" >>"$STUB_OUT"; cat >>"$STUB_OUT" 2>/dev/null || true; }
}
assert_contains()     { grep -qF -- "$2" "$1" || { echo "FAIL: expected to find: $2"; exit 1; }; }
assert_not_contains() { grep -qF -- "$2" "$1" && { echo "FAIL: should NOT find: $2"; exit 1; } || true; }
