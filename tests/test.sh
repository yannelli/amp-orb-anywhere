#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

pass() {
	printf 'ok  %s\n' "$1"
}

fail() {
	printf 'not ok  %s\n' "$1" >&2
	failures=$((failures + 1))
}

assert_equal() {
	local expected="$1" actual="$2" label="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$label"
	else
		fail "$label (expected '$expected', got '$actual')"
	fi
}

if bash -n "$ROOT/setup.sh" "$ROOT"/scripts/*.sh; then
	pass 'Bash syntax'
else
	fail 'Bash syntax'
fi

# shellcheck disable=SC1091
source "$ROOT/setup.sh"

assert_equal 'my-runner-1' "$(slugify ' My Runner_1 ')" 'runner ID normalization'
if validate_runner_id 'runner-1' && validate_runner_id 'a' && ! validate_runner_id '-runner' && ! validate_runner_id 'runner_'; then
	pass 'runner ID validation'
else
	fail 'runner ID validation'
fi

projects='[
  {"id":"p1","namespace":"acme","name":"api","repositoryURL":"https://github.com/acme/api","remoteURLs":[]},
  {"id":"p2","namespace":"acme","name":"web","repositoryURL":"https://github.com/acme/web","remoteURLs":[]}
]'
selected="$(choose_project "$projects" acme/web)"
assert_equal 'p2' "$(jq -r '.id' <<< "$selected")" 'project selection by namespace/name'
selected="$(choose_project "$projects" p1)"
assert_equal 'acme/api' "$(jq -r '.namespace + "/" + .name' <<< "$selected")" 'project selection by ID'

state_root="$(mktemp -d)"
trap 'rm -rf "$state_root"' EXIT
STATE_DIR="$state_root"
printf '%s\n' '{"remoteTerminal":false}' > "$STATE_DIR/local.json"
if runner_flags local && [[ "${RUNNER_FLAGS[*]}" == '--no-tui --runner-id local' ]]; then
	pass 'disabled remote terminal runner flags'
else
	fail 'disabled remote terminal runner flags'
fi

if "$ROOT/setup.sh" --help | grep -q -- 'Amp runner setup'; then
	pass 'help output'
else
	fail 'help output'
fi

if grep -q -- '--cap-drop ALL' "$ROOT/setup.sh" && grep -q -- 'no-new-privileges:true' "$ROOT/setup.sh"; then
	pass 'container hardening defaults'
else
	fail 'container hardening defaults'
fi

if grep -Eq 'RUNNER_FLAGS=.*--project|--no-tui.*--project' "$ROOT/setup.sh"; then
	fail 'runner command contains unsupported project flag'
else
	pass 'runner command avoids unsupported project flag'
fi

if grep -q -- '--remote-env "AMP_API_KEY=' "$ROOT/setup.sh"; then
	fail 'devcontainer token appears in process arguments'
else
	pass 'devcontainer token avoids process arguments'
fi

if grep -R $'\u2014' "$ROOT" --include='*.md' --include='*.sh' >/dev/null; then
	fail 'prose contains em dash'
else
	pass 'prose punctuation check'
fi

if ((failures)); then
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'All tests passed\n'
