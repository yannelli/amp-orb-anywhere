#!/usr/bin/env bash
# shellcheck disable=SC2016 # Test assertions intentionally match literal shell expressions.
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
SECRET_DIR="$state_root/secrets"
mkdir -p "$SECRET_DIR"
printf '%s\n' '{"remoteTerminal":false}' > "$STATE_DIR/local.json"
if runner_flags local && [[ "${RUNNER_FLAGS[*]}" == '--no-tui --runner-id local' ]]; then
	pass 'disabled remote terminal runner flags'
else
	fail 'disabled remote terminal runner flags'
fi
assert_equal 'amp' "$(agent_provider local)" 'legacy state defaults to Amp provider'

write_state codex-test docker tester /tmp/codex-work acme/api https://github.com/acme/api interactive false none '' codex
assert_equal 'codex' "$(jq -r '.agent' "$STATE_DIR/codex-test.json")" 'provider state serialization'
assert_equal 'false' "$(native_remote_enabled codex-test)" 'provider native remote defaults off in legacy state calls'
write_state claude-test docker tester /tmp/claude-work acme/api https://github.com/acme/api interactive false none '' claude true
assert_equal 'true' "$(native_remote_enabled claude-test)" 'provider native remote state serialization'
if ! jq -e 'has("apiKey") or has("token")' "$STATE_DIR/codex-test.json" >/dev/null; then
	pass 'provider state excludes credentials'
else
	fail 'provider state excludes credentials'
fi

rollback_workspace="$state_root/rollback-workspace"
mkdir -p "$rollback_workspace"
printf 'partial\n' > "$rollback_workspace/partial"
ADD_TRANSACTION_ACTIVE=true
ADD_TRANSACTION_ID=rollback-test
ADD_TRANSACTION_WORKSPACE="$rollback_workspace"
ADD_TRANSACTION_WORKSPACE_CREATED=true
ADD_TRANSACTION_VOLUME_CREATED=false
ADD_TRANSACTION_DESKTOP_VOLUME_CREATED=false
ADD_TRANSACTION_SECRET_CREATED=false
ADD_TRANSACTION_BASE_REPO=''
rollback_add_instance
trap 'rm -rf "$state_root"' EXIT
if [[ ! -e "$rollback_workspace" && "$ADD_TRANSACTION_ACTIVE" == false ]]; then
	pass 'failed add transaction removes newly created workspace'
else
	fail 'failed add transaction removes newly created workspace'
fi

printf 'preserve\n' > "$(token_path collision-test)"
if (ensure_add_resources_available collision-test) >/dev/null 2>&1; then
	fail 'add rejects orphaned same-ID resources'
else
	pass 'add rejects orphaned same-ID resources'
fi
rm -f "$(token_path collision-test)"

# A recycled ID must not silently inherit the previous workspace's credentials.
docker() {
	[[ "$*" == 'volume inspect amp-runner-volume-collision-home' ]]
}
if (ensure_add_resources_available volume-collision) >/dev/null 2>&1; then
	fail 'add rejects an orphaned home volume'
else
	pass 'add rejects an orphaned home volume'
fi
unset -f docker

github_projects="$(
	as_user() {
		printf '%s\n' '{"id":"123","namespace":"acme","name":"api","repositoryURL":"https://github.com/acme/api.git"}'
	}
	list_github_repositories tester
)"
assert_equal 'acme/api' "$(jq -r '.[0].namespace + "/" + .[0].name' <<< "$github_projects")" 'GitHub repository conversion'
assert_equal 'https://github.com/acme/api.git' "$(jq -r '.[0].repositoryURL' <<< "$github_projects")" 'GitHub clone URL selection'

container_agent_common_args codex-test /tmp/work agent-home codex /tmp/provider-key
if printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -Fxq 'type=bind,source=/tmp/provider-key,target=/run/secrets/agent_api_key,readonly' && \
	printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -Fxq 'agent-home:/agent-home' && \
	! printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -q 'OPENAI_API_KEY\|ANTHROPIC_API_KEY'; then
	pass 'provider home and file-backed secret mounts'
else
	fail 'provider home and file-backed secret mounts'
fi

SHARED_AUTH_DIR="$state_root/shared"
container_agent_common_args codex-test /tmp/work agent-home codex '' true
if printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -Fxq "type=bind,source=$SHARED_AUTH_DIR/codex,target=/agent-home/.codex" && \
	printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -Fxq '/agent-home/.codex/app-server-daemon:uid=1000,gid=1000,mode=0700' && \
	[[ "$(stat -c '%a' "$SHARED_AUTH_DIR/codex")" == 700 ]]; then
	pass 'shared auth mounts the provider config directory with a private daemon path'
else
	fail 'shared auth mounts the provider config directory with a private daemon path'
fi

container_agent_common_args claude-test /tmp/work agent-home claude '' true
if printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -Fxq "type=bind,source=$SHARED_AUTH_DIR/claude,target=/agent-home/.claude" && \
	! printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -q 'app-server-daemon'; then
	pass 'shared auth maps the Claude configuration directory'
else
	fail 'shared auth maps the Claude configuration directory'
fi

container_agent_common_args codex-test /tmp/work agent-home codex '' false
if ! printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -q "$SHARED_AUTH_DIR"; then
	pass 'isolated auth keeps credentials in the per-workspace volume'
else
	fail 'isolated auth keeps credentials in the per-workspace volume'
fi

if printf '%s\n' "${CONTAINER_ARGS[@]}" | grep -Fxq 'HOME=/agent-home'; then
	pass 'agent containers pin HOME to the persistent volume'
else
	fail 'agent containers pin HOME to the persistent volume'
fi

if shared_auth_present codex; then
	fail 'an empty shared store does not count as authenticated'
else
	pass 'an empty shared store does not count as authenticated'
fi
printf 'token\n' > "$SHARED_AUTH_DIR/codex/auth.json"
if shared_auth_present codex; then
	pass 'a populated shared store skips repeat logins'
else
	fail 'a populated shared store skips repeat logins'
fi

write_state shared-state docker tester /tmp/shared-work acme/api https://github.com/acme/api interactive false none '' codex true true
assert_equal 'true' "$(shared_auth_enabled shared-state)" 'shared auth state serialization'
assert_equal 'false' "$(shared_auth_enabled local)" 'legacy state keeps isolated credentials'

assert_equal '/desktop/local/' "$(desktop_subfolder local)" 'desktop reverse-proxy path'
assert_equal 'false' "$(desktop_state_value local '.desktop.enabled' false)" 'legacy state desktop default'
printf '%s\n' '{"desktop":{"enabled":true,"port":6080}}' > "$STATE_DIR/reserved.json"
if ! desktop_port_available 6080 && desktop_port_available 6081; then
	pass 'desktop port reservation'
else
	fail 'desktop port reservation'
fi

if "$ROOT/setup.sh" --help | grep -q -- 'Agent workspace manager'; then
	pass 'help output'
else
	fail 'help output'
fi

if "$ROOT/setup.sh" --help | grep -q -- '--agent amp|codex|claude' && "$ROOT/setup.sh" --help | grep -q -- 'connect RUNNER_ID' && \
	"$ROOT/setup.sh" --help | grep -q -- 'remote enable|disable|status|pair RUNNER_ID' && \
	"$ROOT/setup.sh" capabilities | grep -q -- 'Amp-managed orb infrastructure only'; then
	pass 'fleet and capability commands'
else
	fail 'fleet and capability commands'
fi

if grep -q -- '--cap-drop ALL' "$ROOT/setup.sh" && grep -q -- 'no-new-privileges:true' "$ROOT/setup.sh"; then
	pass 'container hardening defaults'
else
	fail 'container hardening defaults'
fi

unit_definition="$(declare -f write_unit)"
if grep -q 'Restart=always' <<< "$unit_definition" && grep -q 'RestartSec=5s' <<< "$unit_definition" && \
	grep -q 'StartLimitIntervalSec=0' <<< "$unit_definition" && grep -q 'checks its daemon PID every 30 seconds' "$ROOT/README.md"; then
	pass 'agent crash supervision retries indefinitely'
else
	fail 'agent crash supervision retries indefinitely'
fi

if ! grep -q 'NOPASSWD' "$ROOT/Dockerfile" && grep -q -- '--env HOME=/agent-home' "$ROOT/setup.sh" && \
	grep -q 'docker inspect.*State.Running' "$ROOT/setup.sh" && grep -q 'Interactive.*login skipped without a terminal' "$ROOT/setup.sh"; then
	pass 'provider runtime avoids root escalation and waits for persistent workspace readiness'
else
	fail 'provider runtime avoids root escalation and waits for persistent workspace readiness'
fi

agent_container_definition="$(declare -f run_agent_container)"
if grep -q -- '--cap-add SYS_ADMIN' <<< "$agent_container_definition" && \
	grep -q -- '--cap-add SYS_CHROOT' <<< "$agent_container_definition" && \
	grep -q -- '--cap-add SETUID' <<< "$agent_container_definition" && \
	grep -q -- '--cap-add SETGID' <<< "$agent_container_definition" && \
	grep -q -- '--cap-add SYS_PTRACE' <<< "$agent_container_definition" && \
	grep -q -- 'seccomp=unconfined' <<< "$agent_container_definition" && \
	! grep -q -- 'NET_ADMIN\|NET_RAW\|--privileged' <<< "$agent_container_definition"; then
	pass 'Codex nested sandbox uses documented minimum container privileges'
else
	fail 'Codex nested sandbox uses documented minimum container privileges'
fi

if grep -q 'codex login --device-auth' "$ROOT/setup.sh" && grep -q 'claude auth login' "$ROOT/setup.sh" && \
	grep -q 'docker exec.*"\$agent"' "$ROOT/setup.sh" && grep -q 'codex remote-control start' "$ROOT/setup.sh" && \
	grep -q 'claude remote-control --name' "$ROOT/setup.sh" && grep -q 'codex remote-control pair' "$ROOT/setup.sh" && \
	grep -q 'accept workspace trust' "$ROOT/setup.sh" && grep -q 'Codex Remote Control is opt-in' "$ROOT/README.md"; then
	pass 'provider CLI, trust, login, and remote commands'
else
	fail 'provider CLI, trust, login, and remote commands'
fi

agent_container_definition="$(declare -f run_agent_container)"

# claude auth status already reports JSON and exits non-zero when signed out. The old
# gate piped an undocumented --json flag into jq and read an assumed .loggedIn field,
# so any mismatch inverted through ! and parked the container in an endless sleep.
if ! grep -q 'claude auth status --json' "$ROOT/setup.sh" && \
	! grep -q 'loggedIn' "$ROOT/setup.sh" && \
	grep -q 'claude auth status >/dev/null 2>&1' <<< "$agent_container_definition"; then
	pass 'Claude login gate uses the documented exit status'
else
	fail 'Claude login gate uses the documented exit status'
fi

# A workspace waiting for its first login must keep polling instead of idling forever
# or crash-looping against RestartSec=5s.
# 'exec sh -c ... sleep 3600' was how a provider that could not start parked itself
# permanently. The idle fall-through for workspaces without a remote server is a
# separate 'exec docker run' and stays.
if grep -q 'while ! claude auth status' <<< "$agent_container_definition" && \
	grep -q 'until codex remote-control start' <<< "$agent_container_definition" && \
	! grep -q 'exec sh -c' <<< "$agent_container_definition"; then
	pass 'remote control waits for login instead of idling'
else
	fail 'remote control waits for login instead of idling'
fi

# --spawn session serves exactly one session and rejects further connections.
if grep -q -- '--spawn same-dir' <<< "$agent_container_definition" && \
	! grep -q -- 'remote-control.*--spawn session' "$ROOT/setup.sh"; then
	pass 'Claude Remote Control accepts more than one connection'
else
	fail 'Claude Remote Control accepts more than one connection'
fi

# The daemon writes its PID file asynchronously; checking at t=0 crash-looped.
if grep -q 'waited=0' <<< "$agent_container_definition" && \
	grep -q -- '-lt 60' <<< "$agent_container_definition"; then
	pass 'Codex watchdog allows a daemon start window'
else
	fail 'Codex watchdog allows a daemon start window'
fi

remote_command_definition="$(declare -f native_remote_command)"
if grep -q -- '--workdir /workspace "amp-runner-$id" codex remote-control pair' <<< "$remote_command_definition" && \
	grep -q 'terminal+=(--tty)' <<< "$remote_command_definition"; then
	pass 'Codex pairing runs on a terminal in the project directory'
else
	fail 'Codex pairing runs on a terminal in the project directory'
fi

# Remote Control refuses to start when ANTHROPIC_API_KEY is set.
if grep -q 'claude_wants_account_auth' "$ROOT/scripts/agent-cli-launcher" && \
	grep -q 'remote-control | --remote-control | --rc' "$ROOT/scripts/agent-cli-launcher"; then
	pass 'launcher keeps API keys away from Remote Control'
else
	fail 'launcher keeps API keys away from Remote Control'
fi

if grep -q "runtime_state='awaiting login'" "$ROOT/setup.sh" && \
	grep -q 'Sign in to start it' "$ROOT/setup.sh"; then
	pass 'remote status distinguishes awaiting login from inactive'
else
	fail 'remote status distinguishes awaiting login from inactive'
fi

if grep -q 'OPENAI_API_KEY="$(cat /run/secrets/agent_api_key)"' "$ROOT/scripts/agent-cli-launcher" && \
	grep -q 'ANTHROPIC_API_KEY="$(cat /run/secrets/agent_api_key)"' "$ROOT/scripts/agent-cli-launcher" && \
	grep -q 'CODEX_HOME=.*\.codex' "$ROOT/scripts/agent-cli-launcher" && \
	grep -q 'CLAUDE_CONFIG_DIR=.*\.claude' "$ROOT/scripts/agent-cli-launcher" && \
	grep -q '\.local/bin/codex' "$ROOT/scripts/agent-cli-launcher" && grep -q '\.local/bin/claude' "$ROOT/scripts/agent-cli-launcher"; then
	pass 'provider launcher maps secrets and persistent config'
else
	fail 'provider launcher maps secrets and persistent config'
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

if grep -q 'gh auth token --hostname github.com.*|' "$ROOT/setup.sh" && grep -q 'gh auth login --hostname github.com --git-protocol https --with-token' "$ROOT/setup.sh" && \
	! grep -q 'GH_TOKEN=.*gh auth login' "$ROOT/setup.sh"; then
	pass 'container GitHub credentials transfer over stdin'
else
	fail 'container GitHub credentials transfer over stdin'
fi

if grep -q 'trap rollback_add_instance EXIT' "$ROOT/setup.sh" && grep -q 'ADD_TRANSACTION_SECRET_CREATED' "$ROOT/setup.sh" && \
	grep -q 'requested_project:-\$requested_repository' "$ROOT/setup.sh"; then
	pass 'fleet project forwarding and failed-add rollback'
else
	fail 'fleet project forwarding and failed-add rollback'
fi

if grep -q -- 'OnUnitActiveSec=6h' "$ROOT/setup.sh" && grep -q -- 'releases/latest' "$ROOT/setup.sh" && \
	grep -q 'npm view @openai/codex version' "$ROOT/setup.sh" && grep -q 'npm view @anthropic-ai/claude-code version' "$ROOT/setup.sh" && \
	grep -q 'active desktops were left running' "$ROOT/setup.sh"; then
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
	grep -q 'firefox-esr' "$ROOT/Dockerfile.desktop" && grep -q "'thunar.desktop'" "$ROOT/Dockerfile.desktop"; then
	pass 'web workspace applications'
else
	fail 'web workspace applications'
fi

if grep -q 'chatgpt.com/codex/install.sh' "$ROOT/Dockerfile" && grep -q 'claude.ai/install.sh' "$ROOT/Dockerfile" && \
	grep -q 'CODEX_INSTALL_DIR=/agent-home/.local/bin' "$ROOT/Dockerfile" && \
	grep -q 'chmod u+s /usr/bin/bwrap' "$ROOT/Dockerfile" && grep -q 'install-runtimes.sh node' "$ROOT/Dockerfile.desktop" && \
	grep -q 'scripts/agent-cli-launcher.*INSTALL_DIR/scripts' "$ROOT/setup.sh" && \
	! grep -q 'DISABLE_AUTOUPDATER' "$ROOT/Dockerfile" "$ROOT/Dockerfile.desktop"; then
	pass 'agent images use current native CLIs, native updates, and nested sandbox runtime'
else
	fail 'agent images use current native CLIs, native updates, and nested sandbox runtime'
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

if grep -q 'amp-runner-${id}-home:/agent-home' <<< "$desktop_definition" && \
	grep -q 'target=/run/secrets/agent_api_key,readonly' <<< "$desktop_definition" && \
	grep -q 'provider.*codex' <<< "$desktop_definition"; then
	pass 'provider desktop shares only workspace home and runtime secret'
else
	fail 'provider desktop shares only workspace home and runtime secret'
fi

if grep -q 'flock.*desktop_lock_fd' "$ROOT/setup.sh" && \
	grep -q "transaction_complete.*cleanup_desktop_resources" "$ROOT/setup.sh" && \
	grep -q 'desktop.enabled.*write_desktop_unit' "$ROOT/setup.sh" && \
	[[ "$(grep -c 'exec {desktop_lock_fd}>&-' "$ROOT/setup.sh")" -ge 4 ]]; then
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
