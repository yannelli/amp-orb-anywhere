#!/usr/bin/env bash
set -euo pipefail

VERSION=1.0.0
INSTALL_DIR="${AMP_RUNNER_INSTALL_DIR:-/opt/amp-runner}"
CONFIG_DIR="${AMP_RUNNER_CONFIG_DIR:-/etc/amp-runner}"
STATE_DIR="$CONFIG_DIR/instances"
SECRET_DIR="$CONFIG_DIR/secrets"
DATA_DIR="${AMP_RUNNER_DATA_DIR:-/srv/amp-runners}"
IMAGE="${AMP_RUNNER_IMAGE:-amp-runner:ubuntu24.04}"
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
		gum style --border rounded --border-foreground 212 --foreground 212 --padding '0 2' "$1"
	else
		printf '\n%s\n\n' "$1"
	fi
}

ui_choose() {
	local prompt="$1"
	shift
	if command -v gum >/dev/null 2>&1 && have_tty; then
		printf '%s\n' "$@" | gum choose --header "$prompt"
	else
		local choice
		PS3="$prompt "
		select choice in "$@"; do
			[[ -n "$choice" ]] && printf '%s\n' "$choice" && return
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
	ensure_layout
	if [[ "$SOURCE_DIR" != "$INSTALL_DIR" ]]; then
		install -m 0755 "$SOURCE_DIR/setup.sh" "$INSTALL_DIR/setup.sh"
		install -m 0644 "$SOURCE_DIR/Dockerfile" "$INSTALL_DIR/Dockerfile"
		install -d -m 0755 "$INSTALL_DIR/scripts"
		install -m 0755 "$SOURCE_DIR"/scripts/*.sh "$INSTALL_DIR/scripts/"
	else
		chmod 0755 "$INSTALL_DIR/setup.sh" "$INSTALL_DIR"/scripts/*.sh
	fi
	ln -sfn "$INSTALL_DIR/setup.sh" /usr/local/sbin/amp-runner-setup
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
		'{id:$id,mode:$mode,user:$user,workspace:$workspace,project:$project,repositoryURL:$repositoryURL,auth:$auth,service:$service,dockerAccess:$dockerAccess,baseRepository:$baseRepository,remoteTerminal:$remoteTerminal,createdAt:$createdAt}' \
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
Environment=HOME=$(user_home "$user")
Environment=PATH=/usr/local/bin:/opt/node/bin:/usr/local/go/bin:/opt/rust/cargo/bin:/usr/bin:/bin

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
	say
	say "Runner $id is installed for $project_ref."
	say "Status: sudo amp-runner-setup status $id"
	say "Logs:   sudo amp-runner-setup logs $id"
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
		[[ -n "$cid" ]] && docker exec "$cid" pkill -TERM -f "amp --no-tui --runner-id $id" >/dev/null 2>&1 || true
		;;
	esac
}

list_instances() {
	require_root list
	printf '%-28s %-13s %-10s %-28s %s\n' RUNNER MODE STATUS PROJECT WORKSPACE
	local file id service status
	shopt -s nullglob
	for file in "$STATE_DIR"/*.json; do
		id="$(jq -r '.id' "$file")"
		service="$(jq -r '.service' "$file")"
		status="$(systemctl is-active "$service.service" 2>/dev/null || true)"
		printf '%-28s %-13s %-10s %-28s %s\n' "$id" "$(jq -r '.mode' "$file")" "$status" "$(jq -r '.project' "$file")" "$(jq -r '.workspace' "$file")"
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

update_instances() {
	require_root update
	local target="${1:---all}" file id mode user image_built=false
	install_tool_files
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		[[ "$target" == --all || "$target" == "$id" ]] || continue
		mode="$(jq -r '.mode' "$file")"
		user="$(jq -r '.user' "$file")"
		case "$mode" in
		host | worktree)
			host_amp "$user" update
			;;
		docker)
			if [[ "$image_built" == false ]]; then build_image; image_built=true; fi
			local key=''
			[[ "$(jq -r '.auth' "$file")" == token ]] && key="$(token_path "$id")"
			container_amp "$id" "$(jq -r '.workspace' "$file")" "amp-runner-${id}-home" "$key" update
			;;
		devcontainer)
			local cid
			cid="$(devcontainer_up "$id" "$(jq -r '.workspace' "$file")")"
			devcontainer_amp "$id" "$cid" '' update || true
			;;
		esac
		systemctl restart "$(service_name "$id").service"
	done
}

doctor() {
	require_root doctor
	local failed=0
	check_os
	say "Host: $(hostname)"
	say "Memory: $(free -h | awk '/^Mem:/ {print $2 " total, " $7 " available"}')"
	say "Disk: $(df -h "$DATA_DIR" | awk 'NR==2 {print $2 " total, " $4 " available"}')"
	for command in docker git gh node npm python3 go rustc java devcontainer jq; do
		if command -v "$command" >/dev/null 2>&1; then
			printf 'ok      %s\n' "$command"
		else
			printf 'missing %s\n' "$command"
			failed=1
		fi
	done
	local file id service status
	for file in "$STATE_DIR"/*.json; do
		[[ -e "$file" ]] || continue
		id="$(jq -r '.id' "$file")"
		service="$(service_name "$id")"
		status="$(systemctl is-active "$service.service" 2>/dev/null || true)"
		printf '%-7s runner %s (%s)\n' "$status" "$id" "$(jq -r '.mode' "$file")"
		[[ "$status" == active ]] || failed=1
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
	rm -f /usr/local/sbin/amp-runner-setup
	rm -rf "$INSTALL_DIR"
	[[ "$purge" == --purge ]] && rm -rf "$CONFIG_DIR" "$DATA_DIR"
	say 'Amp runner setup tool removed. Installed OS packages were left in place.'
}

show_help() {
	cat <<EOF
Amp runner setup $VERSION

Usage:
  sudo ./setup.sh bootstrap [--harden-ssh] [--tailscale] [--non-interactive]
  sudo ./setup.sh add [options]
  sudo ./setup.sh list
  sudo ./setup.sh status RUNNER_ID
  sudo ./setup.sh logs RUNNER_ID [--follow]
  sudo ./setup.sh update [RUNNER_ID|--all]
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
  --docker-access none|socket

Run without a command for the terminal menu.
EOF
}

menu() {
	require_root
	ui_title 'Amp runner setup'
	local action
	action="$(ui_choose 'Action' 'Add runner' 'List runners' 'Runner status' 'Follow logs' 'Run health checks' 'Update runners' 'Provision host' 'Remove runner' 'Uninstall')"
	case "$action" in
	'Add runner') add_instance ;;
	'List runners') list_instances ;;
	'Runner status') show_status "$(ui_input 'Runner ID')" ;;
	'Follow logs') show_logs "$(ui_input 'Runner ID')" --follow ;;
	'Run health checks') doctor ;;
	'Update runners') update_instances --all ;;
	'Provision host') bootstrap ;;
	'Remove runner') remove_instance "$(ui_input 'Runner ID')" ;;
	'Uninstall') uninstall_tool ;;
	esac
}

main() {
	local command="${1:-}"
	[[ -n "$command" ]] && shift || true
	case "$command" in
	'') menu ;;
	bootstrap) bootstrap "$@" ;;
	add) add_instance "$@" ;;
	list) list_instances "$@" ;;
	status) (($# >= 1)) || die 'status requires RUNNER_ID'; show_status "$@" ;;
	logs) (($# >= 1)) || die 'logs requires RUNNER_ID'; show_logs "$@" ;;
	update) update_instances "$@" ;;
	doctor) doctor "$@" ;;
	remove) (($# >= 1)) || die 'remove requires RUNNER_ID'; remove_instance "$@" ;;
	uninstall) uninstall_tool "$@" ;;
	_run) run_instance "$@" ;;
	_stop) stop_instance_runtime "$@" ;;
	-h | --help | help) show_help ;;
	*) die "Unknown command: $command" ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
