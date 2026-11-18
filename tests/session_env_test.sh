#!/usr/bin/env bash
# Exercise startup in an isolated checkout; never source the developer's env.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/lib.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rhwa-session-env.XXXXXX")"
trap 'rm -rf "$tmp"; rm -f "$STUB_OUT"' EXIT
lab="$tmp/lab with spaces"
mkdir -p "$lab"
cp "${DIR}/../rhwa-lab" "$lab/"
cp -R "${DIR}/../lib" "$lab/"
export CLUSTER_NAME=existing-env BASE_DOMAIN=existing.example
out="$tmp/stdout" err="$tmp/stderr"
# Run outside the checkout to verify the env is found beside the script.
cd "$tmp"

bash "$lab/rhwa-lab" status </dev/null >"$out" 2>"$err"
assert_contains "$out" 'api.existing-env.existing.example:6443'
[[ ! -s "$err" ]] || { echo 'FAIL: prompted without an env file'; exit 1; }

cat >"$lab/source_me.env" <<'ENV'
export CLUSTER_NAME=file-env
export BASE_DOMAIN=file.example
ENV

for answer in y Y yes YES YeS; do
  printf '%s\n' "$answer" | bash "$lab/rhwa-lab" status >"$out" 2>"$err"
  assert_contains "$err" 'source_me.env'
  assert_contains "$err" '[y/N]'
  assert_not_contains "$out" 'source_me.env'
  assert_contains "$out" 'api.file-env.file.example:6443'
  [[ -f "$lab/state/file-env.state" ]] || { echo 'FAIL: env loaded after derived paths'; exit 1; }
done
[[ "$CLUSTER_NAME" == existing-env ]] || { echo 'FAIL: changed parent environment'; exit 1; }

for answer in n N no NO '' unexpected; do
  printf '%s\n' "$answer" | bash "$lab/rhwa-lab" status >"$out" 2>"$err"
  assert_contains "$err" '[y/N]'
  assert_contains "$out" 'api.existing-env.existing.example:6443'
done

# EOF is a decline, including a partial answer without a terminating newline.
for answer in '' yes; do
  printf '%s' "$answer" | bash "$lab/rhwa-lab" status >"$out" 2>"$err"
  assert_contains "$out" 'api.existing-env.existing.example:6443'
done

# A failed source must stop before dispatch, preserving its nonzero status.
printf 'return 23\n' >"$lab/source_me.env"
rc=0
printf 'y\n' | bash "$lab/rhwa-lab" help >"$out" 2>"$err" || rc=$?
[[ "$rc" -eq 23 ]] || { echo "FAIL: source returned $rc, expected 23"; exit 1; }
[[ ! -s "$out" ]] || { echo 'FAIL: dispatched after env failure'; exit 1; }

# Sourcing must preserve errexit, even if the failed command is not the last.
printf 'false\nexport CLUSTER_NAME=should-not-run\n' >"$lab/source_me.env"
rc=0
printf 'y\n' | bash "$lab/rhwa-lab" help >"$out" 2>"$err" || rc=$?
[[ "$rc" -ne 0 ]] || { echo 'FAIL: ignored a failed env command'; exit 1; }
[[ ! -s "$out" ]] || { echo 'FAIL: dispatched after env failure'; exit 1; }

echo 'PASS session env startup'
