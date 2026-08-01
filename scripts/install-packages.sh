#!/usr/bin/env bash
set -euo pipefail

target="${1:-host}"
case "$target" in
	host | container) ;;
	*)
	printf 'Usage: %s host|container\n' "$0" >&2
	exit 2
	;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	printf 'install-packages.sh must run as root\n' >&2
	exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
if [[ "$ID" != ubuntu || "$VERSION_ID" != 24.04 ]]; then
	printf 'Ubuntu 24.04 is required, found %s %s\n' "$ID" "$VERSION_ID" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
	apt-transport-https bash-completion ca-certificates curl wget gnupg dirmngr openssl sudo util-linux \
	git git-lfs openssh-client jq rsync zip unzip p7zip-full xz-utils zstd \
	build-essential autoconf automake libtool pkg-config cmake ninja-build \
	gcc g++ clang clangd gdb lldb make \
	python3 python3-dev python3-pip python3-venv pipx \
	openjdk-21-jdk-headless maven \
	libssl-dev libffi-dev libreadline-dev zlib1g-dev libsqlite3-dev \
	libbz2-dev liblzma-dev libncurses-dev uuid-dev \
	ripgrep fd-find fzf shellcheck bubblewrap \
	tmux vim less tree procps lsof strace iproute2 iputils-ping dnsutils netcat-openbsd \
	sqlite3 postgresql-client redis-tools \
	ffmpeg imagemagick xvfb \
	libasound2t64 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
	libdrm2 libgbm1 libglib2.0-0 libgtk-3-0 libnspr4 libnss3 \
	libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 \
	libxfixes3 libxkbcommon0 libxrandr2 fonts-liberation fonts-noto-color-emoji

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
cat > /etc/apt/sources.list.d/github-cli.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main
EOF

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update -qq
apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin

if [[ "$target" == host ]]; then
	apt-get install -y --no-install-recommends \
		containerd.io docker-ce docker-ce-rootless-extras \
		fail2ban unattended-upgrades needrestart
	systemctl enable --now docker fail2ban

	curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
	cat > /etc/apt/sources.list.d/charm.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *
EOF
	apt-get update -qq
	apt-get install -y --no-install-recommends gum
fi

git lfs install --system
rm -rf /var/lib/apt/lists/*
