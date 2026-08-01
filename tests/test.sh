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

version_file="$(cat "$ROOT/VERSION")"
manifest_version="$(jq -r '.["."] // empty' "$ROOT/.release-please-manifest.json")"
assert_equal "$version_file" "$VERSION" 'setup version matches VERSION'
if [[ -z "$manifest_version" || "$manifest_version" == "$version_file" ]]; then
	pass 'release manifest is ready for the initial or current version'
else
	fail "release manifest version matches VERSION (expected '$version_file', got '$manifest_version')"
fi
if [[ "$version_file" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] && grep -q 'x-release-please-version' "$ROOT/setup.sh"; then
	pass 'SemVer source and release annotation'
else
	fail 'SemVer source and release annotation'
fi

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

parse_project_spec 'acme/api=08'
assert_equal 'acme/api' "$PROJECT_SPEC_REF" 'bulk project reference parsing'
assert_equal '8' "$PROJECT_SPEC_COUNT" 'bulk project count parsing'

state_root="$(mktemp -d)"
trap 'rm -rf "$state_root"' EXIT
STATE_DIR="$state_root"
printf '%s\n' '{"remoteTerminal":false}' > "$STATE_DIR/local.json"
if runner_flags local && [[ "${RUNNER_FLAGS[*]}" == '--no-tui --runner-id local' ]]; then
	pass 'disabled remote terminal runner flags'
else
	fail 'disabled remote terminal runner flags'
fi

assert_equal '/desktop/local/' "$(desktop_subfolder local)" 'desktop reverse-proxy path'
assert_equal 'false' "$(desktop_state_value local '.desktop.enabled' false)" 'legacy state desktop default'
printf '%s\n' '{"desktop":{"enabled":true,"port":6080}}' > "$STATE_DIR/reserved.json"
if ! desktop_port_available 6080 && desktop_port_available 6081; then
	pass 'desktop port reservation'
else
	fail 'desktop port reservation'
fi

if "$ROOT/setup.sh" --help | grep -q -- 'Amp runner setup'; then
	pass 'help output'
else
	fail 'help output'
fi

if "$ROOT/setup.sh" --help | grep -q -- 'provision' && "$ROOT/setup.sh" capabilities | grep -q -- 'Amp-managed orb infrastructure only'; then
	pass 'fleet and capability commands'
else
	fail 'fleet and capability commands'
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

if grep -q -- 'OnUnitActiveSec=6h' "$ROOT/setup.sh" && grep -q -- 'releases/latest' "$ROOT/setup.sh"; then
	pass 'automatic release updater'
else
	fail 'automatic release updater'
fi

if ! grep -q '^ENV AGENT_BROWSER_EXECUTABLE_PATH=' "$ROOT/Dockerfile" && grep -q '\[\[ -x /usr/local/bin/agent-browser-chrome \]\]' "$ROOT/scripts/entrypoint.sh"; then
	pass 'browser executable override requires installed Chrome'
else
	fail 'browser executable override requires installed Chrome'
fi

if grep -q 'FROM lscr.io/linuxserver/webtop:debian-xfce' "$ROOT/Dockerfile.desktop" && \
	grep -q 'firefox-esr' "$ROOT/Dockerfile.desktop" && grep -q "'Thunar.desktop'" "$ROOT/Dockerfile.desktop"; then
	pass 'web workspace applications'
else
	fail 'web workspace applications'
fi

desktop_definition="$(declare -f run_desktop)"
if grep -q -- '--publish "127.0.0.1:' <<< "$desktop_definition" && \
	grep -q 'FILE__PASSWORD=/run/secrets/webtop_password' <<< "$desktop_definition" && \
	! grep -q -- '--privileged\|docker.sock\|0.0.0.0' <<< "$desktop_definition" && \
	grep -q 'tailscale serve --bg' "$ROOT/setup.sh" && ! grep -q 'tailscale funnel' "$ROOT/setup.sh"; then
	pass 'web workspace private access defaults'
else
	fail 'web workspace private access defaults'
fi

if grep -q 'flock.*desktop_lock_fd' "$ROOT/setup.sh" && \
	grep -q "transaction_complete.*cleanup_desktop_resources" "$ROOT/setup.sh" && \
	grep -q 'desktop.enabled.*write_desktop_unit' "$ROOT/setup.sh" && \
	[[ "$(grep -c 'exec {desktop_lock_fd}>&-' "$ROOT/setup.sh")" -eq 4 ]]; then
	pass 'web workspace transactional lifecycle'
else
	fail 'web workspace transactional lifecycle'
fi

tailscale() {
	printf 'error: failed to remove web serve: handler does not exist\n' >&2
	return 1
}
if disable_tailscale_desktop_route local; then
	pass 'missing Tailscale route cleanup is idempotent'
else
	fail 'missing Tailscale route cleanup is idempotent'
fi
unset -f tailscale

# Match UTF-8 em dash (U+2014). Avoid $'\u2014' so macOS Bash 3.2 does not
# treat the escape sequence as a literal search string for this file.
em_dash="$(printf '\342\200\224')"
if grep -R "$em_dash" "$ROOT" --include='*.md' --include='*.sh' >/dev/null; then
	fail 'prose contains em dash'
else
	pass 'prose punctuation check'
fi

if ((failures)); then
	printf '%s test(s) failed\n' "$failures" >&2
	exit 1
fi

printf 'All tests passed\n'
