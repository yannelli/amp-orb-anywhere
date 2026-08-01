# Amp Orb Anywhere

<p align="center">
    <img src="art/banner.png" alt="Amp Orb Anywhere: self-hosted Amp runners on Lightsail." width="720">
</p>

[![GitHub last commit](https://img.shields.io/github/last-commit/yannelli/amp-orb-anywhere.svg?style=flat-square)](https://github.com/yannelli/amp-orb-anywhere/commits/master)
[![GitHub stars](https://img.shields.io/github/stars/yannelli/amp-orb-anywhere.svg?style=flat-square)](https://github.com/yannelli/amp-orb-anywhere/stargazers)

- [Introduction](#introduction)
- [Requirements](#requirements)
- [Installation](#installation)
  - [Bootstrap](#bootstrap)
  - [What Bootstrap Installs](#what-bootstrap-installs)
  - [Cloud-init](#cloud-init)
- [Adding Runners](#adding-runners)
  - [Interactive Setup](#interactive-setup)
  - [Non-interactive Setup](#non-interactive-setup)
  - [Instance Types](#instance-types)
- [Authentication and Projects](#authentication-and-projects)
- [Runner Behavior](#runner-behavior)
- [Operations](#operations)
  - [Commands](#commands)
  - [Persistent Paths](#persistent-paths)
- [Lightsail Sizing](#lightsail-sizing)
- [Networking and SSH](#networking-and-ssh)
- [Validation](#validation)
- [References](#references)

## Introduction

When you want Amp to keep working on a machine you control, a self-hosted runner is a persistent `amp --no-tui` process on that host. Amp Orb Anywhere provisions an Ubuntu 24.04 Lightsail VM (or any similar Ubuntu 24.04 box), installs a development toolchain, and manages one or more of those runners under systemd.

This repository is setup tooling for **self-hosted Amp runners**. It is not Amp Orbs. Orbs, orb portals, orb OIDC, and orb webhooks are separate Amp product features. Do not expect orb lifecycle hooks such as `.agents/setup` or `.amp/services.yaml` to drive these runners.

Checked against the Amp manual and Amp CLI `0.0.1785549193-gbb3f33` on 2026-08-01. Amp changes quickly. Confirm current flags and auth flow in the [Owner's Manual](https://ampcode.com/manual) before you rely on a command documented here.

## Requirements

- Fresh **Ubuntu 24.04** instance (Lightsail is the primary target)
- Root via `sudo`
- Outbound HTTPS, DNS, and WebSocket access (Amp, Git hosts, package registries)
- A non-root admin account for host-mode runners (`ubuntu` on Lightsail, or set `AMP_RUNNER_ADMIN_USER`)

No inbound ports are required by Amp. The runner opens outbound connections.

## Installation

### Bootstrap

Copy this repository onto the instance, then:

```bash
chmod +x setup.sh scripts/*.sh tests/test.sh
sudo ./setup.sh bootstrap
sudo amp-runner-setup add
```

`bootstrap` is idempotent. It installs packages, optional SSH hardening and Tailscale, builds the generic Docker image, and links `amp-runner-setup` to `/usr/local/sbin/amp-runner-setup`.

```bash
sudo ./setup.sh bootstrap [--harden-ssh] [--tailscale] [--non-interactive]
```

Runtime pins for bootstrap and the Docker image:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NODE_MAJOR` | `24` | Node.js major from NodeSource |
| `GO_VERSION` | `latest` | Go release (`latest` resolves at install time) |
| `RUST_TOOLCHAIN` | `stable` | Rust toolchain channel |

### What Bootstrap Installs

- Docker Engine, BuildKit, Buildx, and Compose from Docker's signed apt repository
- Git, Git LFS, GitHub CLI, build-essential, Clang, CMake, Ninja, and common native libraries
- Node.js 24 LTS, the current Go stable release, Rust stable, Python 3.12, and OpenJDK 21
- Browser and headless runtime libraries, Xvfb, ffmpeg, and ImageMagick
- `gum`, `jq`, `ripgrep`, `fzf`, `shellcheck`, tmux, database clients, and standard diagnostics
- Unattended security updates, fail2ban, and Docker log rotation

### Cloud-init

[`cloud-init.yaml`](cloud-init.yaml) prepares a fresh instance without embedding credentials. Set the repository URL (already pointed at this project by default), branch, and admin user before pasting it into Lightsail's launch script field. It runs a non-interactive host bootstrap. Amp and Tailscale login stay for the first SSH session:

```bash
sudo amp-runner-setup add
sudo tailscale up  # when Tailscale was requested at bootstrap
```

Cloud-init can take 10 to 25 minutes while it installs native toolchains and builds the runner image. Inspect progress with:

```bash
cloud-init status --wait
sudo journalctl -u cloud-final.service
sudo tail -n 200 /var/log/cloud-init-output.log
```

Do not put an Amp token, GitHub token, Tailscale reusable key, or SSH private key in Lightsail user data. Cloud-init logs and instance metadata can retain user data. Complete interactive login over SSH, or transfer a short-lived token file, use it, and delete the source file.

## Adding Runners

### Interactive Setup

After bootstrap, run the menu or add a runner:

```bash
sudo amp-runner-setup
# or
sudo amp-runner-setup add
```

The menu walks through mode, identity, Amp authentication, project selection, workspace, remote terminal, and Docker socket access.

### Non-interactive Setup

```bash
sudo amp-runner-setup add \
  --mode docker \
  --id build-1 \
  --auth token \
  --token-file /root/amp-token \
  --project owner/project \
  --clone \
  --no-remote-terminal \
  --docker-access none
```

| Option | Values | Notes |
| --- | --- | --- |
| `--mode` | `host`, `docker`, `worktree`, `devcontainer` | See [Instance Types](#instance-types) |
| `--id` | DNS label | Stable lowercase id used in unit names and volumes |
| `--auth` | `interactive`, `token` | Token mode needs `--token-file` |
| `--project` | `namespace/name` or project id | Selects from `amp projects list` |
| `--workspace` | absolute path | Defaults under `/srv/amp-runners/workspaces` |
| `--clone` / `--no-clone` | flag | Whether to clone the project repository |
| `--remote-terminal` / `--no-remote-terminal` | flag | Opt-in terminal for remotely controlled threads |
| `--docker-access` | `none`, `socket` | Host Docker socket mount for container modes |

Delete the source token file after setup. The installed copy lives under `/etc/amp-runner/secrets` with mode `0400` and is loaded by systemd as a credential.

### Instance Types

| Type | Intended use | Separation | Docker inside runner | Main risk |
| --- | --- | --- | --- | --- |
| `host` | One trusted runner on a dedicated VM | None | Full host daemon access | Amp and repository code act as the VM user. Docker access is equivalent to host root. |
| `docker` | Several independent runners on one VM | Container filesystem, process, per-runner bridge network, home volume, and workspace | Off by default; optional host socket | Containers share the host kernel. Mounting the Docker socket removes the meaningful host boundary. |
| `worktree` | Trusted concurrent work on one repository | Separate Git worktree only | Host access if the account is in `docker` | Every worktree runner uses the same Unix identity and Git object database. It is not a security boundary. |
| `devcontainer` | A project that already defines its toolchain in `devcontainer.json` | Whatever the project configuration provides | Controlled by `devcontainer.json` | Lifecycle commands are trusted code. `privileged`, host mounts, and Docker socket mounts can give host access. |

Use `host` on a VM dedicated to one trusted project. Use `docker` without `--docker-access socket` when runners on the same VM should not read each other's files. Use separate VMs for hostile repositories, separate trust domains, or credentials that must not be reachable by another runner. Linux containers are weaker isolation than a VM.

The generic Docker image ships a broad development toolchain. The service container drops all capabilities and enables `no-new-privileges`, so its `amp` user cannot elevate with sudo at runtime. Rebuild the image to add OS packages. Docker-based project builds fail unless you opt into the host socket or configure a separate remote builder.

Dev-container mode uses the project's `.devcontainer/devcontainer.json` or `.devcontainer.json`. It mounts a named volume at `/amp-runner-home`, installs Amp there, and reuses it across container rebuilds. The setup tool does not rewrite project configuration or override its security settings.

## Authentication and Projects

Interactive authentication runs `amp login`. On an SSH host it prints a URL for sign-in. Token authentication uses the documented `AMP_API_KEY` environment variable. Create an access token in [Amp security settings](https://ampcode.com/settings/security#access-token).

The selection screen is populated by `amp projects list --json`. A selected project's `repositoryURL` becomes the checkout's `origin`. `amp projects status --json` then matches the project by that remote. There is no runner-level project flag for `amp --no-tui`. The `--project` CLI option applies to `--orb-execute`, not the persistent runner command.

Amp authentication and Git-host authentication are separate. `amp clone namespace/name` covers Amp-hosted repositories. The setup offers `gh auth login` for GitHub repositories. Other private Git hosts need SSH keys, a credential helper, or another Git-supported credential mechanism in the runner identity.

Dev-container interactive setup can prompt for Amp login twice. The host login lists projects before a repository and its `devcontainer.json` exist. The second login is stored in the dev-container home volume and authenticates the runner. GitHub CLI and SSH behavior inside a project dev container depend on that project's configuration; put credentials in `/amp-runner-home` if the runner must push from the container.

Interactive credentials are stored by Amp in the runner's persistent home. On Linux Amp currently uses `~/.local/share/amp/secrets.json`. A container's home is a named Docker volume. Token mode stores the token under `/etc/amp-runner/secrets` and passes it to Amp at process start. Commands launched by Amp can share its process environment, so use a dedicated, revocable token and assume the agent can act with that identity.

## Runner Behavior

A self-hosted runner is a persistent Amp CLI process. It is not an Amp orb.

- The service command is `amp --no-tui --runner-id ID`. Runner IDs are stable lowercase DNS labels in this tool.
- `--remote-control-terminal` is opt-in because it grants terminal access to users who can control the thread.
- Threads use the runner's current checkout. They do not receive a fresh clone or a fresh machine.
- Amp project, workspace, and personal secrets configured for orbs are not automatically injected into this VM.
- `.agents/setup`, `.agents/resume`, `.amp/services.yaml`, orb portals, orb OIDC, and orb webhooks are orb features. Do not rely on them for runner lifecycle management.
- Project plugins in `.amp/plugins/*.ts` load from the checkout. System plugins under `~/.config/amp/plugins/*.ts` persist in the runner home. Plugins execute trusted code with the same access as Amp.
- OAuth MCP servers can require an interactive callback and persistent token storage. Test each server in the chosen mode. The Amp manual currently calls out an OAuth limitation for orbs, not self-hosted runners.

The agent executes tools without approval by default. Use an Amp policy plugin or permissions configuration for repositories that need command restrictions. A policy running inside the same account is a guardrail, not protection from malicious code that already has host execution.

## Operations

### Commands

```bash
sudo amp-runner-setup list
sudo amp-runner-setup status build-1
sudo amp-runner-setup logs build-1 --follow
sudo amp-runner-setup doctor
sudo amp-runner-setup update --all
sudo amp-runner-setup remove build-1
sudo amp-runner-setup remove build-1 --purge
```

Each runner has an `amp-runner-ID.service` unit with `Restart=always`, a five-second restart delay, and a 45-second stop timeout. Logs go to journald. `doctor` checks required tools, memory, disk, and every service. Amp has no documented runner readiness endpoint, so these are process checks and do not prove the runner is registered with Amp's service. Amp's default `amp.updates.mode` is `auto`; `amp-runner-setup update` forces CLI updates, rebuilds the generic container image, and restarts selected services.

`remove` keeps workspaces and Docker home volumes by default. Retained home volumes contain Amp and Git-host credentials. `--purge` deletes them. `uninstall` removes services and this tool but leaves installed OS packages in place.

### Persistent Paths

| Path | Contents |
| --- | --- |
| `/opt/amp-runner` | Installed setup tool and generic image source |
| `/etc/amp-runner/instances` | Non-secret instance metadata |
| `/etc/amp-runner/secrets` | Amp access tokens for token-authenticated services |
| `/srv/amp-runners/workspaces` | Default workspaces |
| `/srv/amp-runners/repositories` | Base repositories used by worktree mode |
| Docker volume `amp-runner-ID-home` | Amp, GitHub CLI, plugin, and shell state for container modes |

Override install locations with `AMP_RUNNER_INSTALL_DIR`, `AMP_RUNNER_CONFIG_DIR`, `AMP_RUNNER_DATA_DIR`, and `AMP_RUNNER_IMAGE` when needed.

## Lightsail Sizing

Current public IPv4 Linux bundle prices on 2026-08-01 from the [Lightsail pricing page](https://aws.amazon.com/lightsail/pricing/):

| Workload | Suggested minimum | Current general-purpose bundle |
| --- | --- | --- |
| One host runner, light Node/Python work | 2 vCPU, 4 GB RAM, 80 GB disk | $24/month |
| One runner with browsers, Java, or Docker builds | 2 vCPU, 8 GB RAM, 160 GB disk | $44/month |
| Two to four container runners | 4 vCPU, 16 GB RAM, 320 GB disk | $84/month |
| CPU-heavy builds | 4 vCPU, 8 GB RAM, 320 GB disk | $84/month compute optimized |

The 1 GB and 2 GB plans are too small for the installed image and ordinary agent workloads. Concurrent compiler, browser, and language-server processes can use several gigabytes each. Watch memory, disk, Docker build cache, and inode use. Prefer a larger bundle over swap for sustained builds. A small 2 to 4 GB swap file can absorb short spikes; severe swap pressure makes the runner unresponsive.

Lightsail instances continue billing while stopped. Snapshots and attached disks have separate charges. The static IPv4 address is free while attached to a running instance and is not required by Amp, because the runner opens outbound connections.

## Networking and SSH

Amp runners need outbound HTTPS, DNS, and WebSocket access. Amp documents these required domains: `ampcode.com`, `auth.ampcode.com`, `production.ampworkers.com`, and `static.ampcode.com`. Git hosts, package registries, model-provider integrations, MCP servers, and Tailscale need their own outbound access.

For the Lightsail firewall:

1. Remove the default public HTTP rule unless another service needs it.
2. Restrict TCP 22 to your current public IP or VPN CIDR. Lightsail creates independent IPv4 and IPv6 firewalls, so change both.
3. Do not expose Docker port 2375, databases, development servers, or headless browser debugging ports.
4. If Tailscale SSH is working, remove public SSH from both Lightsail firewalls. Keep the Lightsail browser console available as a recovery path.

Optional bootstrap SSH hardening disables password login, keyboard-interactive login, root login, and X11 forwarding. It refuses to run unless the admin account has an `authorized_keys` file. Open a second key-authenticated SSH session before enabling it. The script leaves TCP forwarding enabled because developers commonly use SSH tunnels.

Tailscale installation follows its signed Ubuntu repository. Run `sudo tailscale up`, or select the option during interactive bootstrap. Tailscale recommends disabling key expiry only for trusted servers, with prompt revocation after loss or compromise.

## Validation

Repository validation does not modify the host:

```bash
./tests/test.sh
```

It checks Bash syntax, runner-ID validation, project selection parsing, help output, required security defaults, and the absence of unsupported runner flags. A full Docker build is intentionally separate because it downloads several gigabytes:

```bash
docker build --pull -t amp-runner:test .
docker run --rm amp-runner:test amp --version
```

## References

- [Amp Owner's Manual](https://ampcode.com/manual) (Runners, Projects, CLI, Configuration, Plugins)
- [Amp Orbs manual](https://ampcode.com/manual/orbs)
- [Amp security reference](https://ampcode.com/security)
- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker daemon attack surface](https://docs.docker.com/engine/security/)
- [Dev Container CLI](https://github.com/devcontainers/cli)
- [GitHub CLI Linux installation](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Lightsail firewall rules](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-firewall-and-port-mappings-in-amazon-lightsail.html)
