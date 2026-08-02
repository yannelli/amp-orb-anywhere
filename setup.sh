#!/usr/bin/env bash
set -euo pipefail

VERSION=1.1.2 # x-release-please-version
INSTALL_DIR="${AMP_RUNNER_INSTALL_DIR:-/opt/amp-runner}"
CONFIG_DIR="${AMP_RUNNER_CONFIG_DIR:-/etc/amp-runner}"
STATE_DIR="$CONFIG_DIR/instances"
SECRET_DIR="$CONFIG_DIR/secrets"
SHARED_AUTH_DIR="$CONFIG_DIR/shared"
PANEL_USER="${AMP_RUNNER_PANEL_USER:-amp-panel}"
PANEL_PORT="${AMP_RUNNER_PANEL_PORT:-7900}"
PANEL_SERVICE='amp-runner-panel'
PANEL_SUDOERS='/etc/sudoers.d/amp-runner-panel'

DATA_DIR="${AMP_RUNNER_DATA_DIR:-/srv/amp-runners}"
IMAGE="${AMP_RUNNER_IMAGE:-amp-runner:ubuntu24.04}"
DESKTOP_IMAGE="${AMP_RUNNER_DESKTOP_IMAGE:-amp-runner-desktop:debian-xfce}"
UPDATE_REPOSITORY="${AMP_RUNNER_UPDATE_REPOSITORY:-yannelli/amp-orb-anywhere}"
AUTO_UPDATE_TIMER='amp-runner-update.timer'
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SOURCE_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
ADD_TRANSACTION_ACTIVE=false
ADD_TRANSACTION_ID=''
ADD_TRANSACTION_WORKSPACE=''
ADD_TRANSACTION_WORKSPACE_CREATED=false
ADD_TRANSACTION_VOLUME_CREATED=false
ADD_TRANSACTION_DESKTOP_VOLUME_CREATED=false
ADD_TRANSACTION_SECRET_CREATED=false
ADD_TRANSACTION_BASE_REPO=''
ADD_TRANSACTION_USER=''
PROVISION_TEMP_TOKEN_FILE=''

say() {
	printf '%s\n' "$*"
}

die() {
	printf 'Error: %s\n' "$*" >&2
	exit 1
}

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this command with sudo: sudo $0 $*"
}

have_tty() {
	[[ -t 0 && -t 1 ]]
}

ui_title() {
	if command -v gum >/dev/null 2>&1 && have_tty; then
		gum style --border rounded --border-foreground 63 --foreground 213 --bold --padding '0 2' "$1"
	else
		printf '\n%s\n\n' "$1"
	fi
}

ui_choose() {
	local prompt="$1"
	shift
	if command -v gum >/dev/null 2>&1 && have_tty; then
		printf '%s\n' "$@" | gum filter --height 14 --placeholder "$prompt"
	else
		local choice
		PS3="$prompt "
		select choice in "$@"; do
			[[ -n "$choice" ]] && printf '%s\n' "$choice" && return
		done
	fi
}

ui_choose_many() {
	local prompt="$1"
	shift
	if command -v gum >/dev/null 2>&1 && have_tty; then
		printf '%s\n' "$@" | gum filter --no-limit --height 18 --placeholder "$prompt (Tab selects)"
	else
		local index input part
		local -a indexes
		printf '%s\n' "$prompt" >&2
		index=1
		for part in "$@"; do
			printf '  %d) %s\n' "$index" "$part" >&2
			index=$((index + 1))
		done
		read -r -p 'Enter comma-separated numbers, or all: ' input
		if [[ "$input" == all ]]; then
			printf '%s\n' "$@"
			return
		fi
		IFS=',' read -ra indexes <<< "$input"
		for part in "${indexes[@]}"; do
			part="${part//[[:space:]]/}"
			[[ "$part" =~ ^[0-9]+$ && "$part" -ge 1 && "$part" -le $# ]] || die "Invalid selection: $part"
			printf '%s\n' "${!part}"
		done
	fi
}

ui_input() {
	local prompt="$1" default="${2:-}"
	if command -v gum >/dev/null 2>&1 && have_tty; then
		gum input --prompt "$prompt: " --value "$default"
	else
		local value
		read -r -p "$prompt${default:+ [$default]}: " value
		printf '%s\n' "${value:-$default}"
	fi
}

ui_password() {
	local prompt="$1"
	if command -v gum >/dev/null 2>&1 && have_tty; then
		gum input --password --prompt "$prompt: "
	else
		local value
		read -r -s -p "$prompt: " value
		printf '\n' >&2
		printf '%s\n' "$value"
	fi
}

ui_confirm() {
	local prompt="$1" default="${2:-no}"
	if command -v gum >/dev/null 2>&1 && have_tty; then
		if [[ "$default" == yes ]]; then
			gum confirm --default=true "$prompt"
		else
			gum confirm "$prompt"
		fi
	else
		local answer suffix='[y/N]'
		[[ "$default" == yes ]] && suffix='[Y/n]'
		read -r -p "$prompt $suffix " answer
		answer="${answer:-$([[ "$default" == yes ]] && printf y || printf n)}"
		[[ "$answer" =~ ^[Yy]$ ]]
	fi
}

ui_pause() {
	have_tty || return 0
	read -r -p 'Press Enter to continue ' _
}

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-63
}

validate_runner_id() {
	local id="$1"
	[[ ${#id} -le 63 && "$id" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

service_name() {
	printf 'amp-runner-%s' "$1"
}

state_file() {
	printf '%s/%s.json' "$STATE_DIR" "$1"
}

state_value() {
	local id="$1" query="$2"
	jq -r "($query) as \$value | if \$value == null then error(\"missing state value: $query\") else \$value end" "$(state_file "$id")"
}

desktop_state_value() {
	local id="$1" query="$2" default="$3"
	jq -r --arg default "$default" "($query) // \$default" "$(state_file "$id")"
}

agent_provider() {
	jq -r '.agent // "amp"' "$(state_file "$1")"
}

# Every supported workspace provider. Registering one means adding it here and
# giving it an arm in the provider_* helpers below.
AGENT_PROVIDERS=(amp codex claude opencode)

validate_provider() {
	local candidate="$1" provider
	for provider in "${AGENT_PROVIDERS[@]}"; do
		[[ "$provider" != "$candidate" ]] || return 0
	done
	return 1
}

provider_list_text() {
	local IFS='|'
	printf '%s' "${AGENT_PROVIDERS[*]}"
}

# Providers shipping a documented account-login remote control relay. OpenCode
# serves a local HTTP API instead, which the OpenChamber pairing exposes.
provider_supports_native_remote() {
	case "$1" in codex | claude) return 0 ;; *) return 1 ;; esac
}

native_remote_enabled() {
	jq -r '.nativeRemote // false' "$(state_file "$1")"
}

openchamber_enabled() {
	jq -r '.openchamber.enabled // false' "$(state_file "$1")"
}

# Legacy state files predate shared auth, so they keep their isolated per-workspace
# credentials until the workspace is recreated.
shared_auth_enabled() {
	jq -r '.sharedAuth // false' "$(state_file "$1")"
}

ensure_add_resources_available() {
	local id="$1" path
	for path in \
		"$(token_path "$id")" \
		"$(desktop_username_path "$id")" \
		"$(desktop_password_path "$id")" \
		"$(openchamber_password_path "$id")" \
		"/etc/systemd/system/$(service_name "$id").service" \
		"/etc/systemd/system/$(desktop_service_name "$id").service"; do
		[[ ! -e "$path" ]] || die "Runner ID $id has orphaned resources at $path. Remove or rename them before retrying."
	done
	# docker volume create is idempotent, so without this check a recycled ID would
	# silently inherit the previous workspace's credentials and session history.
	if docker volume inspect "amp-runner-${id}-home" >/dev/null 2>&1; then
		die "Runner ID $id has an orphaned Docker volume amp-runner-${id}-home. Remove it with 'docker volume rm amp-runner-${id}-home' or rename the workspace before retrying."
	fi
	if docker container inspect "amp-runner-$id" >/dev/null 2>&1 || docker container inspect "$(desktop_service_name "$id")" >/dev/null 2>&1; then
		die "Runner ID $id has an orphaned Docker container. Remove or rename it before retrying."
	fi
	if docker network inspect "amp-runner-$id" >/dev/null 2>&1; then
		die "Runner ID $id has an orphaned Docker network. Remove or rename it before retrying."
	fi
}

rollback_add_instance() {
	[[ "$ADD_TRANSACTION_ACTIVE" == true ]] || return 0
	trap - EXIT INT TERM HUP
	local id="$ADD_TRANSACTION_ID"
	systemctl disable --now "$(desktop_service_name "$id").service" >/dev/null 2>&1 || true
	systemctl disable --now "$(service_name "$id").service" >/dev/null 2>&1 || true
	docker rm --force "$(desktop_service_name "$id")" "amp-runner-$id" >/dev/null 2>&1 || true
	docker network rm "amp-runner-$id" >/dev/null 2>&1 || true
	rm -f "/etc/systemd/system/$(desktop_service_name "$id").service" "/etc/systemd/system/$(service_name "$id").service"
	rm -f "$(desktop_username_path "$id")" "$(desktop_password_path "$id")" "$(openchamber_password_path "$id")"
	if [[ "$ADD_TRANSACTION_SECRET_CREATED" == true ]]; then rm -f "$(token_path "$id")"; fi
	if [[ "$ADD_TRANSACTION_VOLUME_CREATED" == true ]]; then
		docker volume rm "amp-runner-${id}-home" >/dev/null 2>&1 || true
	fi
	if [[ "$ADD_TRANSACTION_DESKTOP_VOLUME_CREATED" == true ]]; then
		docker volume rm "amp-runner-${id}-desktop" >/dev/null 2>&1 || true
	fi
	if [[ -n "$ADD_TRANSACTION_BASE_REPO" && -e "$ADD_TRANSACTION_WORKSPACE" ]]; then
		as_user "$ADD_TRANSACTION_USER" git -C "$ADD_TRANSACTION_BASE_REPO" worktree remove --force "$ADD_TRANSACTION_WORKSPACE" >/dev/null 2>&1 || true
	elif [[ "$ADD_TRANSACTION_WORKSPACE_CREATED" == true ]]; then
		rm -rf -- "$ADD_TRANSACTION_WORKSPACE"
	fi
	rm -f "$(state_file "$id")"
	if [[ -n "$PROVISION_TEMP_TOKEN_FILE" ]]; then rm -f -- "$PROVISION_TEMP_TOKEN_FILE"; fi
	systemctl daemon-reload >/dev/null 2>&1 || true
	ADD_TRANSACTION_ACTIVE=false
}

restore_provision_exit_trap() {
	if [[ -n "$PROVISION_TEMP_TOKEN_FILE" ]]; then
		trap 'rm -f -- "$PROVISION_TEMP_TOKEN_FILE"' EXIT
	else
		trap - EXIT
	fi
	trap - INT TERM HUP
}

desktop_service_name() {
	printf 'amp-runner-%s-desktop' "$1"
}

desktop_username_path() {
	printf '%s/%s.desktop-user' "$SECRET_DIR" "$1"
}

desktop_password_path() {
	printf '%s/%s.desktop-password' "$SECRET_DIR" "$1"
}

admin_user() {
	local user="${AMP_RUNNER_ADMIN_USER:-${SUDO_USER:-}}"
	if [[ -z "$user" || "$user" == root ]]; then
		user="$(getent passwd 1000 | cut -d: -f1 || true)"
	fi
	[[ -n "$user" && "$user" != root ]] || die 'Set AMP_RUNNER_ADMIN_USER to the non-root account that will own host runners.'
	printf '%s\n' "$user"
}

user_home() {
	getent passwd "$1" | cut -d: -f6
}

as_user() {
	local user="$1"
	shift
	local -a environment=(
		env
		"HOME=$(user_home "$user")"
		"USER=$user"
		"LOGNAME=$user"
		"PATH=/usr/local/bin:/opt/node/bin:/usr/local/go/bin:/opt/rust/cargo/bin:/usr/bin:/bin"
	)
	if [[ $(id -u) -eq $(id -u "$user") ]]; then
		"${environment[@]}" "$@"
	else
		runuser -u "$user" -- "${environment[@]}" "$@"
	fi
}

ensure_layout() {
	install -d -m 0755 "$INSTALL_DIR" "$STATE_DIR" "$DATA_DIR" "$DATA_DIR/workspaces" "$DATA_DIR/repositories" "$DATA_DIR/devcontainer-data"
	install -d -m 0700 "$SECRET_DIR" "$SHARED_AUTH_DIR"
}

install_tool_files() {
	local source="${1:-$SOURCE_DIR}"
	[[ -f "$source/setup.sh" && -f "$source/Dockerfile" && -f "$source/Dockerfile.desktop" && -d "$source/scripts" ]] || die "Invalid setup source: $source"
	ensure_layout
	if [[ "$source" != "$INSTALL_DIR" ]]; then
		install -m 0755 "$source/setup.sh" "$INSTALL_DIR/setup.sh"
		install -m 0644 "$source/Dockerfile" "$INSTALL_DIR/Dockerfile"
		install -m 0644 "$source/Dockerfile.desktop" "$INSTALL_DIR/Dockerfile.desktop"
		install -d -m 0755 "$INSTALL_DIR/scripts"
		install -m 0755 "$source"/scripts/*.sh "$source/scripts/agent-cli-launcher" "$INSTALL_DIR/scripts/"
		# Without this the control panel would be dropped on every update and self-update.
		if [[ -d "$source/panel" ]]; then
			install -d -m 0755 "$INSTALL_DIR/panel"
			install -m 0644 "$source/panel/package.json" "$source/panel/package-lock.json" "$source/panel/vite.config.js" \
				"$source/panel/postcss.config.js" "$source/panel/index.html" "$INSTALL_DIR/panel/"
			install -m 0755 "$source/panel/server.mjs" "$INSTALL_DIR/panel/server.mjs"
			rm -rf "$INSTALL_DIR/panel/src"
			cp -R "$source/panel/src" "$INSTALL_DIR/panel/src"
			chmod -R u=rwX,go=rX "$INSTALL_DIR/panel/src"
		fi
	else
		chmod 0755 "$INSTALL_DIR/setup.sh" "$INSTALL_DIR"/scripts/*.sh "$INSTALL_DIR/scripts/agent-cli-launcher"
	fi
	ln -sfn "$INSTALL_DIR/setup.sh" /usr/local/sbin/amp-runner-setup
}

install_auto_update_timer() {
	[[ "$UPDATE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid GitHub update repository: $UPDATE_REPOSITORY"
	cat > /etc/systemd/system/amp-runner-update.service <<EOF
[Unit]
Description=Update Amp runner tooling and CLI releases
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=AMP_RUNNER_INSTALL_DIR=$INSTALL_DIR
Environment=AMP_RUNNER_CONFIG_DIR=$CONFIG_DIR
Environment=AMP_RUNNER_DATA_DIR=$DATA_DIR
Environment=AMP_RUNNER_IMAGE=$IMAGE
Environment=AMP_RUNNER_DESKTOP_IMAGE=$DESKTOP_IMAGE
Environment=AMP_RUNNER_UPDATE_REPOSITORY=$UPDATE_REPOSITORY
ExecStart=$INSTALL_DIR/setup.sh _automatic-update
EOF
	cat > "/etc/systemd/system/$AUTO_UPDATE_TIMER" <<'EOF'
[Unit]
Description=Check for Amp runner updates every six hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOF
	systemctl daemon-reload
	systemctl enable --now "$AUTO_UPDATE_TIMER"
}

check_os() {
	local os_id os_version
	[[ -r /etc/os-release ]] || die 'Cannot identify this operating system.'
	os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
	os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
	[[ "$os_id" == ubuntu && "$os_version" == 24.04 ]] || die "Ubuntu 24.04 is required, found $os_id $os_version."
}

install_amp_for_user() {
	local user="$1" home
	home="$(user_home "$user")"
	if [[ ! -x "$home/.amp/bin/amp" ]]; then
		as_user "$user" bash -c 'curl -fsSL https://ampcode.com/install.sh | bash'
	fi
}

host_amp() {
	local user="$1"
	shift
	as_user "$user" "$(user_home "$user")/.amp/bin/amp" "$@"
}

configure_docker_logs() {
	local current='{}' merged
	[[ -s /etc/docker/daemon.json ]] && current="$(cat /etc/docker/daemon.json)"
	merged="$(jq -s '.[0] * .[1]' <(printf '%s\n' "$current") <(printf '%s\n' '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}'))"
	printf '%s\n' "$merged" > /etc/docker/daemon.json
	systemctl restart docker
}

configure_unattended_upgrades() {
	cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
}

harden_ssh() {
	local user="$1" home
	home="$(user_home "$user")"
	[[ -s "$home/.ssh/authorized_keys" ]] || die "Refusing to disable password SSH because $home/.ssh/authorized_keys is empty."
	cat > /etc/ssh/sshd_config.d/60-amp-runner-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
MaxAuthTries 3
EOF
	sshd -t
	systemctl reload-or-restart ssh
}

install_tailscale() {
	local codename
	# Bootstrap is also the repair path, so this runs on hosts that already have
	# Tailscale. Reinstalling would rewrite the keyring and apt source every time,
	# and a bare tailscale up can re-prompt a node that is already authenticated.
	if command -v tailscale >/dev/null 2>&1; then
		say 'Tailscale is already installed; skipping package installation.'
	else
		codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
		curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
		curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
		apt-get update -qq
		DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
	fi
	if tailscale_online; then
		say "Tailscale is already authenticated and online as $(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "this node"' | sed 's/\.$//')."
		return 0
	fi
	if have_tty; then
		# --ssh is what makes the documented "remove public SSH once Tailscale SSH
		# works" step, and the Codex remote SSH-host route, actually possible.
		tailscale up --ssh
	else
		say 'Tailscale installed. Run sudo tailscale up --ssh from an SSH session to authenticate.'
	fi
}

build_image() {
	local codex_version claude_version opencode_version
	codex_version="$(npm view @openai/codex version)"
	claude_version="$(npm view @anthropic-ai/claude-code version)"
	opencode_version="$(npm view opencode-ai version)"
	docker build --pull \
		--build-arg "CODEX_VERSION=$codex_version" \
		--build-arg "CLAUDE_CODE_VERSION=$claude_version" \
		--build-arg "OPENCODE_VERSION=$opencode_version" \
		--tag "$IMAGE" "$INSTALL_DIR"
}

build_desktop_image() {
	local codex_version claude_version opencode_version
	codex_version="$(npm view @openai/codex version)"
	claude_version="$(npm view @anthropic-ai/claude-code version)"
	opencode_version="$(npm view opencode-ai version)"
	docker build --pull \
		--build-arg "CODEX_VERSION=$codex_version" \
		--build-arg "CLAUDE_CODE_VERSION=$claude_version" \
		--build-arg "OPENCODE_VERSION=$opencode_version" \
		--file "$INSTALL_DIR/Dockerfile.desktop" --tag "$DESKTOP_IMAGE" "$INSTALL_DIR"
}

desktop_enabled() {
	[[ "$(desktop_state_value "$1" '.desktop.enabled' false)" == true ]]
}

tailscale_online() {
	command -v tailscale >/dev/null 2>&1 && \
		tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running" and .Self.Online == true' >/dev/null
}

desktop_subfolder() {
	printf '/desktop/%s/' "$1"
}

desktop_port_available() {
	local port="$1" file reserved
	[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || return 1
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		# Both loopback services draw from the same host port space.
		for reserved in "$(jq -r '.desktop.port // empty' "$file")" "$(jq -r '.openchamber.port // empty' "$file")"; do
			[[ "$reserved" != "$port" ]] || return 1
		done
	done
	! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

next_desktop_port() {
	local port
	for ((port = 6080; port <= 6279; port++)); do
		if desktop_port_available "$port"; then
			printf '%s\n' "$port"
			return
		fi
	done
	die 'No free desktop port is available between 6080 and 6279.'
}

openchamber_password_path() {
	printf '%s/%s.openchamber-password' "$SECRET_DIR" "$1"
}

next_openchamber_port() {
	local port
	for ((port = 7080; port <= 7279; port++)); do
		if desktop_port_available "$port"; then
			printf '%s\n' "$port"
			return
		fi
	done
	die 'No free OpenChamber port is available between 7080 and 7279.'
}

write_desktop_secret() {
	local path="$1" value="$2"
	[[ -n "$value" ]] || die 'Desktop credentials cannot be empty.'
	[[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die 'Desktop credentials cannot contain newlines.'
	(
		umask 077
		printf '%s' "$value" > "$path"
		chmod 0400 "$path"
	)
}

write_desktop_state() {
	local id="$1" enabled="$2" access="$3" port="$4" username="$5" file tmp
	file="$(state_file "$id")"
	tmp="$(mktemp "${file}.XXXXXX")"
	jq --argjson enabled "$enabled" --arg access "$access" --argjson port "$port" --arg username "$username" \
		'.desktop = {enabled:$enabled,access:$access,port:$port,username:$username}' "$file" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
}

write_desktop_access() {
	local id="$1" access="$2" file tmp
	file="$(state_file "$id")"
	tmp="$(mktemp "${file}.XXXXXX")"
	jq --arg access "$access" '.desktop.access = $access' "$file" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
}

write_desktop_unit() {
	local id="$1" service
	service="$(desktop_service_name "$id")"
	cat > "/etc/systemd/system/$service.service" <<EOF
[Unit]
Description=Secure web workspace for agent $id
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/setup.sh _run-desktop $id
ExecStop=-$INSTALL_DIR/setup.sh _stop-desktop $id
Restart=always
RestartSec=5s
TimeoutStopSec=30s
KillMode=mixed
UMask=0077
Environment=AMP_RUNNER_INSTALL_DIR=$INSTALL_DIR
Environment=AMP_RUNNER_CONFIG_DIR=$CONFIG_DIR
Environment=AMP_RUNNER_DATA_DIR=$DATA_DIR
Environment=AMP_RUNNER_DESKTOP_IMAGE=$DESKTOP_IMAGE

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
}

run_desktop() {
	local id="$1" workspace mode user uid gid port name provider key='' subfolder='/'
	local -a args
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	desktop_enabled "$id" || die "Web workspace is disabled for runner $id."
	workspace="$(state_value "$id" '.workspace')"
	mode="$(state_value "$id" '.mode')"
	provider="$(agent_provider "$id")"
	user="$(state_value "$id" '.user')"
	if [[ "$mode" == docker ]]; then
		uid=1000
		gid=1000
	else
		uid="$(id -u "$user")"
		gid="$(id -g "$user")"
	fi
	port="$(desktop_state_value "$id" '.desktop.port' '')"
	[[ -n "$port" ]] || die "Runner $id has no web workspace port."
	# SUBFOLDER stays '/' for both access modes. Tailscale Serve mounts this container
	# at /desktop/ID and forwards the remainder, so telling the container's own web
	# server to also expect that prefix left it serving its default page instead.
	name="$(desktop_service_name "$id")"
	docker rm --force "$name" >/dev/null 2>&1 || true
	args=(--rm
		--name "$name"
		--label "amp.runner.id=$id"
		--label 'amp.runner.component=desktop'
		--label "amp.agent.provider=$provider"
		--publish "127.0.0.1:$port:3001"
		--volume "amp-runner-${id}-desktop:/config"
		--volume "$workspace:/workspace:rw"
		--mount "type=bind,source=$(desktop_username_path "$id"),target=/run/secrets/webtop_username,readonly"
		--mount "type=bind,source=$(desktop_password_path "$id"),target=/run/secrets/webtop_password,readonly"
		--env "PUID=$uid"
		--env "PGID=$gid"
		--env 'TZ=Etc/UTC'
		--env "TITLE=$provider Workspace: $id"
		--env "SUBFOLDER=$subfolder"
		--env 'FILE_MANAGER_PATH=/workspace'
		--env 'FM_HOME=/workspace'
		--env 'FILE__CUSTOM_USER=/run/secrets/webtop_username'
		--env 'FILE__PASSWORD=/run/secrets/webtop_password'
		--env 'DISABLE_SUDO=true'
		--env 'START_DOCKER=false'
		--shm-size 1g
		--pids-limit 4096)
	if [[ "$provider" != amp ]]; then
		args+=(--volume "amp-runner-${id}-home:/agent-home")
		if [[ "$(state_value "$id" '.auth')" == token ]]; then
			key="$(token_path "$id")"
			args+=(--mount "type=bind,source=$key,target=/run/secrets/agent_api_key,readonly")
		fi
		# The desktop runs the same provider CLIs, so it needs the same login the
		# headless workspace uses or the user would be prompted a second time.
		if [[ "$(shared_auth_enabled "$id")" == true ]]; then
			shared_auth_args "$provider"
			if ((${#SHARED_AUTH_ARGS[@]})); then
				args+=("${SHARED_AUTH_ARGS[@]}")
			fi
		fi
	fi
	if [[ "$provider" == codex ]]; then
		args+=(--cap-add SYS_ADMIN --cap-add SYS_CHROOT --cap-add SETUID --cap-add SETGID --cap-add SYS_PTRACE
			--security-opt seccomp=unconfined --security-opt apparmor=unconfined)
	else
		args+=(--security-opt no-new-privileges:true)
	fi
	exec docker run "${args[@]}" "$DESKTOP_IMAGE"
}

stop_desktop() {
	local id="$1"
	docker stop --time 20 "$(desktop_service_name "$id")" >/dev/null 2>&1 || true
	docker rm --force "$(desktop_service_name "$id")" >/dev/null 2>&1 || true
}

wait_for_desktop() {
	# The container always serves at its own root. Tailscale Serve owns the
	# /desktop/ID mount point, so the backend never sees that prefix.
	local id="$1" port="$2" username="$3" password="$4" path='/' attempt curl_user
	curl_user="$username:$password"
	curl_user="${curl_user//\\/\\\\}"
	curl_user="${curl_user//\"/\\\"}"
	for ((attempt = 1; attempt <= 90; attempt++)); do
		if printf 'user = "%s"\n' "$curl_user" | curl --config - --fail --insecure --silent --show-error \
			--output /dev/null --max-time 5 "https://127.0.0.1:$port$path" 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	return 1
}

enable_tailscale_desktop_route() {
	local id="$1" port
	if ! tailscale_online; then
		printf 'Tailscale must be installed, authenticated, and online for tailnet desktop access.\n' >&2
		return 1
	fi
	port="$(desktop_state_value "$id" '.desktop.port' '')"
	tailscale serve --bg --https=443 --set-path="/desktop/$id" "https+insecure://127.0.0.1:$port"
}

tailscale_desktop_route_present() {
	tailscale serve status 2>/dev/null | grep -Fq "/desktop/$1"
}

disable_tailscale_desktop_route() {
	local id="$1"
	command -v tailscale >/dev/null 2>&1 || return 1
	tailscale serve --https=443 --set-path="/desktop/$id" off >/dev/null 2>&1 && return 0
	# Removing a route that is already gone is success. Confirm that against Serve's
	# own state instead of matching an English error string upstream can reword.
	! tailscale_desktop_route_present "$id"
}

# tailscale serve --bg returns 0 even when it only printed a consent URL, and the
# loopback health check never traverses the proxy, so a broken tailnet route used to
# look like a healthy desktop. Probe the real URL and say what is wrong.
verify_tailscale_desktop_route() {
	local id="$1" username="$2" password="$3" dns_name url body curl_user
	dns_name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
	if [[ -z "$dns_name" ]]; then
		printf 'Could not read this node name from Tailscale, so the web workspace URL was not verified.\n' >&2
		return 1
	fi
	url="https://$dns_name$(desktop_subfolder "$id")"
	curl_user="$username:$password"
	curl_user="${curl_user//\\/\\\\}"
	curl_user="${curl_user//\"/\\\"}"
	body="$(printf 'user = "%s"\n' "$curl_user" | curl --config - --location --silent --show-error \
		--max-time 15 "$url" 2>/dev/null || true)"
	if [[ -z "$body" ]]; then
		printf 'No response from %s yet. Tailscale may still be waiting for HTTPS or Serve consent; run: sudo tailscale serve status\n' "$url" >&2
		return 1
	fi
	if grep -qi 'Welcome to nginx' <<< "$body"; then
		printf 'The web workspace at %s is serving the default web server page instead of the desktop.\n' "$url" >&2
		printf 'That means the proxy path and the container path disagree. Use --access ssh, or report this with: sudo tailscale serve status\n' >&2
		return 1
	fi
	return 0
}

restore_desktop_access() {
	local id="$1" access="$2" port="$3" username="$4" password="$5"
	disable_tailscale_desktop_route "$id" || true
	write_desktop_access "$id" "$access" || return 1
	systemctl restart "$(desktop_service_name "$id").service" || return 1
	wait_for_desktop "$id" "$port" "$username" "$password" || return 1
	if [[ "$access" == tailscale ]]; then enable_tailscale_desktop_route "$id" || return 1; fi
}

panel_password_path() {
	printf '%s/panel-password' "$SECRET_DIR"
}

panel_url() {
	printf 'http://127.0.0.1:%s/' "$PANEL_PORT"
}

ensure_panel_user() {
	if ! id -u "$PANEL_USER" >/dev/null 2>&1; then
		useradd --system --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "$PANEL_USER"
	fi
}

# The panel drives systemd and nothing else. It deliberately cannot run setup.sh,
# which also owns remove and uninstall, and it is kept out of the docker group
# because that is equivalent to host root.
write_panel_sudoers() {
	local tmp
	tmp="$(mktemp)"
	cat > "$tmp" <<EOF
$PANEL_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start amp-runner-*.service, /usr/bin/systemctl stop amp-runner-*.service, /usr/bin/systemctl restart amp-runner-*.service
EOF
	chmod 0440 "$tmp"
	if ! visudo -c -q -f "$tmp"; then
		rm -f "$tmp"
		die 'Generated sudoers policy for the control panel is invalid.'
	fi
	install -m 0440 -o root -g root "$tmp" "$PANEL_SUDOERS"
	rm -f "$tmp"
}

build_panel() {
	local source="$INSTALL_DIR/panel"
	[[ -f "$source/package.json" ]] || die 'Control panel sources are missing. Re-run bootstrap.'
	command -v npm >/dev/null 2>&1 || die 'npm is required to build the control panel. Re-run bootstrap.'
	say 'Building the control panel. This runs npm and can take a few minutes.'
	if [[ -f "$source/package-lock.json" ]]; then
		(cd "$source" && npm ci --no-audit --no-fund --loglevel=error && npm run build)
	else
		(cd "$source" && npm install --no-audit --no-fund --loglevel=error && npm run build)
	fi
	[[ -f "$source/dist/index.html" ]] || die 'The control panel build produced no output.'
	chmod -R u=rwX,go=rX "$source/dist"
}

write_panel_unit() {
	cat > "/etc/systemd/system/$PANEL_SERVICE.service" <<EOF
[Unit]
Description=Amp Orb Anywhere control panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$PANEL_USER
Environment=AMP_PANEL_PORT=$PANEL_PORT
Environment=AMP_PANEL_DIST=$INSTALL_DIR/panel/dist
Environment=AMP_PANEL_PASSWORD_FILE=$(panel_password_path)
Environment=AMP_RUNNER_STATE_DIR=$STATE_DIR
Environment=AMP_PANEL_VERSION=$VERSION
Environment=AMP_PANEL_HOSTNAME=$(hostname -s)
ExecStart=$(command -v node) $INSTALL_DIR/panel/server.mjs
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
NoNewPrivileges=false
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
}

enable_panel() {
	require_root panel
	ensure_layout
	desktop_port_available "$PANEL_PORT" || die "Port $PANEL_PORT is already reserved or in use. Set AMP_RUNNER_PANEL_PORT and retry."
	ensure_panel_user
	if [[ ! -s "$(panel_password_path)" ]]; then
		write_desktop_secret "$(panel_password_path)" "$(openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-24)"
	fi
	chown "$PANEL_USER" "$(panel_password_path)"
	write_panel_sudoers
	build_panel
	write_panel_unit
	systemctl enable --now "$PANEL_SERVICE.service"
	say
	say 'Control panel enabled.'
	panel_details
}

disable_panel() {
	require_root panel
	systemctl disable --now "$PANEL_SERVICE.service" >/dev/null 2>&1 || true
	rm -f "/etc/systemd/system/$PANEL_SERVICE.service" "$PANEL_SUDOERS"
	systemctl daemon-reload
	say 'Control panel disabled. Its password file and build output were retained.'
}

panel_details() {
	require_root panel
	[[ -s "$(panel_password_path)" ]] || die 'The control panel is not enabled.'
	say "URL:      $(panel_url) on this host"
	say "Tunnel:   ssh -N -L $PANEL_PORT:127.0.0.1:$PANEL_PORT $(admin_user)@THIS_HOST"
	say 'Username: any value'
	say "Password: $(cat "$(panel_password_path)")"
	say 'Publish it on a tailnet with:'
	say "  sudo tailscale serve --bg --https=443 --set-path=/panel http://127.0.0.1:$PANEL_PORT"
}

panel_command() {
	local action="${1:-status}"
	case "$action" in
	enable) enable_panel ;;
	disable) disable_panel ;;
	credentials) panel_details ;;
	restart)
		require_root panel
		systemctl restart "$PANEL_SERVICE.service"
		say 'Control panel restarted.'
		;;
	status)
		require_root panel
		printf 'Service: %s\n' "$(systemctl is-active "$PANEL_SERVICE.service" 2>/dev/null || true)"
		printf 'URL: %s\n' "$(panel_url)"
		;;
	*) die 'panel expects enable, disable, status, credentials, or restart.' ;;
	esac
}

openchamber_details() {
	require_root openchamber
	local id="${1:-}" port
	[[ -n "$id" && -r "$(state_file "$id")" ]] || die 'openchamber requires a known RUNNER_ID.'
	[[ "$(openchamber_enabled "$id")" == true ]] || die "OpenChamber is not enabled for $id."
	port="$(jq -r '.openchamber.port // 0' "$(state_file "$id")")"
	say "Workspace: $id"
	say "URL:      https://127.0.0.1:$port/ after forwarding, or http://127.0.0.1:$port/ on this host"
	say "Tunnel:   ssh -N -L $port:127.0.0.1:$port $(admin_user)@THIS_HOST"
	say "Password: $(cat "$(openchamber_password_path "$id")")"
	say 'Publish it on a tailnet with:'
	say "  sudo tailscale serve --bg --https=443 --set-path=/chamber/$id http://127.0.0.1:$port"
}

cleanup_desktop_resources() {
	local id="$1" purge="${2:-}" access route_removed=true
	access="$(desktop_state_value "$id" '.desktop.access' '')"
	if [[ "$access" == tailscale ]]; then
		if ! disable_tailscale_desktop_route "$id"; then route_removed=false; fi
	else
		disable_tailscale_desktop_route "$id" || true
	fi
	systemctl disable --now "$(desktop_service_name "$id").service" >/dev/null 2>&1 || true
	stop_desktop "$id"
	rm -f "/etc/systemd/system/$(desktop_service_name "$id").service" || true
	if [[ "$purge" == --purge ]]; then docker volume rm "amp-runner-${id}-desktop" >/dev/null 2>&1 || true; fi
	systemctl daemon-reload >/dev/null 2>&1 || true
	if [[ "$route_removed" != true ]]; then return 1; fi
	rm -f "$(desktop_username_path "$id")" "$(desktop_password_path "$id")" || true
	if [[ -r "$(state_file "$id")" ]]; then write_desktop_state "$id" false '' 0 '' || true; fi
}

desktop_access_details() {
	local id="$1" access port username password dns_name
	desktop_enabled "$id" || die "Web workspace is disabled for runner $id."
	access="$(desktop_state_value "$id" '.desktop.access' ssh)"
	port="$(desktop_state_value "$id" '.desktop.port' '')"
	username="$(cat "$(desktop_username_path "$id")")"
	password="$(cat "$(desktop_password_path "$id")")"
	if [[ "$access" == tailscale ]]; then
		dns_name="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//' || true)"
		if [[ -n "$dns_name" ]]; then
			say "URL:      https://$dns_name$(desktop_subfolder "$id")"
		else
			say "Path:     $(desktop_subfolder "$id") (Tailscale is currently unavailable)"
		fi
		say 'Network:  tailnet only, subject to Tailscale access controls'
	else
		say "Tunnel:   ssh -N -L $port:127.0.0.1:$port USER@HOST"
		say "URL:      https://127.0.0.1:$port/"
		say 'TLS:      self-signed certificate inside the SSH tunnel'
	fi
	say "Username: $username"
	say "Password: $password"
}

enable_desktop() {
	require_root desktop
	local id="$1"
	shift
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	desktop_enabled "$id" && die "Web workspace is already enabled for runner $id."
	local access='' username=amp port='' password_file='' password status desktop_lock_fd
	while (($#)); do
		case "$1" in
		--access) access="$2"; shift ;;
		--username) username="$2"; shift ;;
		--port) port="$2"; shift ;;
		--password-file) password_file="$2"; shift ;;
		*) die "Unknown desktop enable option: $1" ;;
		esac
		shift
	done
	if [[ -z "$access" ]]; then
		have_tty || die 'Pass --access tailscale or --access ssh without a terminal.'
		if tailscale_online; then access="$(ui_choose 'Secure web access' 'tailscale' 'ssh')"; else access=ssh; fi
	fi
	case "$access" in tailscale | ssh) ;; *) die '--access must be tailscale or ssh.' ;; esac
	[[ "$username" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 'Desktop username must use 1 to 64 letters, numbers, dots, underscores, or hyphens.'
	exec {desktop_lock_fd}> "$CONFIG_DIR/desktop.lock"
	flock "$desktop_lock_fd"
	desktop_enabled "$id" && die "Web workspace is already enabled for runner $id."
	if [[ -n "$port" ]]; then
		desktop_port_available "$port" || die "Desktop port is invalid or already in use: $port"
	else
		port="$(next_desktop_port)"
	fi
	if [[ -n "$password_file" ]]; then
		[[ -r "$password_file" ]] || die "Cannot read desktop password file: $password_file"
		password="$(cat "$password_file")"
	else
		password="$(openssl rand -hex 24)"
	fi
	[[ "$access" != tailscale ]] || tailscale_online || die 'Tailscale must be online before enabling tailnet access.'
	set +e
	(
		set -e
		transaction_complete=false
		trap 'if [[ "$transaction_complete" != true ]]; then cleanup_desktop_resources "$id" || true; fi' EXIT
		if ! docker image inspect "$DESKTOP_IMAGE" >/dev/null 2>&1; then build_desktop_image; fi
		write_desktop_secret "$(desktop_username_path "$id")" "$username"
		write_desktop_secret "$(desktop_password_path "$id")" "$password"
		write_desktop_state "$id" true "$access" "$port" "$username"
		write_desktop_unit "$id"
		systemctl enable --now "$(desktop_service_name "$id").service"
		wait_for_desktop "$id" "$port" "$username" "$password"
		if [[ "$access" == tailscale ]]; then enable_tailscale_desktop_route "$id"; fi
		transaction_complete=true
	)
	status=$?
	set -e
	if ((status != 0)); then
		if ! cleanup_desktop_resources "$id"; then
			die 'Web workspace setup failed. Local resources were removed, but the Tailscale route could not be cleared. Reconnect Tailscale and run desktop disable.'
		fi
		die 'Web workspace setup failed and was rolled back. Check Docker and systemd logs.'
	fi
	flock -u "$desktop_lock_fd"
	exec {desktop_lock_fd}>&-
	say
	say "Web workspace enabled for runner $id."
	# Warn rather than fail: Tailscale can still be waiting on HTTPS or Serve consent,
	# which is the administrator's action, not a broken workspace.
	if [[ "$access" == tailscale ]]; then
		verify_tailscale_desktop_route "$id" "$username" "$password" || true
	fi
	desktop_access_details "$id"
}

disable_desktop() {
	require_root desktop
	local id="$1" purge="${2:-}"
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	if ! cleanup_desktop_resources "$id" "$purge"; then
		die 'Local web workspace resources were removed, but the Tailscale route could not be cleared. Reconnect Tailscale and retry desktop disable.'
	fi
	say "Web workspace disabled for runner $id."
}

set_desktop_access() {
	require_root desktop
	local id="$1" access="$2" old_access port username password status transaction_status desktop_lock_fd
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	desktop_enabled "$id" || die "Web workspace is disabled for runner $id."
	case "$access" in tailscale | ssh) ;; *) die 'Desktop access must be tailscale or ssh.' ;; esac
	[[ "$access" != tailscale ]] || tailscale_online || die 'Tailscale must be online before enabling tailnet access.'
	exec {desktop_lock_fd}> "$CONFIG_DIR/desktop.lock"
	flock "$desktop_lock_fd"
	old_access="$(desktop_state_value "$id" '.desktop.access' ssh)"
	if [[ "$access" == "$old_access" ]]; then
		if [[ "$access" == tailscale ]]; then enable_tailscale_desktop_route "$id"; fi
		flock -u "$desktop_lock_fd"
		exec {desktop_lock_fd}>&-
		desktop_access_details "$id"
		return
	fi
	port="$(desktop_state_value "$id" '.desktop.port' '')"
	username="$(cat "$(desktop_username_path "$id")")"
	password="$(cat "$(desktop_password_path "$id")")"
	set +e
	(
		set -e
		transaction_complete=false
		trap 'transaction_status=$?; trap - EXIT INT TERM HUP; if [[ "$transaction_complete" != true ]] && ! restore_desktop_access "$id" "$old_access" "$port" "$username" "$password"; then exit 200; fi; exit "$transaction_status"' EXIT
		trap 'exit 130' INT
		trap 'exit 143' TERM
		trap 'exit 129' HUP
		if [[ "$old_access" == tailscale ]]; then disable_tailscale_desktop_route "$id"; fi
		write_desktop_access "$id" "$access"
		systemctl restart "$(desktop_service_name "$id").service"
		wait_for_desktop "$id" "$port" "$username" "$password"
		if [[ "$access" == tailscale ]]; then enable_tailscale_desktop_route "$id"; fi
		transaction_complete=true
	)
	status=$?
	set -e
	if ((status == 200)); then
		die 'Web workspace access change failed, and the previous access mode could not be fully restored. Check Docker, systemd, and Tailscale.'
	elif ((status != 0)); then
		die 'Web workspace access change failed. The previous access mode was restored.'
	fi
	flock -u "$desktop_lock_fd"
	exec {desktop_lock_fd}>&-
	desktop_access_details "$id"
}

rotate_desktop_password() {
	require_root desktop
	local id="$1" password_file="${2:-}" password
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	desktop_enabled "$id" || die "Web workspace is disabled for runner $id."
	if [[ -n "$password_file" ]]; then
		[[ -r "$password_file" ]] || die "Cannot read desktop password file: $password_file"
		password="$(cat "$password_file")"
	else
		password="$(openssl rand -hex 24)"
	fi
	write_desktop_secret "$(desktop_password_path "$id")" "$password"
	systemctl restart "$(desktop_service_name "$id").service"
	desktop_access_details "$id"
}

update_desktops() {
	require_root desktop-update
	local target="${1:---all}" file id found=false desktop_lock_fd old_image='' new_image
	local force_restart="${AMP_RUNNER_FORCE_RESTART:-true}"
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		[[ "$target" == --all || "$target" == "$id" ]] || continue
		if [[ "$(jq -r '.desktop.enabled // false' "$file")" == true ]]; then found=true; fi
	done
	[[ "$found" == true ]] || { say 'No enabled web workspaces matched.'; return; }
	exec {desktop_lock_fd}> "$CONFIG_DIR/desktop.lock"
	flock "$desktop_lock_fd"
	old_image="$(docker image inspect --format '{{.Id}}' "$DESKTOP_IMAGE" 2>/dev/null || true)"
	build_desktop_image
	new_image="$(docker image inspect --format '{{.Id}}' "$DESKTOP_IMAGE")"
	if [[ "$force_restart" != true && "$old_image" == "$new_image" ]]; then
		flock -u "$desktop_lock_fd"
		exec {desktop_lock_fd}>&-
		say 'Web workspace image is current; active desktops were left running.'
		return
	fi
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		[[ "$target" == --all || "$target" == "$id" ]] || continue
		[[ "$(jq -r '.desktop.enabled // false' "$file")" != true ]] || systemctl restart "$(desktop_service_name "$id").service"
	done
	flock -u "$desktop_lock_fd"
	exec {desktop_lock_fd}>&-
}

desktop_command() {
	local action="${1:-}" id="${2:-}"
	[[ -n "$action" && -n "$id" ]] || die 'desktop requires an action and RUNNER_ID.'
	shift 2
	case "$action" in
	enable) enable_desktop "$id" "$@" ;;
	disable) disable_desktop "$id" "$@" ;;
	credentials | access-details) require_root desktop; desktop_access_details "$id" ;;
	access) (($# == 1)) || die 'desktop access requires tailscale or ssh.'; set_desktop_access "$id" "$1" ;;
	rotate-password)
		local password_file=''
		if (($#)); then [[ "$1" == --password-file && $# == 2 ]] || die 'rotate-password accepts --password-file PATH.'; password_file="$2"; fi
		rotate_desktop_password "$id" "$password_file"
		;;
	start | stop | restart)
		require_root desktop
		desktop_enabled "$id" || die "Web workspace is disabled for runner $id."
		systemctl "$action" "$(desktop_service_name "$id").service"
		;;
	status)
		require_root desktop
		desktop_access_details "$id"
		systemctl --no-pager --full status "$(desktop_service_name "$id").service" || true
		;;
	logs)
		require_root desktop
		journalctl -u "$(desktop_service_name "$id").service" -n 200 --no-pager "$@"
		;;
	*) die "Unknown desktop action: $action" ;;
	esac
}

bootstrap() {
	local ssh_hardening=false tailscale=false non_interactive=false
	while (($#)); do
		case "$1" in
		--harden-ssh) ssh_hardening=true ;;
		--tailscale) tailscale=true ;;
		--non-interactive) non_interactive=true ;;
		*) die "Unknown bootstrap option: $1" ;;
		esac
		shift
	done
	require_root bootstrap
	check_os
	ui_title 'Amp runner host bootstrap'
	install_tool_files
	"$INSTALL_DIR/scripts/install-packages.sh" host
	"$INSTALL_DIR/scripts/install-runtimes.sh"
	npm install --global @devcontainers/cli
	ln -sfn /opt/node/bin/devcontainer /usr/local/bin/devcontainer
	local user
	user="$(admin_user)"
	usermod -aG docker "$user"
	chown "$user:$(id -gn "$user")" "$DATA_DIR/repositories" "$DATA_DIR/devcontainer-data"
	configure_docker_logs
	build_image
	configure_unattended_upgrades
	install_amp_for_user "$user"
	install_auto_update_timer
	if [[ "$non_interactive" == false && "$ssh_hardening" == false ]] && ui_confirm 'Disable SSH passwords and root login? Verify key login in a second session first.' no; then
		ssh_hardening=true
	fi
	[[ "$ssh_hardening" == true ]] && harden_ssh "$user"
	if [[ "$non_interactive" == false && "$tailscale" == false ]] && ui_confirm 'Install and authenticate Tailscale?' no; then
		tailscale=true
	fi
	[[ "$tailscale" == true ]] && install_tailscale
	touch "$CONFIG_DIR/.bootstrapped"
	say
	say "Host ready. Add a runner with: sudo amp-runner-setup add"
	say 'Log out and reconnect before using Docker directly from the admin account.'
}

token_path() {
	printf '%s/%s.key' "$SECRET_DIR" "$1"
}

store_token() {
	local id="$1" token="$2" owner="${3:-root}" provider="${4:-amp}"
	[[ -n "$token" ]] || die "The $provider API key is empty."
	[[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || die "The $provider API key contains a newline."
	local path
	path="$(token_path "$id")"
	(
		umask 077
		printf '%s' "$token" > "$path"
		chmod 0400 "$path"
		chown "$owner" "$path"
	)
}

shared_auth_dir() {
	printf '%s/%s' "$SHARED_AUTH_DIR" "$1"
}

# Container-side configuration directory each provider CLI reads. These match the
# CODEX_HOME and CLAUDE_CONFIG_DIR values exported by scripts/agent-cli-launcher.
provider_config_target() {
	case "$1" in
	codex) printf '/agent-home/.codex' ;;
	claude) printf '/agent-home/.claude' ;;
	opencode) printf '/agent-home/.local/share/opencode' ;;
	*) return 1 ;;
	esac
}

ensure_shared_auth_dir() {
	local provider="$1" path
	provider_config_target "$provider" >/dev/null || return 1
	path="$(shared_auth_dir "$provider")"
	install -d -m 0700 "$path"
	# The provider CLIs write these credentials as the container's uid 1000.
	[[ "$(id -u)" -ne 0 ]] || chown 1000:1000 "$path"
	printf '%s' "$path"
}

# A shared store counts as authenticated once the provider CLI has written anything
# into it. This avoids guessing undocumented credential file names.
shared_auth_present() {
	local path
	path="$(shared_auth_dir "$1")"
	[[ -d "$path" ]] || return 1
	[[ -n "$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

shared_auth_args() {
	local provider="$1" path target
	SHARED_AUTH_ARGS=()
	[[ "$provider" != amp ]] || return 0
	target="$(provider_config_target "$provider")" || return 0
	path="$(ensure_shared_auth_dir "$provider")" || return 0
	SHARED_AUTH_ARGS=(--mount "type=bind,source=$path,target=$target")
	# The Codex app-server daemon records a PID that is only meaningful inside its own
	# container. Keep it per-container so co-tenant workspaces cannot read each other's.
	if [[ "$provider" == codex ]]; then
		SHARED_AUTH_ARGS+=(--tmpfs "$target/app-server-daemon:uid=1000,gid=1000,mode=0700")
	fi
}

container_common_args() {
	local id="$1" workspace="$2" home_volume="$3" key="$4"
	CONTAINER_ARGS=(--rm --volume "$home_volume:/home/amp" --volume "$workspace:/workspace" --workdir /workspace)
	if [[ -n "$key" ]]; then
		CONTAINER_ARGS+=(--mount "type=bind,source=$key,target=/run/secrets/amp_api_key,readonly")
	fi
	CONTAINER_ARGS+=(--label "amp.runner.id=$id")
}

container_agent_common_args() {
	local id="$1" workspace="$2" home_volume="$3" provider="$4" key="$5" shared="${6:-false}"
	CONTAINER_ARGS=(--rm --volume "$home_volume:/agent-home" --volume "$workspace:/workspace" --workdir /workspace)
	# The image ships HOME=/home/amp, which no volume covers. Without this every plain
	# docker exec would write to the container layer and lose it on the next restart.
	CONTAINER_ARGS+=(--env HOME=/agent-home)
	CONTAINER_ARGS+=(--label "amp.runner.id=$id" --label "amp.agent.provider=$provider")
	if [[ -n "$key" ]]; then
		CONTAINER_ARGS+=(--mount "type=bind,source=$key,target=/run/secrets/agent_api_key,readonly")
	fi
	if [[ "$shared" == true ]]; then
		shared_auth_args "$provider"
		if ((${#SHARED_AUTH_ARGS[@]})); then
			CONTAINER_ARGS+=("${SHARED_AUTH_ARGS[@]}")
		fi
	fi
}

container_agent_interactive() {
	local id="$1" workspace="$2" home_volume="$3" provider="$4" shared="$5"
	shift 5
	container_agent_common_args "$id" "$workspace" "$home_volume" "$provider" '' "$shared"
	docker run --interactive --tty "${CONTAINER_ARGS[@]}" "$IMAGE" "$provider" "$@"
}

container_amp() {
	local id="$1" workspace="$2" home_volume="$3" key="$4"
	shift 4
	container_common_args "$id" "$workspace" "$home_volume" "$key"
	docker run "${CONTAINER_ARGS[@]}" "$IMAGE" amp "$@"
}

container_amp_interactive() {
	local id="$1" workspace="$2" home_volume="$3"
	shift 3
	container_common_args "$id" "$workspace" "$home_volume" ''
	docker run --interactive --tty "${CONTAINER_ARGS[@]}" "$IMAGE" amp "$@"
}

authenticate_host() {
	local user="$1" method="$2" token="$3"
	install_amp_for_user "$user"
	if [[ "$method" == token ]]; then
		AMP_API_KEY="$token" host_amp "$user" projects list --json >/dev/null
	elif ! host_amp "$user" projects list --json >/dev/null 2>&1; then
		host_amp "$user" login
	fi
}

authenticate_container() {
	local id="$1" workspace="$2" volume="$3" method="$4" key="$5"
	if [[ "$method" == token ]]; then
		container_amp "$id" "$workspace" "$volume" "$key" projects list --json >/dev/null
	elif ! container_amp "$id" "$workspace" "$volume" '' projects list --json >/dev/null 2>&1; then
		container_amp_interactive "$id" "$workspace" "$volume" login
	fi
}

list_projects_host() {
	local user="$1" method="$2" token="$3"
	if [[ "$method" == token ]]; then
		AMP_API_KEY="$token" host_amp "$user" projects list --json
	else
		host_amp "$user" projects list --json
	fi
}

list_projects_container() {
	local id="$1" workspace="$2" volume="$3" key="$4"
	container_amp "$id" "$workspace" "$volume" "$key" projects list --json
}

ensure_github_login() {
	local user="$1"
	if as_user "$user" gh auth status --hostname github.com >/dev/null 2>&1; then return; fi
	have_tty || die 'GitHub CLI login is required to discover repositories.'
	as_user "$user" gh auth login --hostname github.com --git-protocol https --web
	as_user "$user" gh auth setup-git --hostname github.com
}

list_github_repositories() {
	local user="$1"
	as_user "$user" gh api --paginate \
		'user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=full_name' \
		--jq '.[] | {id:(.id|tostring),namespace:.owner.login,name:.name,repositoryURL:.clone_url}' |
		jq -s 'unique_by(.repositoryURL) | sort_by(.namespace, .name)'
}

authenticate_agent_container() {
	local provider="$1" id="$2" workspace="$3" volume="$4" auth="$5" shared="${6:-false}"
	[[ "$auth" == interactive ]] || return 0
	if [[ "$shared" == true ]] && shared_auth_present "$provider"; then
		say "Reusing the shared $provider login. Re-authenticate with: sudo amp-runner-setup authenticate $id"
		return 0
	fi
	if ! have_tty; then
		say "Interactive $provider login skipped without a terminal. Run: sudo amp-runner-setup authenticate $id"
		return 0
	fi
	case "$provider" in
	codex) container_agent_interactive "$id" "$workspace" "$volume" "$shared" codex login --device-auth ;;
	opencode) container_agent_interactive "$id" "$workspace" "$volume" "$shared" opencode auth login ;;
	claude)
		container_agent_interactive "$id" "$workspace" "$volume" "$shared" claude auth login
		say 'Claude will open once so you can accept workspace trust. Exit Claude after accepting.'
		container_agent_interactive "$id" "$workspace" "$volume" "$shared" claude
		;;
	esac
}

choose_project() {
	local projects_json="$1" requested="${2:-}" selected
	if [[ -n "$requested" ]]; then
		selected="$(jq -c --arg ref "$requested" '.[] | select((.namespace + "/" + .name) == $ref or .id == $ref or .repositoryURL == $ref)' <<< "$projects_json" | head -n1)"
		[[ -n "$selected" ]] || die "Project or repository not found: $requested"
		printf '%s\n' "$selected"
		return
	fi
	mapfile -t PROJECT_OPTIONS < <(jq -r '.[] | (.namespace + "/" + .name + "\t" + .repositoryURL)' <<< "$projects_json")
	((${#PROJECT_OPTIONS[@]} > 0)) || die 'No projects or repositories are available to this account.'
	selected="$(ui_choose 'Project or repository' "${PROJECT_OPTIONS[@]}")"
	local ref="${selected%%$'\t'*}"
	jq -c --arg ref "$ref" '.[] | select((.namespace + "/" + .name) == $ref)' <<< "$projects_json" | head -n1
}

ensure_remote() {
	local user="$1" workspace="$2" remote="$3"
	if as_user "$user" git -C "$workspace" remote get-url origin >/dev/null 2>&1; then
		as_user "$user" git -C "$workspace" remote set-url origin "$remote"
	else
		as_user "$user" git -C "$workspace" remote add origin "$remote"
	fi
}

ensure_host_github_auth() {
	local user="$1" remote="$2"
	[[ "$remote" == *github.com* ]] || return 0
	if as_user "$user" gh auth status --hostname github.com >/dev/null 2>&1; then
		as_user "$user" gh auth setup-git --hostname github.com
	elif have_tty && ui_confirm 'Authenticate GitHub CLI for private clone and push access?' yes; then
		as_user "$user" gh auth login --hostname github.com --git-protocol https --web
		as_user "$user" gh auth setup-git --hostname github.com
	fi
}

ensure_container_github_auth() {
	local provider="$1" id="$2" workspace="$3" volume="$4" remote="$5" host_user="${6:-}"
	[[ "$remote" == *github.com* ]] || return 0
	if [[ "$provider" == amp ]]; then
		container_common_args "$id" "$workspace" "$volume" ''
	else
		container_agent_common_args "$id" "$workspace" "$volume" "$provider" ''
	fi
	if docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth status --hostname github.com >/dev/null 2>&1; then
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth setup-git --hostname github.com
	elif [[ -n "$host_user" ]] && as_user "$host_user" gh auth status --hostname github.com >/dev/null 2>&1; then
		as_user "$host_user" gh auth token --hostname github.com | \
			docker run --interactive "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth login --hostname github.com --git-protocol https --with-token
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth setup-git --hostname github.com
	elif have_tty && ui_confirm 'Authenticate GitHub CLI in this container for private clone and push access?' yes; then
		docker run --interactive --tty "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth login --hostname github.com --git-protocol https --web
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth setup-git --hostname github.com
	else
		die "GitHub authentication is required inside workspace $id to clone $remote."
	fi
}

prepare_host_checkout() {
	local user="$1" workspace="$2" project_ref="$3" remote="$4" clone_repo="$5"
	install -d -m 0755 "$(dirname "$workspace")"
	chown "$user:$(id -gn "$user")" "$(dirname "$workspace")"
	if [[ -d "$workspace/.git" || -f "$workspace/.git" ]]; then
		ensure_remote "$user" "$workspace" "$remote"
		return
	fi
	[[ ! -e "$workspace" || -z "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || die "Workspace is not empty: $workspace"
	rm -rf "$workspace"
	if [[ "$clone_repo" == true ]]; then
		if [[ "$remote" == https://ampcode.com/git/* ]]; then
			host_amp "$user" clone "$project_ref" "$workspace"
		else
			ensure_host_github_auth "$user" "$remote"
			as_user "$user" git clone "$remote" "$workspace"
		fi
	else
		install -d -m 0755 "$workspace"
		chown "$user:$(id -gn "$user")" "$workspace"
		as_user "$user" git -C "$workspace" init
		as_user "$user" git -C "$workspace" remote add origin "$remote"
	fi
}

prepare_container_checkout() {
	local id="$1" workspace="$2" volume="$3" key="$4" project_ref="$5" remote="$6" clone_repo="$7" provider="${8:-amp}" host_user="${9:-}"
	local -a checkout_args
	install -d -m 0755 "$(dirname "$workspace")"
	if [[ "$provider" == amp ]]; then
		container_common_args "$id" "$workspace" "$volume" "$key"
	else
		container_agent_common_args "$id" "$workspace" "$volume" "$provider" "$key"
	fi
	checkout_args=("${CONTAINER_ARGS[@]}")
	if [[ -d "$workspace/.git" || -f "$workspace/.git" ]]; then
		docker run "${checkout_args[@]}" "$IMAGE" git remote set-url origin "$remote"
		return
	fi
	[[ ! -e "$workspace" || -z "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || die "Workspace is not empty: $workspace"
	rm -rf "$workspace"
	install -d -m 0755 "$workspace"
	chown 1000:1000 "$workspace"
	if [[ "$clone_repo" == true ]]; then
		rm -rf "$workspace"
		install -d -m 0755 "$workspace"
		chown 1000:1000 "$workspace"
		if [[ "$remote" == https://ampcode.com/git/* ]]; then
			container_amp "$id" "$(dirname "$workspace")" "$volume" "$key" clone "$project_ref" "/workspace/$(basename "$workspace")"
		else
			ensure_container_github_auth "$provider" "$id" "$(dirname "$workspace")" "$volume" "$remote" "$host_user"
			if [[ "$provider" == amp ]]; then
				container_common_args "$id" "$(dirname "$workspace")" "$volume" ''
			else
				container_agent_common_args "$id" "$(dirname "$workspace")" "$volume" "$provider" ''
			fi
			docker run "${CONTAINER_ARGS[@]}" "$IMAGE" git clone "$remote" "$(basename "$workspace")"
		fi
	else
		docker run "${checkout_args[@]}" "$IMAGE" git init
		docker run "${checkout_args[@]}" "$IMAGE" git remote add origin "$remote"
	fi
}

prepare_worktree() {
	local user="$1" workspace="$2" project_ref="$3" remote="$4" clone_repo="$5"
	local repo_slug base
	repo_slug="$(slugify "$project_ref")"
	base="$DATA_DIR/repositories/$repo_slug"
	if [[ ! -d "$base/.git" ]]; then
		prepare_host_checkout "$user" "$base" "$project_ref" "$remote" "$clone_repo"
	fi
	as_user "$user" git -C "$base" rev-parse --verify HEAD >/dev/null 2>&1 || die 'Worktree mode requires a repository with at least one commit. Use --clone or populate the base repository first.'
	if [[ -d "$workspace/.git" || -f "$workspace/.git" ]]; then
		printf '%s\n' "$base"
		return
	fi
	[[ ! -e "$workspace" || -z "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || die "Workspace is not empty: $workspace"
	rm -rf "$workspace"
	install -d -m 0755 "$(dirname "$workspace")"
	chown "$user:$(id -gn "$user")" "$(dirname "$workspace")"
	as_user "$user" git -C "$base" worktree add --detach "$workspace" HEAD
	printf '%s\n' "$base"
}

devcontainer_up() {
	local id="$1" workspace="$2" user volume output cid
	if [[ -r "$(state_file "$id")" ]]; then
		user="$(state_value "$id" '.user')"
	else
		user="$(admin_user)"
	fi
	volume="amp-runner-${id}-home"
	if [[ $(id -u) -eq 0 ]]; then
		install -d -m 0755 "$DATA_DIR/devcontainer-data/$id"
		chown "$user:$(id -gn "$user")" "$DATA_DIR/devcontainer-data/$id"
	else
		mkdir -p "$DATA_DIR/devcontainer-data/$id"
	fi
	local args=(devcontainer up --workspace-folder "$workspace" --user-data-folder "$DATA_DIR/devcontainer-data/$id" --mount "type=volume,source=$volume,target=/amp-runner-home")
	output="$(as_user "$user" "${args[@]}")"
	cid="$(jq -r '.containerId // empty' <<< "$output" | tail -n1)"
	[[ -n "$cid" ]] || die "devcontainer up did not return a container ID for $workspace"
	local uid gid
	uid="$(as_user "$user" devcontainer exec --container-id "$cid" id -u | tail -n1)"
	gid="$(as_user "$user" devcontainer exec --container-id "$cid" id -g | tail -n1)"
	docker exec --user root "$cid" sh -c "mkdir -p /amp-runner-home && chown $uid:$gid /amp-runner-home"
	printf '%s\n' "$cid"
}

devcontainer_amp() {
	local id="$1" cid="$2" token="${3:-}"
	shift 3
	local user
	if [[ -r "$(state_file "$id")" ]]; then
		user="$(state_value "$id" '.user')"
	else
		user="$(admin_user)"
	fi
	local args=(devcontainer exec --container-id "$cid" --remote-env HOME=/amp-runner-home --remote-env PATH=/amp-runner-home/.amp/bin:/usr/local/bin:/usr/bin:/bin)
	if [[ -n "$token" ]]; then
		devcontainer_store_token "$cid" "$token"
		# shellcheck disable=SC2016 # Expansion happens inside the dev container.
		as_user "$user" "${args[@]}" sh -c 'export AMP_API_KEY="$(cat /amp-runner-home/.amp-api-key)"; exec "$@"' sh amp "$@"
	else
		as_user "$user" "${args[@]}" amp "$@"
	fi
}

devcontainer_store_token() {
	local cid="$1" token="$2"
	printf '%s' "$token" | docker exec --interactive --user root "$cid" sh -c 'umask 077; cat > /amp-runner-home/.amp-api-key; chown --reference=/amp-runner-home /amp-runner-home/.amp-api-key; chmod 0400 /amp-runner-home/.amp-api-key'
}

prepare_devcontainer_amp() {
	local id="$1" cid="$2"
	local user
	if [[ -r "$(state_file "$id")" ]]; then
		user="$(state_value "$id" '.user')"
	else
		user="$(admin_user)"
	fi
	as_user "$user" devcontainer exec --container-id "$cid" --remote-env HOME=/amp-runner-home sh -lc 'test -x /amp-runner-home/.amp/bin/amp || curl -fsSL https://ampcode.com/install.sh | bash'
}

write_state() {
	local id="$1" mode="$2" user="$3" workspace="$4" project_ref="$5" remote="$6" auth="$7" remote_terminal="$8" docker_access="$9" base_repo="${10:-}" agent="${11:-amp}" native_remote="${12:-false}" shared_auth="${13:-false}" openchamber="${14:-false}" openchamber_port="${15:-0}"
	jq -n \
		--arg id "$id" --arg mode "$mode" --arg user "$user" --arg workspace "$workspace" \
		--arg project "$project_ref" --arg repositoryURL "$remote" --arg auth "$auth" --arg agent "$agent" \
		--arg service "$(service_name "$id")" --arg dockerAccess "$docker_access" \
		--arg baseRepository "$base_repo" --argjson remoteTerminal "$remote_terminal" --argjson nativeRemote "$native_remote" \
		--argjson sharedAuth "$shared_auth" \
		--argjson openchamber "$openchamber" --argjson openchamberPort "$openchamber_port" \
		--arg createdAt "$(date --iso-8601=seconds)" \
		'{id:$id,agent:$agent,mode:$mode,user:$user,workspace:$workspace,project:$project,repositoryURL:$repositoryURL,auth:$auth,service:$service,dockerAccess:$dockerAccess,baseRepository:$baseRepository,remoteTerminal:$remoteTerminal,nativeRemote:$nativeRemote,sharedAuth:$sharedAuth,openchamber:{enabled:$openchamber,port:$openchamberPort},desktop:{enabled:false,access:"",port:0,username:""},createdAt:$createdAt}' \
		> "$(state_file "$id")"
	chmod 0644 "$(state_file "$id")"
}

write_unit() {
	local id="$1" mode="$2" user="$3" auth="$4" agent="${5:-amp}" service unit_user='root' credential=''
	service="$(service_name "$id")"
	[[ "$mode" == host || "$mode" == worktree || "$mode" == devcontainer ]] && unit_user="$user"
	[[ "$agent" == amp && "$auth" == token ]] && credential="LoadCredential=amp_api_key:$(token_path "$id")"
	cat > "/etc/systemd/system/$service.service" <<EOF
[Unit]
Description=$agent agent workspace $id ($mode)
After=network-online.target docker.service
Wants=network-online.target
$([[ "$mode" == docker || "$mode" == devcontainer ]] && printf 'Requires=docker.service')
StartLimitIntervalSec=0

[Service]
Type=simple
User=$unit_user
WorkingDirectory=$INSTALL_DIR
$credential
ExecStart=$INSTALL_DIR/setup.sh _run $id
ExecStop=-$INSTALL_DIR/setup.sh _stop $id
Restart=always
RestartSec=5s
TimeoutStopSec=45s
KillMode=mixed
UMask=0077
Environment=AMP_RUNNER_INSTALL_DIR=$INSTALL_DIR
Environment=AMP_RUNNER_CONFIG_DIR=$CONFIG_DIR
Environment=AMP_RUNNER_DATA_DIR=$DATA_DIR
Environment=AMP_RUNNER_IMAGE=$IMAGE
Environment=HOME=$(user_home "$user")
Environment=PATH=/usr/local/bin:/opt/node/bin:/usr/local/go/bin:/opt/rust/cargo/bin:/usr/bin:/bin
$([[ -x /usr/local/bin/agent-browser-chrome ]] && printf 'Environment=AGENT_BROWSER_EXECUTABLE_PATH=/usr/local/bin/agent-browser-chrome')

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now "$service.service"
}

add_instance() {
	require_root add
	[[ -f "$CONFIG_DIR/.bootstrapped" ]] || die 'Run sudo amp-runner-setup bootstrap first.'

	local agent='' mode='' id='' auth='' token='' token_file='' requested_project='' requested_repository='' workspace='' clone_repo='' remote_terminal='' native_remote='' docker_access='none'
	local desktop='' desktop_access='' shared_auth='' openchamber='' openchamber_port=0
	while (($#)); do
		case "$1" in
		--agent) agent="$2"; shift ;;
		--shared-auth) shared_auth=true ;;
		--isolated-auth) shared_auth=false ;;
		--openchamber) openchamber=true ;;
		--no-openchamber) openchamber=false ;;
		--mode) mode="$2"; shift ;;
		--id) id="$2"; shift ;;
		--auth) auth="$2"; shift ;;
		--token-file) token_file="$2"; shift ;;
		--project) requested_project="$2"; shift ;;
		--repository | --repo) requested_repository="$2"; shift ;;
		--workspace) workspace="$2"; shift ;;
		--clone) clone_repo=true ;;
		--no-clone) clone_repo=false ;;
		--remote-terminal) remote_terminal=true ;;
		--no-remote-terminal) remote_terminal=false ;;
		--native-remote) native_remote=true ;;
		--no-native-remote) native_remote=false ;;
		--desktop) desktop=true ;;
		--no-desktop) desktop=false ;;
		--desktop-access) desktop_access="$2"; shift ;;
		--docker-access) docker_access="$2"; shift ;;
		*) die "Unknown add option: $1" ;;
		esac
		shift
	done

	ui_title 'Add agent workspace'
	[[ -n "$agent" ]] || agent="$(ui_choose 'Agent' "${AGENT_PROVIDERS[@]}")"
	validate_provider "$agent" || die "--agent must be one of $(provider_list_text)."

	if [[ "$agent" == amp ]]; then
		[[ -n "$mode" ]] || mode="$(ui_choose 'Instance type' 'host' 'docker' 'worktree' 'devcontainer')"
	else
		[[ -n "$mode" ]] || mode=docker
		[[ "$mode" == docker ]] || die 'Codex and Claude workspaces currently use Docker mode.'
	fi
	case "$mode" in host | docker | worktree | devcontainer) ;; *) die "Invalid mode: $mode" ;; esac
	if [[ "$agent" == amp && "$mode" == host ]] && find "$STATE_DIR" -name '*.json' -exec jq -e 'select((.agent // "amp") == "amp" and .mode == "host")' {} \; | grep -q .; then
		die 'A dedicated host runner already exists. Use docker, worktree, or devcontainer for another instance.'
	fi
	[[ -n "$id" ]] || id="$(ui_input 'Stable workspace ID' "$(hostname -s)-$agent-$mode")"
	id="$(slugify "$id")"
	validate_runner_id "$id" || die 'Runner ID must be one lowercase DNS label, up to 63 characters.'
	[[ ! -e "$(state_file "$id")" ]] || die "Runner already exists: $id"
	ensure_add_resources_available "$id"

	[[ -n "$auth" ]] || auth="$(ui_choose "$agent authentication" 'interactive' 'token')"
	case "$auth" in interactive | token) ;; *) die "Invalid authentication method: $auth" ;; esac
	# OpenCode brokers many model providers, so there is no single API key to mount.
	[[ "$agent" != opencode || "$auth" != token ]] || die 'OpenCode workspaces authenticate with opencode auth login; --auth token is not supported.'
	if [[ "$auth" == token ]]; then
		if [[ -n "$token_file" ]]; then
			[[ -r "$token_file" ]] || die "Cannot read token file: $token_file"
			token="$(cat "$token_file")"
		else
			have_tty || die '--token-file is required without a terminal.'
			token="$(ui_password "$agent API key")"
		fi
	fi

	local user project_json projects_json project_ref remote key='' volume="amp-runner-${id}-home" base_repo=''
	user="$(admin_user)"
	[[ -n "$workspace" ]] || workspace="$DATA_DIR/workspaces/$id"
	[[ "$workspace" == /* ]] || die 'Workspace must be an absolute path.'
	ADD_TRANSACTION_ACTIVE=true
	ADD_TRANSACTION_ID="$id"
	ADD_TRANSACTION_WORKSPACE="$workspace"
	ADD_TRANSACTION_WORKSPACE_CREATED=false
	ADD_TRANSACTION_VOLUME_CREATED=false
	ADD_TRANSACTION_DESKTOP_VOLUME_CREATED=false
	ADD_TRANSACTION_SECRET_CREATED=false
	ADD_TRANSACTION_BASE_REPO=''
	ADD_TRANSACTION_USER="$user"
	[[ -e "$workspace" ]] || ADD_TRANSACTION_WORKSPACE_CREATED=true
	if [[ "$mode" == docker ]] && ! docker volume inspect "$volume" >/dev/null 2>&1; then ADD_TRANSACTION_VOLUME_CREATED=true; fi
	if ! docker volume inspect "amp-runner-${id}-desktop" >/dev/null 2>&1; then ADD_TRANSACTION_DESKTOP_VOLUME_CREATED=true; fi
	trap rollback_add_instance EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	install -d -m 0755 "$workspace"

	if [[ "$auth" == token ]]; then
		local owner=root
		[[ "$mode" == docker ]] && owner=1000
		[[ "$mode" == devcontainer ]] && owner="$user"
		store_token "$id" "$token" "$owner" "$agent"
		ADD_TRANSACTION_SECRET_CREATED=true
		key="$(token_path "$id")"
	fi

	if [[ "$agent" == amp ]]; then
		case "$mode" in
		host | worktree)
			authenticate_host "$user" "$auth" "$token"
			projects_json="$(list_projects_host "$user" "$auth" "$token")"
			;;
		docker)
			docker volume create "$volume" >/dev/null
			chown 1000:1000 "$workspace"
			authenticate_container "$id" "$workspace" "$volume" "$auth" "$key"
			projects_json="$(list_projects_container "$id" "$workspace" "$volume" "$key")"
			;;
		devcontainer)
			authenticate_host "$user" "$auth" "$token"
			projects_json="$(list_projects_host "$user" "$auth" "$token")"
			;;
		esac
	else
		docker volume create "$volume" >/dev/null
		chown 1000:1000 "$workspace"
		ensure_github_login "$user"
		projects_json="$(list_github_repositories "$user")"
	fi

	if [[ "$agent" == amp ]]; then
		project_json="$(choose_project "$projects_json" "${requested_project:-$requested_repository}")"
	else
		project_json="$(choose_project "$projects_json" "${requested_repository:-$requested_project}")"
	fi
	project_ref="$(jq -r '.namespace + "/" + .name' <<< "$project_json")"
	remote="$(jq -r '.repositoryURL' <<< "$project_json")"
	[[ -n "$remote" && "$remote" != null ]] || die "Project $project_ref has no repository URL."
	if [[ -z "$clone_repo" ]]; then
		have_tty || die 'Pass --clone or --no-clone without a terminal.'
		if ui_confirm "Clone $remote now?" yes; then clone_repo=true; else clone_repo=false; fi
	fi
	if [[ "$agent" != amp ]]; then
		remote_terminal=false
	elif [[ -z "$remote_terminal" ]]; then
		if have_tty && ui_confirm 'Enable web terminal access for remotely controlled threads?' no; then remote_terminal=true; else remote_terminal=false; fi
	fi
	if ! provider_supports_native_remote "$agent"; then
		[[ "$native_remote" != true ]] || die '--native-remote is for Codex and Claude workspaces.'
		native_remote=false
	elif [[ "$auth" == token ]]; then
		[[ "$native_remote" != true ]] || die 'Native Remote Control requires provider account login; API keys are not supported.'
		native_remote=false
	elif [[ -z "$native_remote" ]]; then
		if have_tty; then
			local native_remote_default=yes
			if [[ "$agent" == codex ]]; then native_remote_default=no; fi
			if ui_confirm "Enable $agent native Remote Control?" "$native_remote_default"; then native_remote=true; else native_remote=false; fi
		else
			if [[ "$agent" == claude ]]; then native_remote=true; else native_remote=false; fi
		fi
	fi
	if [[ -z "$desktop" ]]; then
		local desktop_default=no
		if [[ "$agent" != amp ]]; then desktop_default=yes; fi
		if have_tty && ui_confirm 'Enable the secure web workspace with terminal, browsers, and files?' "$desktop_default"; then desktop=true; else desktop=false; fi
	fi
	if [[ "$desktop" == true && -z "$desktop_access" ]]; then
		have_tty || die '--desktop-access tailscale or --desktop-access ssh is required with --desktop.'
		if tailscale_online; then desktop_access="$(ui_choose 'Secure web workspace access' 'tailscale' 'ssh')"; else desktop_access=ssh; fi
	fi
	if [[ "$desktop" == true ]]; then
		case "$desktop_access" in tailscale | ssh) ;; *) die '--desktop-access must be tailscale or ssh.' ;; esac
	fi
	# Shared auth is a provider config-directory mount, so it only applies to the
	# account-login Codex and Claude workspaces. API keys stay per-workspace files.
	if [[ "$agent" == amp || "$auth" == token ]]; then
		[[ "$shared_auth" != true ]] || die '--shared-auth is for account-authenticated Codex and Claude workspaces.'
		shared_auth=false
	elif [[ -z "$shared_auth" ]]; then
		shared_auth=true
	fi
	# OpenChamber is a browser front end for a local opencode server, so it only
	# means anything for an OpenCode workspace.
	if [[ "$agent" != opencode ]]; then
		[[ "$openchamber" != true ]] || die '--openchamber is for OpenCode workspaces.'
		openchamber=false
	elif [[ -z "$openchamber" ]]; then
		if have_tty && ui_confirm 'Pair this OpenCode workspace with the OpenChamber browser interface?' no; then openchamber=true; else openchamber=false; fi
	fi
	case "$docker_access" in none | socket) ;; *) die '--docker-access must be none or socket.' ;; esac
	if [[ "$agent" != amp && "$docker_access" != none ]]; then
		die 'Docker socket access is not supported for Codex or Claude workspaces.'
	elif [[ "$agent" == amp && "$mode" == docker && "$docker_access" == none ]] && have_tty; then
		if ui_confirm 'Mount the host Docker socket? This gives the runner effective root access to the VM.' no; then docker_access=socket; fi
	fi

	case "$mode" in
	host)
		prepare_host_checkout "$user" "$workspace" "$project_ref" "$remote" "$clone_repo"
		usermod -aG docker "$user"
		;;
	worktree)
		base_repo="$(prepare_worktree "$user" "$workspace" "$project_ref" "$remote" "$clone_repo")"
		ADD_TRANSACTION_BASE_REPO="$base_repo"
		;;
	docker)
		prepare_container_checkout "$id" "$workspace" "$volume" "$key" "$project_ref" "$remote" "$clone_repo" "$agent" "$user"
		if [[ "$agent" != amp ]]; then authenticate_agent_container "$agent" "$id" "$workspace" "$volume" "$auth" "$shared_auth"; fi
		;;
	devcontainer)
		prepare_host_checkout "$user" "$workspace" "$project_ref" "$remote" "$clone_repo"
		[[ -f "$workspace/.devcontainer/devcontainer.json" || -f "$workspace/.devcontainer.json" ]] || die "No devcontainer.json found in $workspace"
		local cid
		cid="$(devcontainer_up "$id" "$workspace")"
		prepare_devcontainer_amp "$id" "$cid"
		if [[ "$auth" == token ]]; then
			devcontainer_amp "$id" "$cid" "$token" projects list --json >/dev/null
		elif ! devcontainer_amp "$id" "$cid" '' projects list --json >/dev/null 2>&1; then
			devcontainer_amp "$id" "$cid" '' login
		fi
		;;
	esac

	if [[ "$openchamber" == true ]]; then
		openchamber_port="$(next_openchamber_port)"
		write_desktop_secret "$(openchamber_password_path "$id")" "$(openssl rand -base64 18 | tr -d '\n/+=' | cut -c1-24)"
	fi
	write_state "$id" "$mode" "$user" "$workspace" "$project_ref" "$remote" "$auth" "$remote_terminal" "$docker_access" "$base_repo" "$agent" "$native_remote" "$shared_auth" "$openchamber" "$openchamber_port"
	write_unit "$id" "$mode" "$user" "$auth" "$agent"
	if [[ "$desktop" == true ]]; then enable_desktop "$id" --access "$desktop_access"; fi
	ADD_TRANSACTION_ACTIVE=false
	restore_provision_exit_trap
	say
	say "$agent workspace $id is installed for $project_ref."
	say "Status: sudo amp-runner-setup status $id"
	say "Logs:   sudo amp-runner-setup logs $id"
	say "CLI:    sudo amp-runner-setup connect $id"
	if [[ "$native_remote" == true ]]; then say "Remote: sudo amp-runner-setup remote status $id"; fi
}

parse_project_spec() {
	local spec="$1"
	PROJECT_SPEC_REF="$spec"
	PROJECT_SPEC_COUNT=1
	if [[ "$spec" =~ ^(.+)=([0-9]+)$ ]]; then
		PROJECT_SPEC_REF="${BASH_REMATCH[1]}"
		PROJECT_SPEC_COUNT="$((10#${BASH_REMATCH[2]}))"
	fi
	[[ -n "$PROJECT_SPEC_REF" && "$PROJECT_SPEC_COUNT" -ge 1 && "$PROJECT_SPEC_COUNT" -le 100 ]] || \
		die "Project count must be between 1 and 100: $spec"
}

next_runner_id() {
	local base suffix candidate collision=2
	base="$(slugify "$1")"
	suffix="${2:-}"
	base="${base:0:$((63 - ${#suffix}))}"
	candidate="$base$suffix"
	while [[ -e "$(state_file "$candidate")" ]]; do
		suffix="-$collision"
		base="${base:0:$((63 - ${#suffix}))}"
		candidate="$base$suffix"
		collision=$((collision + 1))
	done
	printf '%s\n' "$candidate"
}

provision_instances() {
	require_root provision
	[[ -f "$CONFIG_DIR/.bootstrapped" ]] || die 'Run sudo amp-runner-setup bootstrap first.'
	PROVISION_TEMP_TOKEN_FILE=''

	local agent='' mode='' auth='' token_file='' generated_token_file='' token='' clone_repo='' remote_terminal='' native_remote='' docker_access='none'
	local desktop='' desktop_access='' shared_auth='' openchamber=''
	local -a requested_specs=()
	while (($#)); do
		case "$1" in
		--agent) agent="$2"; shift ;;
		--shared-auth) shared_auth=true ;;
		--isolated-auth) shared_auth=false ;;
		--openchamber) openchamber=true ;;
		--no-openchamber) openchamber=false ;;
		--mode) mode="$2"; shift ;;
		--auth) auth="$2"; shift ;;
		--token-file) token_file="$2"; shift ;;
		--project | --repository | --repo) requested_specs+=("$2"); shift ;;
		--clone) clone_repo=true ;;
		--no-clone) clone_repo=false ;;
		--remote-terminal) remote_terminal=true ;;
		--no-remote-terminal) remote_terminal=false ;;
		--native-remote) native_remote=true ;;
		--no-native-remote) native_remote=false ;;
		--desktop) desktop=true ;;
		--no-desktop) desktop=false ;;
		--desktop-access) desktop_access="$2"; shift ;;
		--docker-access) docker_access="$2"; shift ;;
		*) die "Unknown provision option: $1" ;;
		esac
		shift
	done

	ui_title 'Provision agent fleet'
	[[ -n "$agent" ]] || agent="$(ui_choose 'Agent' "${AGENT_PROVIDERS[@]}")"
	validate_provider "$agent" || die "--agent must be one of $(provider_list_text)."

	if [[ "$agent" == amp ]]; then
		[[ -n "$mode" ]] || mode="$(ui_choose 'Runtime isolation' 'docker' 'worktree' 'devcontainer' 'host')"
	else
		[[ -n "$mode" ]] || mode=docker
		[[ "$mode" == docker ]] || die 'Codex and Claude workspaces currently use Docker mode.'
	fi
	case "$mode" in host | docker | worktree | devcontainer) ;; *) die "Invalid mode: $mode" ;; esac
	[[ -n "$auth" ]] || auth="$(ui_choose "$agent authentication" 'token' 'interactive')"
	case "$auth" in interactive | token) ;; *) die "Invalid authentication method: $auth" ;; esac
	# OpenCode brokers many model providers, so there is no single API key to mount.
	[[ "$agent" != opencode || "$auth" != token ]] || die 'OpenCode workspaces authenticate with opencode auth login; --auth token is not supported.'
	if [[ "$auth" == token ]]; then
		if [[ -n "$token_file" ]]; then
			[[ -r "$token_file" ]] || die "Cannot read token file: $token_file"
			token="$(cat "$token_file")"
		else
			have_tty || die '--token-file is required without a terminal.'
			token="$(ui_password "$agent API key")"
			token_file="$(mktemp)"
			generated_token_file="$token_file"
			PROVISION_TEMP_TOKEN_FILE="$token_file"
			chmod 0600 "$token_file"
			printf '%s' "$token" > "$token_file"
			# Capture the path now because this local variable is gone when the EXIT trap runs.
			# shellcheck disable=SC2064
			trap "rm -f -- $(printf '%q' "$generated_token_file")" EXIT
		fi
	fi

	[[ -n "$clone_repo" ]] || {
		if have_tty && ui_confirm 'Clone every selected repository?' yes; then clone_repo=true; else clone_repo=false; fi
	}
	if [[ "$agent" != amp ]]; then remote_terminal=false; fi
	[[ -n "$remote_terminal" ]] || {
		if have_tty && ui_confirm 'Enable web terminal access for these runners?' no; then remote_terminal=true; else remote_terminal=false; fi
	}
	if ! provider_supports_native_remote "$agent"; then
		[[ "$native_remote" != true ]] || die '--native-remote is for Codex and Claude workspaces.'
		native_remote=false
	elif [[ "$auth" == token ]]; then
		[[ "$native_remote" != true ]] || die 'Native Remote Control requires provider account login; API keys are not supported.'
		native_remote=false
	elif [[ -z "$native_remote" ]]; then
		if have_tty; then
			local native_remote_default=yes
			if [[ "$agent" == codex ]]; then native_remote_default=no; fi
			if ui_confirm "Enable $agent native Remote Control for every workspace?" "$native_remote_default"; then native_remote=true; else native_remote=false; fi
		else
			if [[ "$agent" == claude ]]; then native_remote=true; else native_remote=false; fi
		fi
	fi
	[[ -n "$desktop" ]] || {
		local desktop_default=no
		if [[ "$agent" != amp ]]; then desktop_default=yes; fi
		if have_tty && ui_confirm 'Enable secure web workspaces for these runners?' "$desktop_default"; then desktop=true; else desktop=false; fi
	}
	if [[ "$desktop" == true && -z "$desktop_access" ]]; then
		have_tty || die '--desktop-access tailscale or --desktop-access ssh is required with --desktop.'
		if tailscale_online; then desktop_access="$(ui_choose 'Secure web workspace access' 'tailscale' 'ssh')"; else desktop_access=ssh; fi
	fi
	if [[ "$desktop" == true ]]; then
		case "$desktop_access" in tailscale | ssh) ;; *) die '--desktop-access must be tailscale or ssh.' ;; esac
	fi
	# Shared auth is what makes a fleet a one-login operation instead of one login per runner.
	if [[ "$agent" == amp || "$auth" == token ]]; then
		[[ "$shared_auth" != true ]] || die '--shared-auth is for account-authenticated Codex and Claude workspaces.'
		shared_auth=false
	elif [[ -z "$shared_auth" ]]; then
		shared_auth=true
	fi
	# OpenChamber is a browser front end for a local opencode server, so it only
	# means anything for an OpenCode workspace.
	if [[ "$agent" != opencode ]]; then
		[[ "$openchamber" != true ]] || die '--openchamber is for OpenCode workspaces.'
		openchamber=false
	elif [[ -z "$openchamber" ]]; then
		if have_tty && ui_confirm 'Pair this OpenCode workspace with the OpenChamber browser interface?' no; then openchamber=true; else openchamber=false; fi
	fi
	case "$docker_access" in none | socket) ;; *) die '--docker-access must be none or socket.' ;; esac
	if [[ "$agent" != amp && "$docker_access" != none ]]; then
		die 'Docker socket access is not supported for Codex or Claude workspaces.'
	elif [[ "$agent" == amp && "$mode" == docker && "$docker_access" == none ]] && have_tty; then
		if ui_confirm 'Mount the host Docker socket in every runner? This grants effective host root access.' no; then docker_access=socket; fi
	fi

	local user projects_json
	user="$(admin_user)"
	if [[ "$auth" == token ]]; then
		token="${token:-$(cat "$token_file")}"
	fi
	if [[ "$agent" == amp ]]; then
		authenticate_host "$user" "$auth" "$token"
		projects_json="$(list_projects_host "$user" "$auth" "$token")"
	else
		ensure_github_login "$user"
		projects_json="$(list_github_repositories "$user")"
	fi

	if ((${#requested_specs[@]} == 0)); then
		have_tty || die 'Pass at least one --repository OWNER/REPO[=COUNT] without a terminal.'
		local -a project_options selected_options
		mapfile -t project_options < <(jq -r '.[] | (.namespace + "/" + .name + "\t" + .repositoryURL)' <<< "$projects_json")
		((${#project_options[@]} > 0)) || die "No repositories are available for $agent."
		project_options=('[all repositories]' "${project_options[@]}")
		mapfile -t selected_options < <(ui_choose_many "Select repositories for $agent" "${project_options[@]}")
		((${#selected_options[@]} > 0)) || die 'No projects selected.'
		local selected ref count
		if printf '%s\n' "${selected_options[@]}" | grep -Fxq '[all repositories]'; then
			mapfile -t selected_options < <(jq -r '.[] | .namespace + "/" + .name' <<< "$projects_json")
		fi
		for selected in "${selected_options[@]}"; do
			[[ "$selected" == '[all repositories]' ]] && continue
			ref="${selected%%$'\t'*}"
			count="$(ui_input "Workspace count for $ref" 1)"
			[[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 && "$count" -le 100 ]] || die "Runner count must be between 1 and 100: $count"
			count="$((10#$count))"
			requested_specs+=("$ref=$count")
		done
	fi

	local -a project_refs=() project_counts=()
	local spec project_json project_ref total=0
	declare -A seen_projects=()
	for spec in "${requested_specs[@]}"; do
		parse_project_spec "$spec"
		project_json="$(choose_project "$projects_json" "$PROJECT_SPEC_REF")"
		project_ref="$(jq -r '.namespace + "/" + .name' <<< "$project_json")"
		[[ -z "${seen_projects[$project_ref]:-}" ]] || die "Project selected more than once: $project_ref"
		seen_projects[$project_ref]=1
		project_refs+=("$project_ref")
		project_counts+=("$PROJECT_SPEC_COUNT")
		total=$((total + PROJECT_SPEC_COUNT))
	done
	if [[ "$mode" == host && "$total" -ne 1 ]]; then
		die 'Host mode supports one runner. Use docker, worktree, or devcontainer for a fleet.'
	fi

	ui_title "Provisioning plan: $total $agent workspace(s)"
	local index
	for index in "${!project_refs[@]}"; do
		printf '  %-32s %s\n' "${project_refs[$index]}" "${project_counts[$index]} x $agent/$mode"
	done
	if [[ "$desktop" == true ]]; then printf '  %-32s %s\n' 'Web workspace' "$desktop_access access for every runner"; fi
	if [[ "$native_remote" == true ]]; then printf '  %-32s %s\n' 'Native Remote Control' "enabled for every $agent workspace"; fi
	if [[ "$shared_auth" == true ]]; then
		printf '  %-32s %s\n' 'Authentication' "one shared $agent login for the whole fleet"
	elif [[ "$auth" == interactive ]]; then
		printf '  %-32s %s\n' 'Authentication' "a separate $agent login for every runner"
	fi
	if have_tty; then
		if ! ui_confirm 'Create this agent fleet?' yes; then
			if [[ -n "$generated_token_file" ]]; then
				rm -f -- "$generated_token_file"
				PROVISION_TEMP_TOKEN_FILE=''
				trap - EXIT
			fi
			return 0
		fi
	fi

	local project_count runner_index id suffix
	for index in "${!project_refs[@]}"; do
		project_ref="${project_refs[$index]}"
		project_count="${project_counts[$index]}"
		for ((runner_index = 1; runner_index <= project_count; runner_index++)); do
			suffix=''
			if ((project_count > 1)); then suffix="-$runner_index"; fi
			id="$(next_runner_id "$project_ref-$agent-$mode" "$suffix")"
			local -a add_args=(--agent "$agent" --mode "$mode" --id "$id" --auth "$auth" --repository "$project_ref" --docker-access "$docker_access")
			[[ "$auth" == token ]] && add_args+=(--token-file "$token_file")
			if [[ "$clone_repo" == true ]]; then add_args+=(--clone); else add_args+=(--no-clone); fi
			if [[ "$remote_terminal" == true ]]; then add_args+=(--remote-terminal); else add_args+=(--no-remote-terminal); fi
			if [[ "$native_remote" == true ]]; then add_args+=(--native-remote); else add_args+=(--no-native-remote); fi
			if [[ "$shared_auth" == true ]]; then add_args+=(--shared-auth); else add_args+=(--isolated-auth); fi
			if [[ "$openchamber" == true ]]; then add_args+=(--openchamber); else add_args+=(--no-openchamber); fi
			if [[ "$desktop" == true ]]; then add_args+=(--desktop --desktop-access "$desktop_access"); else add_args+=(--no-desktop); fi
			add_instance "${add_args[@]}"
		done
	done

	if [[ -n "$generated_token_file" ]]; then
		rm -f -- "$generated_token_file"
		PROVISION_TEMP_TOKEN_FILE=''
		trap - EXIT
	fi
	say
	say "Provisioned $total $agent workspace(s)."
}

runner_flags() {
	local id="$1" remote_terminal
	remote_terminal="$(state_value "$id" '.remoteTerminal')"
	RUNNER_FLAGS=(--no-tui --runner-id "$id")
	if [[ "$remote_terminal" == true ]]; then
		RUNNER_FLAGS+=(--remote-control-terminal)
	fi
}

load_service_token() {
	SERVICE_TOKEN=''
	if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -r "$CREDENTIALS_DIRECTORY/amp_api_key" ]]; then
		SERVICE_TOKEN="$(cat "$CREDENTIALS_DIRECTORY/amp_api_key")"
	fi
}

run_host_instance() {
	local id="$1" workspace amp
	workspace="$(state_value "$id" '.workspace')"
	amp="$(user_home "$(state_value "$id" '.user')")/.amp/bin/amp"
	load_service_token
	runner_flags "$id"
	cd "$workspace"
	if [[ -n "$SERVICE_TOKEN" ]]; then
		export AMP_API_KEY="$SERVICE_TOKEN"
	fi
	exec "$amp" "${RUNNER_FLAGS[@]}"
}

run_agent_container() {
	local agent="$1" id="$2" workspace volume name network key='' native_remote shared_auth
	workspace="$(state_value "$id" '.workspace')"
	volume="amp-runner-${id}-home"
	name="amp-runner-$id"
	network="amp-runner-$id"
	native_remote="$(native_remote_enabled "$id")"
	shared_auth="$(shared_auth_enabled "$id")"
	[[ "$(state_value "$id" '.auth')" == token ]] && key="$(token_path "$id")"
	docker rm --force "$name" >/dev/null 2>&1 || true
	docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
	container_agent_common_args "$id" "$workspace" "$volume" "$agent" "$key" "$shared_auth"
	CONTAINER_ARGS+=(--name "$name" --network "$network" --init --stop-timeout 30 --cap-drop ALL --pids-limit 4096)
	if [[ "$agent" == codex ]]; then
		# Codex's Linux sandbox uses bubblewrap namespaces. These are narrower than --privileged,
		# but still weaken Docker's default isolation and should only be used for trusted images.
		CONTAINER_ARGS+=(--cap-add SYS_ADMIN --cap-add SYS_CHROOT --cap-add SETUID --cap-add SETGID --cap-add SYS_PTRACE
			--security-opt seccomp=unconfined --security-opt apparmor=unconfined)
	else
		CONTAINER_ARGS+=(--security-opt no-new-privileges:true)
	fi
	if [[ "$native_remote" == true && "$(state_value "$id" '.auth')" == interactive ]]; then
		CONTAINER_ARGS+=(--env "AGENT_WORKSPACE_ID=$id")
		case "$agent" in
		codex)
			exec docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c '
				trap '\''codex remote-control stop >/dev/null 2>&1 || true; exit 0'\'' TERM INT
				announced=0
				until codex remote-control start; do
					codex remote-control stop >/dev/null 2>&1 || true
					if [ "$announced" -eq 0 ]; then
						echo "Codex experimental Remote Control could not start. It retries every 30 seconds. Authenticate with: sudo amp-runner-setup authenticate $AGENT_WORKSPACE_ID" >&2
						announced=1
					fi
					sleep 30
				done
				# The daemon writes its PID file asynchronously, so give it a start
				# window before the watchdog treats a missing file as a crash.
				waited=0
				while [ "$waited" -lt 60 ]; do
					pid="$(jq -r '\''.pid // empty'\'' /agent-home/.codex/app-server-daemon/app-server.pid 2>/dev/null || true)"
					[ -n "$pid" ] && break
					waited=$((waited + 1))
					sleep 1
				done
				echo "Codex Remote Control is running. Pair it with: sudo amp-runner-setup remote pair $AGENT_WORKSPACE_ID" >&2
				while :; do
					pid="$(jq -r '\''.pid // empty'\'' /agent-home/.codex/app-server-daemon/app-server.pid 2>/dev/null || true)"
					[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || exit 1
					sleep 30
				done'
			;;
		claude)
			# Remote Control needs a claude.ai account token; an API key makes it refuse.
			# claude auth status already reports JSON and exits non-zero when signed out,
			# so use its exit status instead of parsing an assumed field name.
			exec docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c '
				unset ANTHROPIC_API_KEY
				if ! claude auth status >/dev/null 2>&1; then
					echo "Claude Remote Control is waiting for claude.ai login. It starts automatically once you run: sudo amp-runner-setup authenticate $AGENT_WORKSPACE_ID" >&2
					while ! claude auth status >/dev/null 2>&1; do sleep 30; done
					echo "Claude login detected. Starting Remote Control." >&2
				fi
				exec claude remote-control --name "$AGENT_WORKSPACE_ID" --spawn same-dir'
			;;
		esac
	fi
	if [[ "$agent" == opencode && "$(openchamber_enabled "$id")" == true ]]; then
		local chamber_port
		chamber_port="$(jq -r '.openchamber.port // 0' "$(state_file "$id")")"
		[[ "$chamber_port" != 0 ]] || die "Runner $id has no OpenChamber port."
		# Published to host loopback only. The in-container bind must be broad for
		# Docker to forward the published port.
		CONTAINER_ARGS+=(--env "AGENT_WORKSPACE_ID=$id"
			--publish "127.0.0.1:$chamber_port:3000"
			--mount "type=bind,source=$(openchamber_password_path "$id"),target=/run/secrets/openchamber_password,readonly")
		exec docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c '
			opencode serve --hostname 127.0.0.1 --port 4096 &
			opencode_pid=$!
			trap '\''kill "$opencode_pid" 2>/dev/null || true; exit 0'\'' TERM INT
			waited=0
			while [ "$waited" -lt 60 ]; do
				curl -fsS -o /dev/null "http://127.0.0.1:4096/" 2>/dev/null && break
				kill -0 "$opencode_pid" 2>/dev/null || exit 1
				waited=$((waited + 1))
				sleep 1
			done
			# Attach to the server started above instead of letting OpenChamber spawn
			# its own, so both halves share one workspace and one login.
			OPENCODE_HOST=http://127.0.0.1 OPENCODE_PORT=4096 OPENCODE_SKIP_START=true \
				OPENCHAMBER_UI_PASSWORD="$(cat /run/secrets/openchamber_password)" \
				exec openchamber serve --host 0.0.0.0 --port 3000'
	fi
	exec docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c 'trap "exit 0" TERM INT; while :; do sleep 3600; done'
}

run_container_instance() {
	local id="$1" workspace volume name network key='' access socket_gid agent
	agent="$(agent_provider "$id")"
	if [[ "$agent" != amp ]]; then
		run_agent_container "$agent" "$id"
	fi
	workspace="$(state_value "$id" '.workspace')"
	volume="amp-runner-${id}-home"
	name="amp-runner-$id"
	network="amp-runner-$id"
	access="$(state_value "$id" '.dockerAccess')"
	[[ "$(state_value "$id" '.auth')" == token ]] && key="$(token_path "$id")"
	docker rm --force "$name" >/dev/null 2>&1 || true
	docker network inspect "$network" >/dev/null 2>&1 || docker network create "$network" >/dev/null
	container_common_args "$id" "$workspace" "$volume" "$key"
	CONTAINER_ARGS+=(--name "$name" --network "$network" --init --stop-timeout 30 --cap-drop ALL --security-opt no-new-privileges:true --pids-limit 4096)
	if [[ "$access" == socket ]]; then
		socket_gid="$(stat -c %g /var/run/docker.sock)"
		CONTAINER_ARGS+=(--volume /var/run/docker.sock:/var/run/docker.sock --group-add "$socket_gid")
	fi
	runner_flags "$id"
	exec docker run "${CONTAINER_ARGS[@]}" "$IMAGE" amp "${RUNNER_FLAGS[@]}"
}

run_devcontainer_instance() {
	local id="$1" workspace cid token=''
	workspace="$(state_value "$id" '.workspace')"
	cid="$(devcontainer_up "$id" "$workspace")"
	prepare_devcontainer_amp "$id" "$cid"
	load_service_token
	token="$SERVICE_TOKEN"
	[[ -n "$token" ]] && devcontainer_store_token "$cid" "$token"
	runner_flags "$id"
	local -a args=(devcontainer exec \
		--container-id "$cid" \
		--remote-env HOME=/amp-runner-home \
		--remote-env PATH=/amp-runner-home/.amp/bin:/usr/local/bin:/usr/bin:/bin)
	if [[ -n "$token" ]]; then
		# shellcheck disable=SC2016 # Expansion happens inside the dev container.
		args+=(sh -c 'export AMP_API_KEY="$(cat /amp-runner-home/.amp-api-key)"; exec "$@"' sh amp "${RUNNER_FLAGS[@]}")
	else
		args+=(amp "${RUNNER_FLAGS[@]}")
	fi
	exec env HOME="$(user_home "$(state_value "$id" '.user')")" "${args[@]}"
}

run_instance() {
	local id="$1" mode
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	mode="$(state_value "$id" '.mode')"
	case "$mode" in
	host | worktree) run_host_instance "$id" ;;
	docker) run_container_instance "$id" ;;
	devcontainer) run_devcontainer_instance "$id" ;;
	esac
}

stop_instance_runtime() {
	local id="$1" mode cid workspace
	[[ -r "$(state_file "$id")" ]] || return 0
	mode="$(state_value "$id" '.mode')"
	case "$mode" in
	docker)
		docker stop --time 30 "amp-runner-$id" >/dev/null 2>&1 || true
		;;
	devcontainer)
		workspace="$(state_value "$id" '.workspace')"
		cid="$(docker ps --filter "label=devcontainer.local_folder=$workspace" --format '{{.ID}}' | head -n1)"
		if [[ -n "$cid" ]]; then
			docker exec "$cid" pkill -TERM -f "amp --no-tui --runner-id $id" >/dev/null 2>&1 || true
		fi
		;;
	esac
}

list_instances() {
	require_root list
	printf '%-28s %-8s %-13s %-10s %-10s %-28s %s\n' WORKSPACE AGENT MODE STATUS DESKTOP REPOSITORY PATH
	local file id service status desktop
	shopt -s nullglob
	for file in "$STATE_DIR"/*.json; do
		id="$(jq -r '.id' "$file")"
		service="$(jq -r '.service' "$file")"
		status="$(systemctl is-active "$service.service" 2>/dev/null || true)"
		desktop="$(jq -r 'if .desktop.enabled == true then .desktop.access else "off" end' "$file")"
		printf '%-28s %-8s %-13s %-10s %-10s %-28s %s\n' "$id" "$(jq -r '.agent // "amp"' "$file")" "$(jq -r '.mode' "$file")" "$status" "$desktop" "$(jq -r '.project' "$file")" "$(jq -r '.workspace' "$file")"
	done
	shopt -u nullglob
}

show_status() {
	require_root status
	local id="$1"
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	jq . "$(state_file "$id")"
	systemctl --no-pager --full status "$(service_name "$id").service" || true
}

show_logs() {
	require_root logs
	local id="$1" follow="${2:-}"
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	local args=(-u "$(service_name "$id").service" -n 200 --no-pager)
	[[ "$follow" == --follow || "$follow" == -f ]] && args=(-u "$(service_name "$id").service" -f)
	journalctl "${args[@]}"
}

control_instance() {
	require_root "$1"
	local action="$1" id="$2"
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	case "$action" in start | stop | restart) ;; *) die "Invalid runner action: $action" ;; esac
	systemctl "$action" "$(service_name "$id").service"
	say "Agent workspace $id: $action requested."
}

ensure_instance_running() {
	local id="$1" service mode attempt
	service="$(service_name "$id")"
	if ! systemctl is-active --quiet "$service.service"; then
		systemctl start "$service.service"
	fi
	mode="$(state_value "$id" '.mode')"
	if [[ "$mode" == docker ]]; then
		for ((attempt = 1; attempt <= 30; attempt++)); do
			if [[ "$(docker inspect --format '{{.State.Running}}' "amp-runner-$id" 2>/dev/null || true)" == true ]]; then return; fi
			sleep 0.5
		done
		die "Container amp-runner-$id did not become ready. Check: sudo amp-runner-setup logs $id"
	fi
}

connect_instance() {
	require_root connect
	local id="$1" agent mode
	shift
	if (($#)) && [[ "$1" == -- ]]; then shift; fi
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	agent="$(agent_provider "$id")"
	mode="$(state_value "$id" '.mode')"
	[[ "$agent" != amp && "$mode" == docker ]] || die 'connect is for Docker-backed Codex and Claude workspaces.'
	ensure_instance_running "$id"
	local -a terminal=(--interactive)
	if [[ -t 0 && -t 1 ]]; then terminal+=(--tty); fi
	docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" "$agent" "$@"
}

shell_instance() {
	require_root shell
	local id="$1" mode agent
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	mode="$(state_value "$id" '.mode')"
	[[ "$mode" == docker ]] || die 'shell currently supports Docker-backed workspaces.'
	agent="$(agent_provider "$id")"
	ensure_instance_running "$id"
	local -a terminal=(--interactive)
	if [[ -t 0 && -t 1 ]]; then terminal+=(--tty); fi
	if [[ "$agent" == amp ]]; then
		docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" bash
	else
		docker exec "${terminal[@]}" --env HOME=/agent-home --workdir /workspace "amp-runner-$id" bash
	fi
}

authenticate_agent_instance() {
	require_root authenticate
	local id="$1" agent
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	agent="$(agent_provider "$id")"
	[[ "$agent" != amp && "$(state_value "$id" '.mode')" == docker ]] || die 'authenticate is for Docker-backed Codex and Claude workspaces.'
	have_tty || die 'authenticate requires an interactive terminal.'
	ensure_instance_running "$id"
	local -a terminal=(--interactive)
	if [[ -t 0 && -t 1 ]]; then terminal+=(--tty); fi
	case "$agent" in
		codex) docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" codex login --device-auth ;;
		opencode) docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" opencode auth login ;;
		claude)
			docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" claude auth login
			say 'Claude will open once so you can accept workspace trust. Exit Claude after accepting.'
			docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" claude
			;;
	esac
	if [[ "$(shared_auth_enabled "$id")" == true ]]; then
		say "This login is shared with every workspace that uses the shared $agent credentials."
	fi
	if [[ "$(native_remote_enabled "$id")" == true ]]; then
		systemctl restart "$(service_name "$id").service"
		say "Restarted $id with native Remote Control."
	fi
}

write_auth_method() {
	local id="$1" method="$2" file tmp
	file="$(state_file "$id")"
	tmp="$(mktemp "${file}.XXXXXX")"
	jq --arg method "$method" '.auth = $method' "$file" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
}

write_native_remote() {
	local id="$1" enabled="$2" file tmp
	file="$(state_file "$id")"
	tmp="$(mktemp "${file}.XXXXXX")"
	jq --argjson enabled "$enabled" '.nativeRemote = $enabled' "$file" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
}

native_remote_status() {
	require_root remote
	local id="$1" agent enabled service_state runtime_state=inactive
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	agent="$(agent_provider "$id")"
	[[ "$agent" != amp && "$(state_value "$id" '.mode')" == docker ]] || die 'remote is for Docker-backed Codex and Claude workspaces.'
	enabled="$(native_remote_enabled "$id")"
	service_state="$(systemctl is-active "$(service_name "$id").service" 2>/dev/null || true)"
	if [[ "$(docker inspect --format '{{.State.Running}}' "amp-runner-$id" 2>/dev/null || true)" == true ]]; then
		case "$agent" in
		codex)
			if docker exec "amp-runner-$id" sh -c 'pid="$(jq -r '\''.pid // empty'\'' /agent-home/.codex/app-server-daemon/app-server.pid 2>/dev/null || true)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null'; then
				runtime_state=running
			elif ! docker exec "amp-runner-$id" codex login status >/dev/null 2>&1; then
				runtime_state='awaiting login'
			fi
			;;
		claude)
			if docker exec "amp-runner-$id" pgrep -f 'claude remote-control' >/dev/null 2>&1; then
				runtime_state=running
			elif ! docker exec "amp-runner-$id" claude auth status >/dev/null 2>&1; then
				runtime_state='awaiting login'
			fi
			;;
		esac
	fi
	printf 'Workspace: %s\nProvider: %s\nConfigured: %s\nService: %s\nRemote runtime: %s\n' "$id" "$agent" "$enabled" "$service_state" "$runtime_state"
	if [[ "$runtime_state" == 'awaiting login' ]]; then
		# The container stays up and polls, so this resolves without a restart.
		printf 'Sign in to start it: sudo amp-runner-setup authenticate %s\n' "$id"
	elif [[ "$agent" == codex && "$runtime_state" == running ]]; then
		printf 'Pair a device: sudo amp-runner-setup remote pair %s\n' "$id"
	elif [[ "$agent" == claude && "$runtime_state" == running ]]; then
		printf 'Open https://claude.ai/code or the Claude mobile app with the authenticated account.\n'
	fi
}

native_remote_command() {
	local action="${1:-}" id="${2:-}" agent
	[[ -n "$action" && -n "$id" && $# == 2 ]] || die 'remote requires enable, disable, status, or pair and RUNNER_ID.'
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	agent="$(agent_provider "$id")"
	[[ "$agent" != amp && "$(state_value "$id" '.mode')" == docker ]] || die 'remote is for Docker-backed Codex and Claude workspaces.'
	case "$action" in
	enable)
		require_root remote
		[[ "$(state_value "$id" '.auth')" == interactive ]] || die 'Native Remote Control requires provider account login. Clear the API key first.'
		write_native_remote "$id" true
		systemctl restart "$(service_name "$id").service"
		say "$agent native Remote Control enabled for $id."
		;;
	disable)
		require_root remote
		write_native_remote "$id" false
		systemctl restart "$(service_name "$id").service"
		say "$agent native Remote Control disabled for $id."
		;;
	status) native_remote_status "$id" ;;
	pair)
		require_root remote
		[[ "$agent" == codex ]] || die 'Claude sessions appear directly at https://claude.ai/code and do not use a pairing command.'
		[[ "$(native_remote_enabled "$id")" == true ]] || die "Enable native Remote Control first: sudo amp-runner-setup remote enable $id"
		ensure_instance_running "$id"
		# Pairing prints a code and waits for confirmation, so it needs a TTY and the
		# project directory, matching connect, shell, and authenticate.
		local -a terminal=(--interactive)
		if [[ -t 0 && -t 1 ]]; then terminal+=(--tty); fi
		docker exec "${terminal[@]}" --workdir /workspace "amp-runner-$id" codex remote-control pair
		;;
	*) die 'remote expects enable, disable, status, or pair.' ;;
	esac
}

set_agent_api_key() {
	require_root credentials
	local id="$1" token_file="${2:-}" agent token
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	agent="$(agent_provider "$id")"
	[[ "$agent" != amp ]] || die 'credentials set currently supports Codex and Claude workspaces.'
	if [[ -n "$token_file" ]]; then
		[[ -r "$token_file" ]] || die "Cannot read token file: $token_file"
		token="$(cat "$token_file")"
	else
		have_tty || die 'Pass --token-file PATH without a terminal.'
		token="$(ui_password "$agent API key")"
	fi
	store_token "$id" "$token" 1000 "$agent"
	write_auth_method "$id" token
	write_native_remote "$id" false
	systemctl restart "$(service_name "$id").service"
	if desktop_enabled "$id"; then systemctl restart "$(desktop_service_name "$id").service"; fi
	say "$agent API key updated for $id."
	say 'Native Remote Control was disabled because provider API keys do not support it.'
}

clear_agent_api_key() {
	require_root credentials
	local id="$1" agent
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	agent="$(agent_provider "$id")"
	[[ "$agent" != amp ]] || die 'credentials clear currently supports Codex and Claude workspaces.'
	rm -f "$(token_path "$id")"
	write_auth_method "$id" interactive
	systemctl restart "$(service_name "$id").service"
	if desktop_enabled "$id"; then systemctl restart "$(desktop_service_name "$id").service"; fi
	say "$agent API key removed from $id. Stored login state was retained."
}

credentials_command() {
	local action="${1:-}" id="${2:-}"
	[[ -n "$action" && -n "$id" ]] || die 'credentials requires set or clear and RUNNER_ID.'
	shift 2
	case "$action" in
	set)
		local token_file=''
		if (($#)); then [[ "$1" == --token-file && $# == 2 ]] || die 'credentials set accepts --token-file PATH.'; token_file="$2"; fi
		set_agent_api_key "$id" "$token_file"
		;;
	clear) (($# == 0)) || die 'credentials clear accepts no options.'; clear_agent_api_key "$id" ;;
	*) die 'credentials expects set or clear.' ;;
	esac
}

set_remote_terminal() {
	require_root configure
	local id="$1" enabled="$2" file tmp
	file="$(state_file "$id")"
	[[ -r "$file" ]] || die "Unknown runner: $id"
	case "$enabled" in true | false) ;; *) die 'Remote terminal value must be true or false.' ;; esac
	tmp="$(mktemp "${file}.XXXXXX")"
	jq --argjson enabled "$enabled" '.remoteTerminal = $enabled' "$file" > "$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$file"
	systemctl restart "$(service_name "$id").service"
	say "Runner $id remote terminal access: $enabled"
}

update_agent_cli_volume() {
	local agent="$1" id="$2" workspace="$3" old_version new_version
	local volume="amp-runner-${id}-home"
	container_agent_common_args "$id" "$workspace" "$volume" "$agent" ''
	CONTAINER_ARGS+=(--env HOME=/agent-home)
	old_version="$(docker run "${CONTAINER_ARGS[@]}" "$IMAGE" "$agent" --version 2>/dev/null || true)"
	case "$agent" in
	codex)
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c \
			'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_HOME=/agent-home/.codex CODEX_INSTALL_DIR=/agent-home/.local/bin CODEX_NON_INTERACTIVE=true sh'
		;;
	claude)
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c \
			'curl -fsSL https://claude.ai/install.sh | HOME=/agent-home bash'
		;;
	opencode)
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" sh -c \
			'curl -fsSL https://opencode.ai/install | HOME=/agent-home OPENCODE_INSTALL_DIR=/agent-home/.local/bin bash'
		;;
	esac
	new_version="$(docker run "${CONTAINER_ARGS[@]}" "$IMAGE" "$agent" --version)"
	AGENT_CLI_CHANGED=false
	[[ "$old_version" == "$new_version" ]] || AGENT_CLI_CHANGED=true
}

update_instances() {
	require_root update
	local target="${1:---all}" file id mode user agent image_built=false image_changed=false old_image='' new_image should_restart
	local rebuild_image="${AMP_RUNNER_REBUILD_IMAGE:-true}"
	local force_restart="${AMP_RUNNER_FORCE_RESTART:-true}"
	install_tool_files
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		[[ "$target" == --all || "$target" == "$id" ]] || continue
		mode="$(jq -r '.mode' "$file")"
		user="$(jq -r '.user' "$file")"
		agent="$(jq -r '.agent // "amp"' "$file")"
		should_restart=true
		write_unit "$id" "$mode" "$user" "$(jq -r '.auth' "$file")" "$agent"
		if [[ "$(jq -r '.desktop.enabled // false' "$file")" == true ]]; then write_desktop_unit "$id"; fi
		case "$mode" in
		host | worktree)
			host_amp "$user" update
			;;
		docker)
			if [[ "$rebuild_image" == true && "$image_built" == false ]]; then
				old_image="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
				build_image
				new_image="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
				[[ "$old_image" == "$new_image" ]] || image_changed=true
				image_built=true
			fi
			if [[ "$agent" == amp ]]; then
				local key=''
				[[ "$(jq -r '.auth' "$file")" == token ]] && key="$(token_path "$id")"
				container_amp "$id" "$(jq -r '.workspace' "$file")" "amp-runner-${id}-home" "$key" update
			else
				update_agent_cli_volume "$agent" "$id" "$(jq -r '.workspace' "$file")"
				should_restart=false
				if [[ "$image_changed" == true || "$AGENT_CLI_CHANGED" == true || "$force_restart" == true ]]; then should_restart=true; fi
			fi
			;;
		devcontainer)
			local cid token=''
			cid="$(devcontainer_up "$id" "$(jq -r '.workspace' "$file")")"
			[[ "$(jq -r '.auth' "$file")" == token ]] && token="$(cat "$(token_path "$id")")"
			devcontainer_amp "$id" "$cid" "$token" update
			;;
		esac
		if [[ "$should_restart" == true ]]; then systemctl restart "$(service_name "$id").service"; fi
	done
}

self_update_files() {
	SELF_UPDATED=false
	local tmp metadata status tag release_version tarball archive release_root installed_version
	tmp="$(mktemp -d)"
	metadata="$tmp/release.json"
	status="$(curl -sS -L -o "$metadata" -w '%{http_code}' \
		-H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' \
		-H 'User-Agent: amp-runner-setup' \
		"https://api.github.com/repos/$UPDATE_REPOSITORY/releases/latest")"
	if [[ "$status" == 404 ]]; then
		say "No GitHub release is published for $UPDATE_REPOSITORY."
		rm -rf -- "$tmp"
		return 0
	fi
	[[ "$status" == 200 ]] || die "GitHub release check failed with HTTP $status."
	tag="$(jq -r '.tag_name // empty' "$metadata")"
	tarball="$(jq -r '.tarball_url // empty' "$metadata")"
	[[ -n "$tag" && -n "$tarball" ]] || die 'Latest GitHub release metadata is incomplete.'
	release_version="${tag#v}"
	[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "Unsupported release tag: $tag"
	if [[ "$(printf '%s\n' "$VERSION" "$release_version" | sort -V | tail -n1)" == "$VERSION" ]]; then
		say "Amp runner setup $VERSION is current."
		rm -rf -- "$tmp"
		return 0
	fi

	archive="$tmp/release.tar.gz"
	curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: amp-runner-setup' "$tarball" -o "$archive"
	mkdir "$tmp/release"
	tar -xzf "$archive" -C "$tmp/release"
	release_root="$(find "$tmp/release" -mindepth 1 -maxdepth 1 -type d -print -quit)"
	[[ -n "$release_root" ]] || die 'GitHub release archive has no root directory.'
	installed_version="$(sed -n 's/^VERSION=\([^[:space:]#]*\).*/\1/p' "$release_root/setup.sh" | head -n1)"
	[[ "$installed_version" == "$release_version" ]] || die "Release tag $tag does not match setup version $installed_version."
	bash -n "$release_root/setup.sh" "$release_root"/scripts/*.sh
	install_tool_files "$release_root"
	SELF_UPDATED=true
	say "Updated Amp runner setup from $VERSION to $release_version."
	rm -rf -- "$tmp"
}

self_update() {
	require_root self-update
	self_update_files
	if [[ "$SELF_UPDATED" == true ]]; then
		exec "$INSTALL_DIR/setup.sh" _activate-update
	fi
}

automatic_update() {
	require_root automatic-update
	self_update_files
	if [[ "$SELF_UPDATED" == true ]]; then
		exec "$INSTALL_DIR/setup.sh" _activate-update
	fi
	AMP_RUNNER_REBUILD_IMAGE=true AMP_RUNNER_FORCE_RESTART=false update_instances --all
	AMP_RUNNER_FORCE_RESTART=false update_desktops --all
}

activate_update() {
	require_root activate-update
	install_auto_update_timer
	"$INSTALL_DIR/scripts/install-runtimes.sh" browser
	env AMP_RUNNER_REBUILD_IMAGE=true AMP_RUNNER_FORCE_RESTART=true "$INSTALL_DIR/setup.sh" update --all
	env AMP_RUNNER_FORCE_RESTART=true "$INSTALL_DIR/setup.sh" desktop-update --all
}

auto_update_control() {
	require_root auto-update
	local action="${1:-status}"
	case "$action" in
	enable)
		install_auto_update_timer
		say 'Automatic updates enabled.'
		;;
	disable)
		systemctl disable --now "$AUTO_UPDATE_TIMER"
		say 'Automatic updates disabled.'
		;;
	status)
		systemctl --no-pager status "$AUTO_UPDATE_TIMER" || true
		;;
	*) die 'auto-update expects enable, disable, or status.' ;;
	esac
}

doctor() {
	require_root doctor
	local failed=0
	check_os
	say "Host: $(hostname)"
	say "Memory: $(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
	say "Disk: $(df -h "$DATA_DIR" | awk 'NR==2 {print $2 " total, " $4 " available"}')"
	for command in agent-browser docker git gh node npm python3 go rustc java devcontainer jq; do
		if command -v "$command" >/dev/null 2>&1; then
			printf 'ok      %s\n' "$command"
		else
			printf 'missing %s\n' "$command"
			failed=1
		fi
	done
	local host_amp_path
	host_amp_path="$(user_home "$(admin_user)")/.amp/bin/amp"
	if [[ -x "$host_amp_path" ]]; then
		printf 'ok      amp (%s)\n' "$($host_amp_path --version | awk '{print $1}')"
	else
		printf 'missing amp\n'
		failed=1
	fi
	local file id service status
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		service="$(service_name "$id")"
		status="$(systemctl is-active "$service.service" 2>/dev/null || true)"
		printf '%-7s runner %s (%s)\n' "$status" "$id" "$(jq -r '.mode' "$file")"
		[[ "$status" == active ]] || failed=1
		if [[ "$(jq -r '.desktop.enabled // false' "$file")" == true ]]; then
			service="$(desktop_service_name "$id")"
			status="$(systemctl is-active "$service.service" 2>/dev/null || true)"
			printf '%-7s web workspace %s (%s)\n' "$status" "$id" "$(jq -r '.desktop.access' "$file")"
			[[ "$status" == active ]] || failed=1
		fi
	done
	if ((failed)); then
		say 'One or more checks failed.'
		return 1
	fi
	say 'All checks passed.'
}

remove_instance() {
	require_root remove
	local id="$1" purge="${2:-}" file mode workspace base
	file="$(state_file "$id")"
	[[ -r "$file" ]] || die "Unknown runner: $id"
	if [[ "$purge" != --purge ]]; then
		if have_tty; then
			ui_confirm "Remove agent workspace $id? Its repository and container home will be retained." no || return
		else
			die 'Pass --purge to remove non-interactively, or use a terminal for a retaining removal.'
		fi
	fi
	mode="$(jq -r '.mode' "$file")"
	workspace="$(jq -r '.workspace' "$file")"
	base="$(jq -r '.baseRepository' "$file")"
	if ! cleanup_desktop_resources "$id" "$purge"; then
		die 'Runner removal stopped because its Tailscale web workspace route could not be cleared. Reconnect Tailscale and retry.'
	fi
	systemctl disable --now "$(service_name "$id").service" >/dev/null 2>&1 || true
	stop_instance_runtime "$id"
	rm -f "/etc/systemd/system/$(service_name "$id").service" "$(token_path "$id")" "$(openchamber_password_path "$id")"
	if [[ "$purge" == --purge ]]; then
		if [[ "$mode" == worktree && -n "$base" && -d "$base/.git" ]]; then
			as_user "$(jq -r '.user' "$file")" git -C "$base" worktree remove --force "$workspace"
		else
			rm -rf --one-file-system "$workspace"
		fi
		if [[ "$mode" == docker || "$mode" == devcontainer ]]; then
			docker volume rm "amp-runner-${id}-home" >/dev/null 2>&1 || true
		fi
	fi
	if [[ "$mode" == docker ]]; then
		docker network rm "amp-runner-$id" >/dev/null 2>&1 || true
	fi
	rm -f "$file"
	systemctl daemon-reload
	say "Removed agent workspace $id."
	if [[ "$purge" != --purge ]]; then
		# The state file is gone, so list and status can no longer surface these.
		# Name them now or they become unreclaimable disk nobody remembers.
		say 'Retained, and no longer listed by this tool:'
		say "  workspace  $workspace"
		if [[ "$mode" == docker || "$mode" == devcontainer ]]; then
			say "  volume     amp-runner-${id}-home"
			say "Reclaim both: sudo rm -rf --one-file-system $workspace && docker volume rm amp-runner-${id}-home"
		else
			say "Reclaim: sudo rm -rf --one-file-system $workspace"
		fi
		say "Reusing the ID $id requires reclaiming them first."
	fi
}

uninstall_tool() {
	require_root uninstall
	local purge="${1:-}"
	if have_tty; then
		ui_confirm 'Remove every Amp runner service? Workspaces are retained unless you pass --purge.' no || return
	elif [[ "$purge" != --purge ]]; then
		die 'Pass --purge for non-interactive uninstall.'
	fi
	local file id
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		remove_instance "$id" "$purge"
	done
	systemctl disable --now "$AUTO_UPDATE_TIMER" >/dev/null 2>&1 || true
	rm -f /etc/systemd/system/amp-runner-update.service "/etc/systemd/system/$AUTO_UPDATE_TIMER"
	rm -f /usr/local/sbin/amp-runner-setup
	rm -rf "$INSTALL_DIR"
	systemctl daemon-reload
	[[ "$purge" == --purge ]] && rm -rf "$CONFIG_DIR" "$DATA_DIR"
	say 'Amp runner setup tool removed. Installed OS packages were left in place.'
}

show_help() {
	cat <<EOF
Agent workspace manager $VERSION

Usage:
  sudo ./setup.sh bootstrap [--harden-ssh] [--tailscale] [--non-interactive]
  sudo ./setup.sh add [options]
  sudo ./setup.sh provision [options]
  sudo ./setup.sh list
  sudo ./setup.sh status RUNNER_ID
  sudo ./setup.sh logs RUNNER_ID [--follow]
  sudo ./setup.sh start|stop|restart RUNNER_ID
  sudo ./setup.sh connect RUNNER_ID [-- AGENT_ARGS...]
  sudo ./setup.sh shell RUNNER_ID
  sudo ./setup.sh authenticate RUNNER_ID
  sudo ./setup.sh remote enable|disable|status|pair RUNNER_ID
  sudo ./setup.sh credentials set RUNNER_ID [--token-file PATH]
  sudo ./setup.sh credentials clear RUNNER_ID
  sudo ./setup.sh configure RUNNER_ID --remote-terminal|--no-remote-terminal
  sudo ./setup.sh desktop enable RUNNER_ID [--access tailscale|ssh]
  sudo ./setup.sh desktop disable|status|credentials RUNNER_ID
  sudo ./setup.sh desktop access RUNNER_ID tailscale|ssh
  sudo ./setup.sh openchamber RUNNER_ID
  sudo ./setup.sh panel enable|disable|status|credentials|restart
  sudo ./setup.sh desktop rotate-password RUNNER_ID [--password-file PATH]
  sudo ./setup.sh desktop start|stop|restart|logs RUNNER_ID
  sudo ./setup.sh desktop-update [RUNNER_ID|--all]
  sudo ./setup.sh update [RUNNER_ID|--all]
  sudo ./setup.sh self-update
  sudo ./setup.sh auto-update enable|disable|status
  sudo ./setup.sh capabilities
  sudo ./setup.sh doctor
  sudo ./setup.sh remove RUNNER_ID [--purge]
  sudo ./setup.sh uninstall [--purge]

Add options:
  --agent amp|codex|claude|opencode
  --mode host|docker|worktree|devcontainer
  --id DNS_LABEL
  --auth interactive|token
  --token-file PATH
  --repository OWNER/REPOSITORY
  --workspace ABSOLUTE_PATH
  --clone | --no-clone
  --remote-terminal | --no-remote-terminal
  --native-remote | --no-native-remote
  --shared-auth | --isolated-auth
  --openchamber | --no-openchamber
  --desktop | --no-desktop
  --desktop-access tailscale|ssh
  --docker-access none|socket

Provision accepts the same common options and repeatable:
  --repository OWNER/REPOSITORY[=COUNT]

Codex and Claude use independent, persistent Docker workspaces and can run their
provider Remote Control services with account login. Claude supports documented
headless Remote Control. Codex exposes an experimental, opt-in CLI daemon that
is not a supported replacement for OpenAI's desktop Remote workflow. Amp also
supports host, worktree, and devcontainer modes. API keys are stored in root-only
files and mounted as read-only runtime secrets, never saved in state or argv.

Account-authenticated Codex and Claude workspaces share one login per provider by
default, so a fleet is authenticated once instead of once per runner. The shared
credentials live in a root-only directory that is mounted into each workspace at
the provider's own configuration path. Pass --isolated-auth to give a workspace
its own credentials, which is the right choice for an untrusted repository.

Run without a command for the terminal menu.
EOF
}

capability_report() {
	cat <<'EOF'
Self-hosted runner capabilities

Available
  Claude Remote Control         documented headless provider relay
  Codex Remote Control          opt-in experimental CLI daemon
  Remote thread creation          amp --no-tui
  Web and mobile remote control   Amp thread page
  Shared web terminal             opt-in per runner
  Secure web workspace            terminal, Chromium, Firefox, and Thunar
  Tailnet HTTPS or SSH tunnel     loopback-only service with generated login
  Amp modes and Fast feature      selected by the client per thread
  Plugins, skills, MCP, schedules available while the runner is online
  Headless or Xvfb browser        agent-browser
  Docker isolation                one persistent container per runner
  Dev containers and worktrees    selectable per runner

Amp-managed orb infrastructure only
  Fresh VM and clone per thread, snapshot reuse, pause and resume
  Orb portals and apps, .amp/services.yaml supervision
  Orb OIDC identity, orb secrets, and durable webhook wakeups
  Multiplayer orb file and terminal access, amp sync, orb sizing

The web workspace is a local counterpart to an orb desktop, not an Amp portal.
It shares the runner workspace but has a separate container home and no Docker
socket. Experimental custom agent modes are registered by plugins; no global
switch enables unnamed modes safely.
EOF
}

runner_summary() {
	local total=0 active=0 desktops=0 desktop_active=0 file service id
	if [[ -d "$STATE_DIR" ]]; then
		for file in "$STATE_DIR"/*.json; do
			[[ -e "$file" ]] || continue
			total=$((total + 1))
			service="$(jq -r '.service' "$file")"
			if systemctl is-active --quiet "$service.service" 2>/dev/null; then active=$((active + 1)); fi
			if [[ "$(jq -r '.desktop.enabled // false' "$file")" == true ]]; then
				desktops=$((desktops + 1))
				id="$(jq -r '.id' "$file")"
				if systemctl is-active --quiet "$(desktop_service_name "$id").service" 2>/dev/null; then desktop_active=$((desktop_active + 1)); fi
			fi
		done
	fi
	local updates=disabled
	if systemctl is-enabled --quiet "$AUTO_UPDATE_TIMER" 2>/dev/null; then updates=enabled; fi
	printf '%s/%s agents    %s/%s web workspaces    auto-updates %s' "$active" "$total" "$desktop_active" "$desktops" "$updates"
}

dashboard_header() {
	if command -v clear >/dev/null 2>&1 && [[ -n "${TERM:-}" ]]; then clear; fi
	ui_title "Agent Workspace Control  v$VERSION"
	printf '%s\n\n' "$(runner_summary)"
}

choose_runner_id() {
	local -a options
	local file id status
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		status="$(systemctl is-active "$(service_name "$id").service" 2>/dev/null || true)"
		options+=("$id"$'\t'"$status"$'\t'"$(jq -r '.project + "  [" + (.agent // "amp") + "/" + .mode + "]"' "$file")")
	done
	((${#options[@]} > 0)) || die 'No agent workspaces are configured.'
	local selected
	selected="$(ui_choose 'Find an agent workspace' "${options[@]}")"
	printf '%s\n' "${selected%%$'\t'*}"
}

web_workspace_menu() {
	local id="$1" action access
	while true; do
		dashboard_header
		ui_title "Web workspace: $id"
		if ! desktop_enabled "$id"; then
			action="$(ui_choose 'Web workspace action' 'Enable' 'Back')"
			case "$action" in
			Enable)
				if tailscale_online; then access="$(ui_choose 'Secure access' 'tailscale' 'ssh')"; else access=ssh; fi
				enable_desktop "$id" --access "$access"
				ui_pause
				;;
			Back) return ;;
			esac
			continue
		fi
		action="$(ui_choose 'Web workspace action' 'Access details' 'Status' 'Logs' 'Follow logs' 'Restart' 'Change access' 'Rotate password' 'Disable' 'Back')"
		case "$action" in
		'Access details') desktop_access_details "$id"; ui_pause ;;
		Status) desktop_command status "$id"; ui_pause ;;
		Logs) desktop_command logs "$id"; ui_pause ;;
		'Follow logs') desktop_command logs "$id" --follow || true ;;
		Restart) desktop_command restart "$id"; ui_pause ;;
		'Change access')
			if tailscale_online; then access="$(ui_choose 'Secure access' 'tailscale' 'ssh')"; else access=ssh; fi
			set_desktop_access "$id" "$access"
			ui_pause
			;;
		'Rotate password') rotate_desktop_password "$id"; ui_pause ;;
		Disable) disable_desktop "$id"; ui_pause ;;
		Back) return ;;
		esac
	done
}

manage_runner_menu() {
	local id action enabled agent
	id="$(choose_runner_id)"
	agent="$(agent_provider "$id")"
	while true; do
		dashboard_header
		ui_title "$agent workspace: $id"
		printf '%s\n' "$(jq -r '.project + "    " + (.agent // "amp") + "/" + .mode + "    " + .workspace' "$(state_file "$id")")"
		local -a actions=('Status' 'Logs' 'Follow logs' 'Start' 'Stop' 'Restart')
		if [[ "$agent" == amp ]]; then
			actions+=('Web workspace' 'Toggle Amp shared terminal')
		else
			actions+=('Open agent CLI' 'Open shell' 'Native Remote Control' 'Authenticate' 'Set API key' 'Clear API key' 'Web workspace')
		fi
		actions+=('Remove' 'Back')
		action="$(ui_choose 'Workspace action' "${actions[@]}")"
		case "$action" in
		Status) show_status "$id"; ui_pause ;;
		Logs) show_logs "$id"; ui_pause ;;
		'Follow logs') show_logs "$id" --follow || true ;;
		Start) control_instance start "$id"; ui_pause ;;
		Stop) control_instance stop "$id"; ui_pause ;;
		Restart) control_instance restart "$id"; ui_pause ;;
		'Open agent CLI') connect_instance "$id"; ui_pause ;;
		'Open shell') shell_instance "$id"; ui_pause ;;
		'Native Remote Control') native_remote_menu "$id" ;;
		Authenticate) authenticate_agent_instance "$id"; ui_pause ;;
		'Set API key') set_agent_api_key "$id"; ui_pause ;;
		'Clear API key')
			if ui_confirm "Remove the API key for $id?" no; then clear_agent_api_key "$id"; fi
			ui_pause
			;;
		'Web workspace') web_workspace_menu "$id" ;;
		'Toggle Amp shared terminal')
			enabled="$(state_value "$id" '.remoteTerminal')"
			if [[ "$enabled" == true ]]; then set_remote_terminal "$id" false; else set_remote_terminal "$id" true; fi
			ui_pause
			;;
		Remove) remove_instance "$id"; return ;;
		Back) return ;;
		esac
	done
}

native_remote_menu() {
	local id="$1" action enabled agent
	agent="$(agent_provider "$id")"
	while true; do
		dashboard_header
		ui_title "$agent Remote Control: $id"
		enabled="$(native_remote_enabled "$id")"
		if [[ "$enabled" == true ]]; then
			if [[ "$agent" == codex ]]; then
				action="$(ui_choose 'Remote action' 'Status' 'Pair device' 'Restart' 'Disable' 'Back')"
			else
				action="$(ui_choose 'Remote action' 'Status' 'Restart' 'Disable' 'Back')"
			fi
		else
			action="$(ui_choose 'Remote action' 'Status' 'Enable' 'Back')"
		fi
		case "$action" in
		Status) native_remote_status "$id"; ui_pause ;;
		'Pair device') native_remote_command pair "$id"; ui_pause ;;
		Restart) control_instance restart "$id"; ui_pause ;;
		Enable) native_remote_command enable "$id"; ui_pause ;;
		Disable) native_remote_command disable "$id"; ui_pause ;;
		Back) return ;;
		esac
	done
}

updates_menu() {
	local action
	while true; do
		dashboard_header
		ui_title 'Updates'
		action="$(ui_choose 'Update action' 'Update Amp CLIs' 'Rebuild agent image and update CLIs' 'Update web workspace image' 'Update manager from GitHub release' 'Automatic update status' 'Enable automatic updates' 'Disable automatic updates' 'Back')"
		case "$action" in
		'Update Amp CLIs') AMP_RUNNER_REBUILD_IMAGE=false update_instances --all; ui_pause ;;
		'Rebuild agent image and update CLIs') update_instances --all; ui_pause ;;
		'Update web workspace image') update_desktops --all; ui_pause ;;
		'Update manager from GitHub release') self_update; ui_pause ;;
		'Automatic update status') auto_update_control status; ui_pause ;;
		'Enable automatic updates') auto_update_control enable; ui_pause ;;
		'Disable automatic updates') auto_update_control disable; ui_pause ;;
		Back) return ;;
		esac
	done
}

host_menu() {
	local action
	while true; do
		dashboard_header
		ui_title 'Host and features'
		action="$(ui_choose 'Host action' 'Health checks' 'Feature compatibility' 'Bootstrap or repair host' 'Uninstall' 'Back')"
		case "$action" in
		'Health checks') doctor || true; ui_pause ;;
		'Feature compatibility') capability_report; ui_pause ;;
		'Bootstrap or repair host') bootstrap; ui_pause ;;
		Uninstall) uninstall_tool; return ;;
		Back) return ;;
		esac
	done
}

menu() {
	require_root
	local action
	while true; do
		dashboard_header
		action="$(ui_choose 'Choose an area' 'Provision agent fleet' 'Add one workspace' 'Manage workspaces' 'List workspaces' 'Updates' 'Host and features' 'Quit')"
		case "$action" in
		'Provision agent fleet') provision_instances; ui_pause ;;
		'Add one workspace') add_instance; ui_pause ;;
		'Manage workspaces') manage_runner_menu ;;
		'List workspaces') list_instances; ui_pause ;;
		Updates) updates_menu ;;
		'Host and features') host_menu ;;
		Quit) return ;;
		esac
	done
}

main() {
	local command="${1:-}"
	if [[ -n "$command" ]]; then shift; fi
	case "$command" in
	'') menu ;;
	bootstrap) bootstrap "$@" ;;
	add) add_instance "$@" ;;
	provision | add-many) provision_instances "$@" ;;
	list) list_instances "$@" ;;
	status) (($# >= 1)) || die 'status requires RUNNER_ID'; show_status "$@" ;;
	logs) (($# >= 1)) || die 'logs requires RUNNER_ID'; show_logs "$@" ;;
	start | stop | restart) (($# == 1)) || die "$command requires RUNNER_ID"; control_instance "$command" "$1" ;;
	connect) (($# >= 1)) || die 'connect requires RUNNER_ID'; connect_instance "$@" ;;
	shell) (($# == 1)) || die 'shell requires RUNNER_ID'; shell_instance "$1" ;;
	authenticate) (($# == 1)) || die 'authenticate requires RUNNER_ID'; authenticate_agent_instance "$1" ;;
	remote) native_remote_command "$@" ;;
	credentials) credentials_command "$@" ;;
	configure)
		(($# == 2)) || die 'configure requires RUNNER_ID and --remote-terminal or --no-remote-terminal'
		case "$2" in --remote-terminal) set_remote_terminal "$1" true ;; --no-remote-terminal) set_remote_terminal "$1" false ;; *) die "Unknown configure option: $2" ;; esac
		;;
	desktop) desktop_command "$@" ;;
	openchamber) openchamber_details "$@" ;;
	panel) panel_command "$@" ;;
	desktop-update) update_desktops "$@" ;;
	update) update_instances "$@" ;;
	self-update) self_update "$@" ;;
	auto-update) auto_update_control "$@" ;;
	capabilities) capability_report ;;
	doctor) doctor "$@" ;;
	remove) (($# >= 1)) || die 'remove requires RUNNER_ID'; remove_instance "$@" ;;
	uninstall) uninstall_tool "$@" ;;
	_run) run_instance "$@" ;;
	_stop) stop_instance_runtime "$@" ;;
	_run-desktop) run_desktop "$@" ;;
	_stop-desktop) stop_desktop "$@" ;;
	_automatic-update) automatic_update "$@" ;;
	_activate-update) activate_update "$@" ;;
	-h | --help | help) show_help ;;
	*) die "Unknown command: $command" ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
