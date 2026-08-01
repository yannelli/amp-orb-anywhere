#!/usr/bin/env bash
set -euo pipefail

VERSION=1.0.0 # x-release-please-version
INSTALL_DIR="${AMP_RUNNER_INSTALL_DIR:-/opt/amp-runner}"
CONFIG_DIR="${AMP_RUNNER_CONFIG_DIR:-/etc/amp-runner}"
STATE_DIR="$CONFIG_DIR/instances"
SECRET_DIR="$CONFIG_DIR/secrets"
DATA_DIR="${AMP_RUNNER_DATA_DIR:-/srv/amp-runners}"
IMAGE="${AMP_RUNNER_IMAGE:-amp-runner:ubuntu24.04}"
DESKTOP_IMAGE="${AMP_RUNNER_DESKTOP_IMAGE:-amp-runner-desktop:debian-xfce}"
UPDATE_REPOSITORY="${AMP_RUNNER_UPDATE_REPOSITORY:-yannelli/amp-orb-anywhere}"
AUTO_UPDATE_TIMER='amp-runner-update.timer'
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SOURCE_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"

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
	install -d -m 0700 "$SECRET_DIR"
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
		install -m 0755 "$source"/scripts/*.sh "$INSTALL_DIR/scripts/"
	else
		chmod 0755 "$INSTALL_DIR/setup.sh" "$INSTALL_DIR"/scripts/*.sh
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
	codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')"
	curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" -o /usr/share/keyrings/tailscale-archive-keyring.gpg
	curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" -o /etc/apt/sources.list.d/tailscale.list
	apt-get update -qq
	DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
	if have_tty; then
		tailscale up
	else
		say 'Tailscale installed. Run sudo tailscale up from an SSH session to authenticate.'
	fi
}

build_image() {
	docker build --pull --tag "$IMAGE" "$INSTALL_DIR"
}

build_desktop_image() {
	docker build --pull --file "$INSTALL_DIR/Dockerfile.desktop" --tag "$DESKTOP_IMAGE" "$INSTALL_DIR"
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
		reserved="$(jq -r '.desktop.port // empty' "$file")"
		[[ "$reserved" != "$port" ]] || return 1
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
Description=Secure web workspace for Amp runner $id
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
	local id="$1" workspace mode user uid gid port access name subfolder='/'
	[[ -r "$(state_file "$id")" ]] || die "Unknown runner: $id"
	desktop_enabled "$id" || die "Web workspace is disabled for runner $id."
	workspace="$(state_value "$id" '.workspace')"
	mode="$(state_value "$id" '.mode')"
	user="$(state_value "$id" '.user')"
	if [[ "$mode" == docker ]]; then
		uid=1000
		gid=1000
	else
		uid="$(id -u "$user")"
		gid="$(id -g "$user")"
	fi
	port="$(desktop_state_value "$id" '.desktop.port' '')"
	access="$(desktop_state_value "$id" '.desktop.access' ssh)"
	[[ -n "$port" ]] || die "Runner $id has no web workspace port."
	[[ "$access" != tailscale ]] || subfolder="$(desktop_subfolder "$id")"
	name="$(desktop_service_name "$id")"
	docker rm --force "$name" >/dev/null 2>&1 || true
	exec docker run --rm \
		--name "$name" \
		--label "amp.runner.id=$id" \
		--label 'amp.runner.component=desktop' \
		--publish "127.0.0.1:$port:3001" \
		--volume "amp-runner-${id}-desktop:/config" \
		--volume "$workspace:/workspace:rw" \
		--mount "type=bind,source=$(desktop_username_path "$id"),target=/run/secrets/webtop_username,readonly" \
		--mount "type=bind,source=$(desktop_password_path "$id"),target=/run/secrets/webtop_password,readonly" \
		--env "PUID=$uid" \
		--env "PGID=$gid" \
		--env 'TZ=Etc/UTC' \
		--env "TITLE=Amp Workspace: $id" \
		--env "SUBFOLDER=$subfolder" \
		--env 'FILE_MANAGER_PATH=/workspace' \
		--env 'FILE__CUSTOM_USER=/run/secrets/webtop_username' \
		--env 'FILE__PASSWORD=/run/secrets/webtop_password' \
		--env 'DISABLE_SUDO=true' \
		--env 'START_DOCKER=false' \
		--shm-size 1g \
		--pids-limit 4096 \
		--security-opt no-new-privileges:true \
		"$DESKTOP_IMAGE"
}

stop_desktop() {
	local id="$1"
	docker stop --time 20 "$(desktop_service_name "$id")" >/dev/null 2>&1 || true
	docker rm --force "$(desktop_service_name "$id")" >/dev/null 2>&1 || true
}

wait_for_desktop() {
	local id="$1" port="$2" username="$3" password="$4" path='/' attempt curl_user
	if [[ "$(desktop_state_value "$id" '.desktop.access' ssh)" == tailscale ]]; then path="$(desktop_subfolder "$id")"; fi
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

disable_tailscale_desktop_route() {
	local id="$1" output
	command -v tailscale >/dev/null 2>&1 || return 1
	output="$(tailscale serve --https=443 --set-path="/desktop/$id" off 2>&1)" && return 0
	[[ "$output" == *'handler does not exist'* ]]
}

restore_desktop_access() {
	local id="$1" access="$2" port="$3" username="$4" password="$5"
	disable_tailscale_desktop_route "$id" || true
	write_desktop_access "$id" "$access" || return 1
	systemctl restart "$(desktop_service_name "$id").service" || return 1
	wait_for_desktop "$id" "$port" "$username" "$password" || return 1
	if [[ "$access" == tailscale ]]; then enable_tailscale_desktop_route "$id" || return 1; fi
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
	local target="${1:---all}" file id found=false desktop_lock_fd
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		[[ "$target" == --all || "$target" == "$id" ]] || continue
		if [[ "$(jq -r '.desktop.enabled // false' "$file")" == true ]]; then found=true; fi
	done
	[[ "$found" == true ]] || { say 'No enabled web workspaces matched.'; return; }
	exec {desktop_lock_fd}> "$CONFIG_DIR/desktop.lock"
	flock "$desktop_lock_fd"
	build_desktop_image
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
	local id="$1" token="$2" owner="${3:-root}"
	[[ -n "$token" ]] || die 'The Amp access token is empty.'
	[[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || die 'The Amp access token contains a newline.'
	local path
	path="$(token_path "$id")"
	(
		umask 077
		printf '%s' "$token" > "$path"
		chmod 0400 "$path"
		chown "$owner" "$path"
	)
}

container_common_args() {
	local id="$1" workspace="$2" home_volume="$3" key="$4"
	CONTAINER_ARGS=(--rm --volume "$home_volume:/home/amp" --volume "$workspace:/workspace" --workdir /workspace)
	if [[ -n "$key" ]]; then
		CONTAINER_ARGS+=(--mount "type=bind,source=$key,target=/run/secrets/amp_api_key,readonly")
	fi
	CONTAINER_ARGS+=(--label "amp.runner.id=$id")
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

choose_project() {
	local projects_json="$1" requested="${2:-}" selected
	if [[ -n "$requested" ]]; then
		selected="$(jq -c --arg ref "$requested" '.[] | select((.namespace + "/" + .name) == $ref or .id == $ref or .repositoryURL == $ref)' <<< "$projects_json" | head -n1)"
		[[ -n "$selected" ]] || die "Amp project not found: $requested"
		printf '%s\n' "$selected"
		return
	fi
	mapfile -t PROJECT_OPTIONS < <(jq -r '.[] | (.namespace + "/" + .name + "\t" + .repositoryURL)' <<< "$projects_json")
	((${#PROJECT_OPTIONS[@]} > 0)) || die 'No Amp projects are available to this account.'
	selected="$(ui_choose 'Amp project' "${PROJECT_OPTIONS[@]}")"
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
	local id="$1" workspace="$2" volume="$3" remote="$4"
	[[ "$remote" == *github.com* ]] || return 0
	container_common_args "$id" "$workspace" "$volume" ''
	if docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth status --hostname github.com >/dev/null 2>&1; then
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth setup-git --hostname github.com
	elif have_tty && ui_confirm 'Authenticate GitHub CLI in this container for private clone and push access?' yes; then
		docker run --interactive --tty "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth login --hostname github.com --git-protocol https --web
		docker run "${CONTAINER_ARGS[@]}" "$IMAGE" gh auth setup-git --hostname github.com
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
	local id="$1" workspace="$2" volume="$3" key="$4" project_ref="$5" remote="$6" clone_repo="$7"
	install -d -m 0755 "$(dirname "$workspace")"
	if [[ -d "$workspace/.git" || -f "$workspace/.git" ]]; then
		docker run --rm --volume "$workspace:/workspace" --workdir /workspace "$IMAGE" git remote set-url origin "$remote"
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
			ensure_container_github_auth "$id" "$(dirname "$workspace")" "$volume" "$remote"
			container_common_args "$id" "$(dirname "$workspace")" "$volume" ''
			docker run "${CONTAINER_ARGS[@]}" "$IMAGE" git clone "$remote" "$(basename "$workspace")"
		fi
	else
		docker run --rm --volume "$workspace:/workspace" --workdir /workspace "$IMAGE" git init
		docker run --rm --volume "$workspace:/workspace" --workdir /workspace "$IMAGE" git remote add origin "$remote"
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
	local id="$1" mode="$2" user="$3" workspace="$4" project_ref="$5" remote="$6" auth="$7" remote_terminal="$8" docker_access="$9" base_repo="${10:-}"
	jq -n \
		--arg id "$id" --arg mode "$mode" --arg user "$user" --arg workspace "$workspace" \
		--arg project "$project_ref" --arg repositoryURL "$remote" --arg auth "$auth" \
		--arg service "$(service_name "$id")" --arg dockerAccess "$docker_access" \
		--arg baseRepository "$base_repo" --argjson remoteTerminal "$remote_terminal" \
		--arg createdAt "$(date --iso-8601=seconds)" \
		'{id:$id,mode:$mode,user:$user,workspace:$workspace,project:$project,repositoryURL:$repositoryURL,auth:$auth,service:$service,dockerAccess:$dockerAccess,baseRepository:$baseRepository,remoteTerminal:$remoteTerminal,desktop:{enabled:false,access:"",port:0,username:""},createdAt:$createdAt}' \
		> "$(state_file "$id")"
	chmod 0644 "$(state_file "$id")"
}

write_unit() {
	local id="$1" mode="$2" user="$3" auth="$4" service unit_user='root' credential=''
	service="$(service_name "$id")"
	[[ "$mode" == host || "$mode" == worktree || "$mode" == devcontainer ]] && unit_user="$user"
	[[ "$auth" == token ]] && credential="LoadCredential=amp_api_key:$(token_path "$id")"
	cat > "/etc/systemd/system/$service.service" <<EOF
[Unit]
Description=Amp runner $id ($mode)
After=network-online.target docker.service
Wants=network-online.target
$([[ "$mode" == docker || "$mode" == devcontainer ]] && printf 'Requires=docker.service')

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

	local mode='' id='' auth='' token='' token_file='' requested_project='' workspace='' clone_repo='' remote_terminal='' docker_access='none'
	local desktop='' desktop_access=''
	while (($#)); do
		case "$1" in
		--mode) mode="$2"; shift ;;
		--id) id="$2"; shift ;;
		--auth) auth="$2"; shift ;;
		--token-file) token_file="$2"; shift ;;
		--project) requested_project="$2"; shift ;;
		--workspace) workspace="$2"; shift ;;
		--clone) clone_repo=true ;;
		--no-clone) clone_repo=false ;;
		--remote-terminal) remote_terminal=true ;;
		--no-remote-terminal) remote_terminal=false ;;
		--desktop) desktop=true ;;
		--no-desktop) desktop=false ;;
		--desktop-access) desktop_access="$2"; shift ;;
		--docker-access) docker_access="$2"; shift ;;
		*) die "Unknown add option: $1" ;;
		esac
		shift
	done

	ui_title 'Add Amp runner instance'
	[[ -n "$mode" ]] || mode="$(ui_choose 'Instance type' 'host' 'docker' 'worktree' 'devcontainer')"
	case "$mode" in host | docker | worktree | devcontainer) ;; *) die "Invalid mode: $mode" ;; esac
	if [[ "$mode" == host ]] && find "$STATE_DIR" -name '*.json' -exec jq -e 'select(.mode == "host")' {} \; | grep -q .; then
		die 'A dedicated host runner already exists. Use docker, worktree, or devcontainer for another instance.'
	fi
	[[ -n "$id" ]] || id="$(ui_input 'Stable runner ID' "$(hostname -s)-$mode")"
	id="$(slugify "$id")"
	validate_runner_id "$id" || die 'Runner ID must be one lowercase DNS label, up to 63 characters.'
	[[ ! -e "$(state_file "$id")" ]] || die "Runner already exists: $id"

	[[ -n "$auth" ]] || auth="$(ui_choose 'Amp authentication' 'interactive' 'token')"
	case "$auth" in interactive | token) ;; *) die "Invalid authentication method: $auth" ;; esac
	if [[ "$auth" == token ]]; then
		if [[ -n "$token_file" ]]; then
			[[ -r "$token_file" ]] || die "Cannot read token file: $token_file"
			token="$(cat "$token_file")"
		else
			have_tty || die '--token-file is required without a terminal.'
			token="$(ui_password 'Amp access token')"
		fi
	fi

	local user project_json projects_json project_ref remote key='' volume="amp-runner-${id}-home" base_repo=''
	user="$(admin_user)"
	[[ -n "$workspace" ]] || workspace="$DATA_DIR/workspaces/$id"
	[[ "$workspace" == /* ]] || die 'Workspace must be an absolute path.'
	install -d -m 0755 "$workspace"

	if [[ "$auth" == token ]]; then
		local owner=root
		[[ "$mode" == docker ]] && owner=1000
		[[ "$mode" == devcontainer ]] && owner="$user"
		store_token "$id" "$token" "$owner"
		key="$(token_path "$id")"
	fi

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

	project_json="$(choose_project "$projects_json" "$requested_project")"
	project_ref="$(jq -r '.namespace + "/" + .name' <<< "$project_json")"
	remote="$(jq -r '.repositoryURL' <<< "$project_json")"
	[[ -n "$remote" && "$remote" != null ]] || die "Project $project_ref has no repository URL. Configure one in Amp first."
	if [[ -z "$clone_repo" ]]; then
		have_tty || die 'Pass --clone or --no-clone without a terminal.'
		if ui_confirm "Clone $remote now?" yes; then clone_repo=true; else clone_repo=false; fi
	fi
	if [[ -z "$remote_terminal" ]]; then
		if have_tty && ui_confirm 'Enable web terminal access for remotely controlled threads?' no; then remote_terminal=true; else remote_terminal=false; fi
	fi
	if [[ -z "$desktop" ]]; then
		if have_tty && ui_confirm 'Enable the secure web workspace with terminal, browsers, and files?' no; then desktop=true; else desktop=false; fi
	fi
	if [[ "$desktop" == true && -z "$desktop_access" ]]; then
		have_tty || die '--desktop-access tailscale or --desktop-access ssh is required with --desktop.'
		if tailscale_online; then desktop_access="$(ui_choose 'Secure web workspace access' 'tailscale' 'ssh')"; else desktop_access=ssh; fi
	fi
	if [[ "$desktop" == true ]]; then
		case "$desktop_access" in tailscale | ssh) ;; *) die '--desktop-access must be tailscale or ssh.' ;; esac
	fi
	case "$docker_access" in none | socket) ;; *) die '--docker-access must be none or socket.' ;; esac
	if [[ "$mode" == docker && "$docker_access" == none ]] && have_tty; then
		if ui_confirm 'Mount the host Docker socket? This gives the runner effective root access to the VM.' no; then docker_access=socket; fi
	fi

	case "$mode" in
	host)
		prepare_host_checkout "$user" "$workspace" "$project_ref" "$remote" "$clone_repo"
		usermod -aG docker "$user"
		;;
	worktree)
		base_repo="$(prepare_worktree "$user" "$workspace" "$project_ref" "$remote" "$clone_repo")"
		;;
	docker)
		prepare_container_checkout "$id" "$workspace" "$volume" "$key" "$project_ref" "$remote" "$clone_repo"
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

	write_state "$id" "$mode" "$user" "$workspace" "$project_ref" "$remote" "$auth" "$remote_terminal" "$docker_access" "$base_repo"
	write_unit "$id" "$mode" "$user" "$auth"
	if [[ "$desktop" == true ]]; then enable_desktop "$id" --access "$desktop_access"; fi
	say
	say "Runner $id is installed for $project_ref."
	say "Status: sudo amp-runner-setup status $id"
	say "Logs:   sudo amp-runner-setup logs $id"
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

	local mode='' auth='' token_file='' generated_token_file='' token='' clone_repo='' remote_terminal='' docker_access='none'
	local desktop='' desktop_access=''
	local -a requested_specs=()
	while (($#)); do
		case "$1" in
		--mode) mode="$2"; shift ;;
		--auth) auth="$2"; shift ;;
		--token-file) token_file="$2"; shift ;;
		--project) requested_specs+=("$2"); shift ;;
		--clone) clone_repo=true ;;
		--no-clone) clone_repo=false ;;
		--remote-terminal) remote_terminal=true ;;
		--no-remote-terminal) remote_terminal=false ;;
		--desktop) desktop=true ;;
		--no-desktop) desktop=false ;;
		--desktop-access) desktop_access="$2"; shift ;;
		--docker-access) docker_access="$2"; shift ;;
		*) die "Unknown provision option: $1" ;;
		esac
		shift
	done

	ui_title 'Provision runner fleet'
	[[ -n "$mode" ]] || mode="$(ui_choose 'Runtime isolation' 'docker' 'worktree' 'devcontainer' 'host')"
	case "$mode" in host | docker | worktree | devcontainer) ;; *) die "Invalid mode: $mode" ;; esac
	[[ -n "$auth" ]] || auth="$(ui_choose 'Amp authentication' 'token' 'interactive')"
	case "$auth" in interactive | token) ;; *) die "Invalid authentication method: $auth" ;; esac
	if [[ "$auth" == token ]]; then
		if [[ -n "$token_file" ]]; then
			[[ -r "$token_file" ]] || die "Cannot read token file: $token_file"
			token="$(cat "$token_file")"
		else
			have_tty || die '--token-file is required without a terminal.'
			token="$(ui_password 'Amp access token')"
			token_file="$(mktemp)"
			generated_token_file="$token_file"
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
	[[ -n "$remote_terminal" ]] || {
		if have_tty && ui_confirm 'Enable web terminal access for these runners?' no; then remote_terminal=true; else remote_terminal=false; fi
	}
	[[ -n "$desktop" ]] || {
		if have_tty && ui_confirm 'Enable secure web workspaces for these runners?' no; then desktop=true; else desktop=false; fi
	}
	if [[ "$desktop" == true && -z "$desktop_access" ]]; then
		have_tty || die '--desktop-access tailscale or --desktop-access ssh is required with --desktop.'
		if tailscale_online; then desktop_access="$(ui_choose 'Secure web workspace access' 'tailscale' 'ssh')"; else desktop_access=ssh; fi
	fi
	if [[ "$desktop" == true ]]; then
		case "$desktop_access" in tailscale | ssh) ;; *) die '--desktop-access must be tailscale or ssh.' ;; esac
	fi
	case "$docker_access" in none | socket) ;; *) die '--docker-access must be none or socket.' ;; esac
	if [[ "$mode" == docker && "$docker_access" == none ]] && have_tty; then
		if ui_confirm 'Mount the host Docker socket in every runner? This grants effective host root access.' no; then docker_access=socket; fi
	fi

	local user projects_json
	user="$(admin_user)"
	if [[ "$auth" == token ]]; then
		token="${token:-$(cat "$token_file")}"
	fi
	authenticate_host "$user" "$auth" "$token"
	projects_json="$(list_projects_host "$user" "$auth" "$token")"

	if ((${#requested_specs[@]} == 0)); then
		have_tty || die 'Pass at least one --project PROJECT[=COUNT] without a terminal.'
		local -a project_options selected_options
		mapfile -t project_options < <(jq -r '.[] | (.namespace + "/" + .name + "\t" + .repositoryURL)' <<< "$projects_json")
		((${#project_options[@]} > 0)) || die 'No Amp projects are available to this account.'
		project_options=('[all projects]' "${project_options[@]}")
		mapfile -t selected_options < <(ui_choose_many 'Select Amp projects' "${project_options[@]}")
		((${#selected_options[@]} > 0)) || die 'No projects selected.'
		local selected ref count
		if printf '%s\n' "${selected_options[@]}" | grep -Fxq '[all projects]'; then
			mapfile -t selected_options < <(jq -r '.[] | .namespace + "/" + .name' <<< "$projects_json")
		fi
		for selected in "${selected_options[@]}"; do
			[[ "$selected" == '[all projects]' ]] && continue
			ref="${selected%%$'\t'*}"
			count="$(ui_input "Runner count for $ref" 1)"
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

	ui_title "Provisioning plan: $total runner(s)"
	local index
	for index in "${!project_refs[@]}"; do
		printf '  %-32s %s\n' "${project_refs[$index]}" "${project_counts[$index]} x $mode"
	done
	if [[ "$desktop" == true ]]; then printf '  %-32s %s\n' 'Web workspace' "$desktop_access access for every runner"; fi
	if have_tty; then
		if ! ui_confirm 'Create this runner fleet?' yes; then
			if [[ -n "$generated_token_file" ]]; then
				rm -f -- "$generated_token_file"
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
			id="$(next_runner_id "$project_ref-$mode" "$suffix")"
			local -a add_args=(--mode "$mode" --id "$id" --auth "$auth" --project "$project_ref" --docker-access "$docker_access")
			[[ "$auth" == token ]] && add_args+=(--token-file "$token_file")
			if [[ "$clone_repo" == true ]]; then add_args+=(--clone); else add_args+=(--no-clone); fi
			if [[ "$remote_terminal" == true ]]; then add_args+=(--remote-terminal); else add_args+=(--no-remote-terminal); fi
			if [[ "$desktop" == true ]]; then add_args+=(--desktop --desktop-access "$desktop_access"); else add_args+=(--no-desktop); fi
			add_instance "${add_args[@]}"
		done
	done

	if [[ -n "$generated_token_file" ]]; then
		rm -f -- "$generated_token_file"
		trap - EXIT
	fi
	say
	say "Provisioned $total runner(s)."
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

run_container_instance() {
	local id="$1" workspace volume name network key='' access socket_gid
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
	printf '%-28s %-13s %-10s %-10s %-28s %s\n' RUNNER MODE STATUS DESKTOP PROJECT WORKSPACE
	local file id service status desktop
	shopt -s nullglob
	for file in "$STATE_DIR"/*.json; do
		id="$(jq -r '.id' "$file")"
		service="$(jq -r '.service' "$file")"
		status="$(systemctl is-active "$service.service" 2>/dev/null || true)"
		desktop="$(jq -r 'if .desktop.enabled == true then .desktop.access else "off" end' "$file")"
		printf '%-28s %-13s %-10s %-10s %-28s %s\n' "$id" "$(jq -r '.mode' "$file")" "$status" "$desktop" "$(jq -r '.project' "$file")" "$(jq -r '.workspace' "$file")"
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
	say "Runner $id: $action requested."
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

update_instances() {
	require_root update
	local target="${1:---all}" file id mode user image_built=false
	local rebuild_image="${AMP_RUNNER_REBUILD_IMAGE:-true}"
	install_tool_files
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		[[ "$target" == --all || "$target" == "$id" ]] || continue
		mode="$(jq -r '.mode' "$file")"
		user="$(jq -r '.user' "$file")"
		write_unit "$id" "$mode" "$user" "$(jq -r '.auth' "$file")"
		if [[ "$(jq -r '.desktop.enabled // false' "$file")" == true ]]; then write_desktop_unit "$id"; fi
		case "$mode" in
		host | worktree)
			host_amp "$user" update
			;;
		docker)
			if [[ "$rebuild_image" == true && "$image_built" == false ]]; then build_image; image_built=true; fi
			local key=''
			[[ "$(jq -r '.auth' "$file")" == token ]] && key="$(token_path "$id")"
			container_amp "$id" "$(jq -r '.workspace' "$file")" "amp-runner-${id}-home" "$key" update
			;;
		devcontainer)
			local cid token=''
			cid="$(devcontainer_up "$id" "$(jq -r '.workspace' "$file")")"
			[[ "$(jq -r '.auth' "$file")" == token ]] && token="$(cat "$(token_path "$id")")"
			devcontainer_amp "$id" "$cid" "$token" update
			;;
		esac
		systemctl restart "$(service_name "$id").service"
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
	AMP_RUNNER_REBUILD_IMAGE=false update_instances --all
}

activate_update() {
	require_root activate-update
	install_auto_update_timer
	"$INSTALL_DIR/scripts/install-runtimes.sh" browser
	env AMP_RUNNER_REBUILD_IMAGE=true "$INSTALL_DIR/setup.sh" update --all
	"$INSTALL_DIR/setup.sh" desktop-update --all
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
			ui_confirm "Remove runner $id? Its workspace and container home will be retained." no || return
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
	rm -f "/etc/systemd/system/$(service_name "$id").service" "$(token_path "$id")"
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
	say "Removed runner $id."
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
Amp runner setup $VERSION

Usage:
  sudo ./setup.sh bootstrap [--harden-ssh] [--tailscale] [--non-interactive]
  sudo ./setup.sh add [options]
  sudo ./setup.sh provision [options]
  sudo ./setup.sh list
  sudo ./setup.sh status RUNNER_ID
  sudo ./setup.sh logs RUNNER_ID [--follow]
  sudo ./setup.sh start|stop|restart RUNNER_ID
  sudo ./setup.sh configure RUNNER_ID --remote-terminal|--no-remote-terminal
  sudo ./setup.sh desktop enable RUNNER_ID [--access tailscale|ssh]
  sudo ./setup.sh desktop disable|status|credentials RUNNER_ID
  sudo ./setup.sh desktop access RUNNER_ID tailscale|ssh
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
  --mode host|docker|worktree|devcontainer
  --id DNS_LABEL
  --auth interactive|token
  --token-file PATH
  --project NAMESPACE/NAME
  --workspace ABSOLUTE_PATH
  --clone | --no-clone
  --remote-terminal | --no-remote-terminal
  --desktop | --no-desktop
  --desktop-access tailscale|ssh
  --docker-access none|socket

Provision accepts the same common options and repeatable:
  --project NAMESPACE/NAME[=COUNT]

Run without a command for the terminal menu.
EOF
}

capability_report() {
	cat <<'EOF'
Self-hosted runner capabilities

Available
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
	printf '%s/%s runners    %s/%s web workspaces    auto-updates %s' "$active" "$total" "$desktop_active" "$desktops" "$updates"
}

dashboard_header() {
	if command -v clear >/dev/null 2>&1 && [[ -n "${TERM:-}" ]]; then clear; fi
	ui_title "Amp Runner Control  v$VERSION"
	printf '%s\n\n' "$(runner_summary)"
}

choose_runner_id() {
	local -a options
	local file id status
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		status="$(systemctl is-active "$(service_name "$id").service" 2>/dev/null || true)"
		options+=("$id"$'\t'"$status"$'\t'"$(jq -r '.project + "  [" + .mode + "]"' "$file")")
	done
	((${#options[@]} > 0)) || die 'No runners are configured.'
	local selected
	selected="$(ui_choose 'Find a runner' "${options[@]}")"
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
	local id action enabled
	id="$(choose_runner_id)"
	while true; do
		dashboard_header
		ui_title "Runner: $id"
		printf '%s\n' "$(jq -r '.project + "    " + .mode + "    " + .workspace' "$(state_file "$id")")"
		action="$(ui_choose 'Runner action' 'Status' 'Logs' 'Follow logs' 'Start' 'Stop' 'Restart' 'Web workspace' 'Toggle Amp shared terminal' 'Remove' 'Back')"
		case "$action" in
		Status) show_status "$id"; ui_pause ;;
		Logs) show_logs "$id"; ui_pause ;;
		'Follow logs') show_logs "$id" --follow || true ;;
		Start) control_instance start "$id"; ui_pause ;;
		Stop) control_instance stop "$id"; ui_pause ;;
		Restart) control_instance restart "$id"; ui_pause ;;
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

updates_menu() {
	local action
	while true; do
		dashboard_header
		ui_title 'Updates'
		action="$(ui_choose 'Update action' 'Update Amp CLIs' 'Rebuild image and update Amp' 'Update web workspace image' 'Update runner setup from GitHub release' 'Automatic update status' 'Enable automatic updates' 'Disable automatic updates' 'Back')"
		case "$action" in
		'Update Amp CLIs') AMP_RUNNER_REBUILD_IMAGE=false update_instances --all; ui_pause ;;
		'Rebuild image and update Amp') update_instances --all; ui_pause ;;
		'Update web workspace image') update_desktops --all; ui_pause ;;
		'Update runner setup from GitHub release') self_update; ui_pause ;;
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
		action="$(ui_choose 'Choose an area' 'Provision runner fleet' 'Add one runner' 'Manage runners' 'List runners' 'Updates' 'Host and features' 'Quit')"
		case "$action" in
		'Provision runner fleet') provision_instances; ui_pause ;;
		'Add one runner') add_instance; ui_pause ;;
		'Manage runners') manage_runner_menu ;;
		'List runners') list_instances; ui_pause ;;
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
	configure)
		(($# == 2)) || die 'configure requires RUNNER_ID and --remote-terminal or --no-remote-terminal'
		case "$2" in --remote-terminal) set_remote_terminal "$1" true ;; --no-remote-terminal) set_remote_terminal "$1" false ;; *) die "Unknown configure option: $2" ;; esac
		;;
	desktop) desktop_command "$@" ;;
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
