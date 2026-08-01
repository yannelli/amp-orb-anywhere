#!/usr/bin/env bash
set -euo pipefail

NODE_MAJOR="${NODE_MAJOR:-24}"
GO_VERSION="${GO_VERSION:-latest}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	printf 'install-runtimes.sh must run as root\n' >&2
	exit 1
fi

machine="$(uname -m)"
case "$machine" in
	x86_64)
	node_arch=x64
	go_arch=amd64
	;;
	aarch64 | arm64)
	node_arch=arm64
	go_arch=arm64
	;;
	*)
	printf 'Unsupported CPU architecture: %s\n' "$machine" >&2
	exit 1
	;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

install_node() {
	local version archive install_dir
	version="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r --arg major "v${NODE_MAJOR}." '[.[] | select(.version | startswith($major)) | select(.lts != false)][0].version // empty')"
	if [[ -z "$version" ]]; then
		printf 'No Node.js %s LTS release was found\n' "$NODE_MAJOR" >&2
		exit 1
	fi
	if [[ -x /opt/node/bin/node ]] && [[ "$(/opt/node/bin/node --version)" == "$version" ]]; then
		return
	fi

	archive="node-${version}-linux-${node_arch}.tar.xz"
	curl -fsSL "https://nodejs.org/dist/${version}/${archive}" -o "$tmp_dir/$archive"
	curl -fsSL "https://nodejs.org/dist/${version}/SHASUMS256.txt" -o "$tmp_dir/SHASUMS256.txt"
	(
		cd "$tmp_dir"
		grep "  ${archive}$" SHASUMS256.txt | sha256sum --check --status
	)
	install_dir="/opt/node-${version}"
	rm -rf "$install_dir"
	mkdir -p "$install_dir"
	tar -xJf "$tmp_dir/$archive" --strip-components=1 -C "$install_dir"
	ln -sfn "$install_dir" /opt/node
	for command in node npm npx corepack; do
		ln -sfn "/opt/node/bin/$command" "/usr/local/bin/$command"
	done
	corepack enable
}

install_go() {
	local version checksum archive
	if [[ "$GO_VERSION" == latest ]]; then
		read -r version checksum < <(
			curl -fsSL 'https://go.dev/dl/?mode=json' |
				jq -r --arg arch "$go_arch" '.[0] as $release | [$release.version, ($release.files[] | select(.os == "linux" and .arch == $arch and .kind == "archive") | .sha256)] | @tsv'
		)
	else
		version="$GO_VERSION"
		[[ "$version" == go* ]] || version="go$version"
		checksum="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg version "$version" --arg arch "$go_arch" '.[] | select(.version == $version) | .files[] | select(.os == "linux" and .arch == $arch and .kind == "archive") | .sha256')"
	fi
	if [[ -z "${version:-}" || -z "${checksum:-}" ]]; then
		printf 'Could not resolve Go release %s for %s\n' "$GO_VERSION" "$go_arch" >&2
		exit 1
	fi
	if [[ -x /usr/local/go/bin/go ]] && [[ "$(/usr/local/go/bin/go version | awk '{print $3}')" == "$version" ]]; then
		return
	fi

	archive="${version}.linux-${go_arch}.tar.gz"
	curl -fsSL "https://go.dev/dl/${archive}" -o "$tmp_dir/$archive"
	printf '%s  %s\n' "$checksum" "$tmp_dir/$archive" | sha256sum --check --status
	rm -rf /usr/local/go
	tar -xzf "$tmp_dir/$archive" -C /usr/local
	ln -sfn /usr/local/go/bin/go /usr/local/bin/go
	ln -sfn /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

install_rust() {
	if [[ -x /opt/rust/cargo/bin/rustup ]]; then
		RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo /opt/rust/cargo/bin/rustup update "$RUST_TOOLCHAIN"
	else
		mkdir -p /opt/rust/rustup /opt/rust/cargo
		curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs |
			RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo sh -s -- -y --no-modify-path --default-toolchain "$RUST_TOOLCHAIN" --profile default
	fi
	for command in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt rustup; do
		[[ -e "/opt/rust/cargo/bin/$command" ]] && ln -sfn "/opt/rust/cargo/bin/$command" "/usr/local/bin/$command"
	done
}

install_node
install_go
install_rust

printf 'Node %s, %s, and Rust %s installed\n' "$(node --version)" "$(go version | awk '{print $3}')" "$(rustc --version | awk '{print $2}')"
