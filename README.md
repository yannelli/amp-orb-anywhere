# Amp Orb Anywhere

<p align="center">
    <img src="art/banner.png" alt="Amp Orb Anywhere: keep Amp running on infrastructure you control." width="720">
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
  - [Fleet Provisioning](#fleet-provisioning)
  - [Non-interactive Setup](#non-interactive-setup)
  - [Instance Types](#instance-types)
- [Authentication and Projects](#authentication-and-projects)
- [Runner Behavior](#runner-behavior)
  - [Secure Web Workspace](#secure-web-workspace)
  - [Feature Compatibility](#feature-compatibility)
- [Operations](#operations)
  - [Commands](#commands)
  - [Automatic Updates](#automatic-updates)
  - [Persistent Paths](#persistent-paths)
- [Releases and Versioning](#releases-and-versioning)
- [Lightsail Sizing](#lightsail-sizing)
- [Networking and SSH](#networking-and-ssh)
- [Validation](#validation)
- [References](#references)

## Introduction

A self-hosted Amp runner is a persistent `amp --no-tui` process on a machine you control. Amp Orb Anywhere also manages OpenAI Codex and Anthropic Claude Code as independent Docker workspaces. Codex and Claude are not registered with or managed by Amp. Claude's documented headless Remote Control can stay online in its container. Codex can run its shipped experimental Remote Control daemon, but OpenAI does not document that daemon as a supported substitute for its desktop Remote workflow. The project provisions an Ubuntu 24.04 Lightsail VM (or a similar Ubuntu 24.04 host), installs a development toolchain, and manages all three agents under systemd.

This repository does not turn a VM or Docker container into an Amp-managed orb. Managed orbs depend on Amp infrastructure for fresh per-thread VMs, pause and resume, portals, OIDC, secrets, webhooks, apps, multiplayer, and `amp sync`. Local counterparts include an authenticated browser workspace with terminal, Chromium, Firefox, and file management. The setup command prints the current boundary with `amp-runner-setup capabilities`.

Checked against the Amp manual, the current [Codex CLI documentation](https://developers.openai.com/codex/cli), OpenAI's secure Codex dev-container configuration, Anthropic's [Claude Code setup guide](https://code.claude.com/docs/en/setup), and the [Claude Remote Control guide](https://code.claude.com/docs/en/remote-control) on 2026-08-01. The images use both vendors' native installers and resolve their latest releases whenever they are rebuilt.

## Requirements

- Fresh Ubuntu 24.04 instance (Lightsail is the primary target)
- Root via `sudo`
- Outbound HTTPS, DNS, and WebSocket access (Amp, OpenAI, Anthropic, Git hosts, and package registries)
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

`bootstrap` is idempotent. It installs packages, optional SSH hardening and Tailscale, builds the generic Docker image, enables the release update timer, and links `amp-runner-setup` to `/usr/local/sbin/amp-runner-setup`. The larger web workspace image is built only when the first workspace is enabled.

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
- `agent-browser`, Chrome for Testing on amd64, browser runtime libraries, Xvfb, ffmpeg, and ImageMagick
- `gum`, `jq`, `ripgrep`, `fzf`, `shellcheck`, tmux, database clients, and standard diagnostics
- Unattended security updates, fail2ban, and Docker log rotation

### Cloud-init

[`cloud-init.yaml`](cloud-init.yaml) prepares a fresh instance without embedding credentials. Set the repository URL (defaults to this project), branch, and admin user before pasting it into Lightsail's launch script field. It runs a non-interactive host bootstrap. Finish Amp and Tailscale login on first SSH:

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

After bootstrap, open the control dashboard or add an agent workspace directly:

```bash
sudo amp-runner-setup
# or
sudo amp-runner-setup add
```

The dashboard starts with an agent picker. It has fleet provisioning, repository search, per-repository counts, lifecycle controls, interactive agent and shell access, authentication, API-key rotation, secure web workspaces, updates, diagnostics, and a feature compatibility screen. Its searchable menus use `gum` and fall back to numbered shell menus.

### Fleet Provisioning

Select Amp, Codex, or Claude, choose any subset of the available repositories, then set a workspace count for each:

```bash
sudo amp-runner-setup provision
```

Amp discovery uses `amp projects list`. Codex and Claude discovery uses the authenticated host `gh` account and includes repositories where it is an owner, collaborator, or organization member. The wizard supports an `all repositories` selection, previews the plan, and creates stable workspace IDs. Each Docker workspace has independent agent and GitHub authentication state.

The same operation is scriptable. Repeat `--repository` and append `=COUNT` when a repository needs more than one workspace:

```bash
sudo amp-runner-setup provision \
  --agent amp \
  --mode docker \
  --auth token \
  --token-file /root/amp-token \
  --repository owner/api=2 \
  --repository owner/web=3 \
  --clone \
  --remote-terminal \
  --desktop \
  --desktop-access tailscale \
  --docker-access none
```

Create missing Amp projects first with `amp projects create REPOSITORY`. Codex and Claude do not require an Amp project.

### Non-interactive Setup

```bash
sudo amp-runner-setup add \
  --agent codex \
  --mode docker \
  --id codex-build-1 \
  --auth interactive \
  --repository owner/project \
  --clone \
  --no-remote-terminal \
  --native-remote \
  --desktop \
  --desktop-access ssh \
  --docker-access none
```

| Option | Values | Notes |
| --- | --- | --- |
| `--agent` | `amp`, `codex`, `claude` | Defaults to an interactive picker |
| `--mode` | `host`, `docker`, `worktree`, `devcontainer` | See [Instance Types](#instance-types) |
| `--id` | DNS label | Stable lowercase id used in unit names and volumes |
| `--auth` | `interactive`, `token` | Token mode needs `--token-file` |
| `--repository` | `owner/name` | Amp selects a matching project; Codex and Claude select from GitHub CLI |
| `--workspace` | absolute path | Defaults under `/srv/amp-runners/workspaces` |
| `--clone` / `--no-clone` | flag | Whether to clone the project repository |
| `--remote-terminal` / `--no-remote-terminal` | flag | Amp only: opt-in terminal for remotely controlled threads |
| `--native-remote` / `--no-native-remote` | flag | Codex/Claude only: persistent provider-native Remote Control; requires account login |
| `--desktop` / `--no-desktop` | flag | Per-runner browser workspace with terminal, browsers, and files |
| `--desktop-access` | `tailscale`, `ssh` | Tailnet HTTPS route or loopback service reached through SSH |
| `--docker-access` | `none`, `socket` | Amp only: host Docker socket mount for container mode |

Delete the source token file after setup. The installed copy lives under `/etc/amp-runner/secrets` with mode `0400`. API keys are mounted read-only at runtime rather than placed in state, image layers, environment literals, or command-line arguments.

### Instance Types

Amp supports all four modes below. Codex and Claude currently use Docker mode only. With native Remote Control enabled, the systemd service runs the provider's remote server in the persistent workspace container. Without it, the container stays idle until the TUI, `connect`, or the web desktop starts a CLI.

| Type | Intended use | Separation | Docker inside runner | Main risk |
| --- | --- | --- | --- | --- |
| `host` | One trusted runner on a dedicated VM | None | Full host daemon access | Amp and repository code act as the VM user. Docker access is equivalent to host root. |
| `docker` | Several independent runners on one VM | Container filesystem, process, per-runner bridge network, home volume, and workspace | Off by default; optional host socket | Containers share the host kernel. Mounting the Docker socket removes the meaningful host boundary. |
| `worktree` | Trusted concurrent work on one repository | Separate Git worktree only | Host access if the account is in `docker` | Every worktree runner uses the same Unix identity and Git object database. It is not a security boundary. |
| `devcontainer` | A project that already defines its toolchain in `devcontainer.json` | Whatever the project configuration provides | Controlled by `devcontainer.json` | Lifecycle commands are trusted code. `privileged`, host mounts, and Docker socket mounts can give host access. |

Pick `host` for one trusted project on a dedicated VM. Pick `docker` without `--docker-access socket` when co-located runners must not read each other's files. Put hostile repositories, separate trust domains, or mutually unreachable credentials on separate VMs. A Linux container shares the host kernel; it is weaker isolation than a VM.

The generic Docker image includes a broad development toolchain. The service container drops all capabilities and sets `no-new-privileges`, so the `amp` user cannot elevate with sudo at runtime. Rebuild the image to add OS packages. In-container Docker builds need `--docker-access socket` or a separate remote builder.

Codex is the exception to the default Docker capability profile. OpenAI's current Linux sandbox uses setuid bubblewrap inside the container. The headless Codex service drops all capabilities, then adds only `SYS_ADMIN`, `SYS_CHROOT`, `SETUID`, `SETGID`, and `SYS_PTRACE`, and disables the outer Docker seccomp and AppArmor profiles. Webtop retains Docker's default capability set for its root init, then adds the same sandbox capabilities. Codex applies its own inner seccomp policy after bubblewrap creates the namespace. This is narrower than `--privileged`, excludes OpenAI's optional firewall-only `NET_ADMIN` and `NET_RAW` capabilities, and still weakens the outer container boundary. Use a separate VM for untrusted repositories or trust domains. Claude needs none of these added capabilities.

Dev-container mode uses the project's `.devcontainer/devcontainer.json` or `.devcontainer.json`. It mounts a named volume at `/amp-runner-home`, installs Amp there, and reuses that home across rebuilds. The setup tool does not rewrite project configuration or change the project's security settings.

## Authentication and Projects

Interactive authentication runs `amp login`. On an SSH host it prints a URL for sign-in. Token authentication uses the documented `AMP_API_KEY` environment variable. Create an access token in [Amp security settings](https://ampcode.com/settings/security#access-token).

The selection screen is populated by `amp projects list --json`. A selected project's `repositoryURL` becomes the checkout's `origin`. `amp projects status --json` then matches the project by that remote. There is no runner-level project flag for `amp --no-tui`. The `--project` CLI option applies to `--orb-execute`, not the persistent runner command.

Amp authentication and Git-host authentication are separate. `amp clone namespace/name` covers Amp-hosted repositories. The setup offers `gh auth login` for GitHub. Other private Git hosts need SSH keys, a credential helper, or another Git credential mechanism on the runner identity.

For a GitHub-backed Docker workspace, setup copies the authenticated host `gh` credential into that workspace over stdin, then configures Git's `gh` credential helper. The token is never placed in state, Docker environment literals, argv, or a clone URL. Each selected workspace receives the host GitHub identity's repository access, so use a dedicated, least-privilege GitHub account or token when workspaces should not share your full account scope.

Dev-container interactive setup can prompt for Amp login twice. The host login lists projects before a repository and its `devcontainer.json` exist. The second login is stored in the dev-container home volume for the runner process. GitHub CLI and SSH inside a project dev container follow that project's configuration. Put push credentials in `/amp-runner-home` when the runner must push from the container.

Interactive credentials are stored by Amp in the runner's persistent home. On Linux Amp currently uses `~/.local/share/amp/secrets.json`. A container's home is a named Docker volume. Token mode stores the token under `/etc/amp-runner/secrets` and passes it to Amp at process start. Child commands can inherit that environment. Use a dedicated, revocable token and treat the agent as that identity.

Codex and Claude have independent authentication flows and homes:

```bash
# Codex: codex login --device-auth
# Claude: claude auth login
sudo amp-runner-setup authenticate WORKSPACE_ID

# Native provider Remote Control lifecycle
sudo amp-runner-setup remote enable WORKSPACE_ID
sudo amp-runner-setup remote status WORKSPACE_ID
sudo amp-runner-setup remote pair CODEX_ID
sudo amp-runner-setup remote disable WORKSPACE_ID

# Run the agent TUI or a provider-specific noninteractive command
sudo amp-runner-setup connect WORKSPACE_ID
sudo amp-runner-setup connect CODEX_ID -- exec 'Review the current changes'
sudo amp-runner-setup connect CLAUDE_ID -- -p 'Review the current changes'

# Rotate or remove an API key without putting it in argv
sudo amp-runner-setup credentials set WORKSPACE_ID --token-file /secure/key
sudo amp-runner-setup credentials clear WORKSPACE_ID
```

The named home volume is mounted at `/agent-home`. Codex uses `CODEX_HOME=/agent-home/.codex`. Claude uses `CLAUDE_CONFIG_DIR=/agent-home/.claude`, following Anthropic's current guidance so OAuth state and settings survive container rebuilds. Token mode maps the read-only secret to `OPENAI_API_KEY` or `ANTHROPIC_API_KEY` inside the agent process. Clearing a key retains any interactive login already stored in the volume.

Native Remote Control requires provider account login; API keys are rejected. Claude Remote Control defaults on for interactive workspaces. Authentication also opens Claude once to satisfy Anthropic's workspace-trust requirement. Claude then runs `claude remote-control --spawn session`; the workspace appears at [claude.ai/code](https://claude.ai/code) and in the Claude mobile app. It requires a Pro, Max, Team, or Enterprise subscription. Team and Enterprise owners must enable it in Claude Code admin settings.

Codex Remote Control is opt-in with `--native-remote`. Codex `0.146.0` ships experimental `remote-control start`, `stop`, and `pair` commands, which this project runs and supervises. OpenAI's public Remote documentation supports mobile control through the ChatGPT desktop app on macOS or Windows, including projects reached from that app over SSH. It does not support or guarantee direct headless Linux/container pairing as an end-user workflow. Treat the Codex integration as experimental and expect its command and pairing behavior to change. Both implementations make outbound TLS connections and open no inbound container port. Provider relays store synchronized session data under their respective data policies.

Codex and Claude are installed with the vendors' native installers. Their native background updaters remain enabled on the latest channel. The host update timer also resolves current release versions, rebuilds both images, and recreates affected containers. This covers idle containers where a CLI background updater has not run recently.

## Runner Behavior

A self-hosted runner is a persistent Amp CLI process under your systemd unit. Orb-only features do not apply to it.

- The service command is `amp --no-tui --runner-id ID`. Runner IDs are stable lowercase DNS labels in this tool.
- `--remote-control-terminal` is opt-in. It grants terminal access to users who can control the thread.
- Threads use the runner's current checkout. They do not get a fresh clone or a fresh machine.
- Amp project, workspace, and personal secrets configured for orbs are not injected into this VM.
- `.agents/setup`, `.agents/resume`, `.amp/services.yaml`, orb portals, orb OIDC, and orb webhooks manage orbs. Do not rely on them for runner lifecycle.
- Project plugins in `.amp/plugins/*.ts` load from the checkout. System plugins under `~/.config/amp/plugins/*.ts` persist in the runner home. Plugins run with the same access as Amp.
- OAuth MCP servers can require an interactive callback and persistent token storage. Test each server in the chosen mode. The Amp manual currently documents an OAuth limitation for orbs; self-hosted runners are a different surface.

The agent executes tools without approval by default. Use an Amp policy plugin or permissions configuration when a repository needs command restrictions. A policy in the same account only constrains willing tools. It does not stop malicious code that already has host execution.

### Secure Web Workspace

Each agent workspace can have a separate LinuxServer Webtop companion. The XFCE application menu exposes Chromium, Firefox ESR, XFCE Terminal, and Thunar. Codex and Claude are available directly in the terminal for their respective workspaces. Selkies provides the browser-delivered desktop and file transfer UI. The repository is mounted read-write at `/workspace`; the desktop home and browser profiles persist in a separate `amp-runner-ID-desktop` Docker volume.

Enable it during runner provisioning or later:

```bash
sudo amp-runner-setup desktop enable build-1 --access tailscale
sudo amp-runner-setup desktop credentials build-1
```

The first enable builds the desktop image and can download more than a gigabyte. The installer generates a 48-character password, stores both login fields under `/etc/amp-runner/secrets` with mode `0400`, and passes them to Webtop through read-only secret mounts. Rotate it at any time:

```bash
sudo amp-runner-setup desktop rotate-password build-1
```

Access modes:

- `tailscale` publishes a path such as `https://runner.example.ts.net/desktop/build-1/` through Tailscale Serve. Tailscale terminates TLS, applies tailnet access controls, and Webtop still requires its generated login. Tailscale may print a one-time consent URL when HTTPS certificates or Serve have not been enabled for the tailnet.
- `ssh` keeps Webtop on host loopback. `desktop credentials` prints the SSH forwarding command, local HTTPS URL, and login. Webtop uses a self-signed certificate inside the encrypted tunnel.

The installer never publishes the desktop on `0.0.0.0` and does not use Tailscale Funnel. The container receives no Docker socket or privileged mode. Passwordless sudo is disabled. Codex and Claude desktops mount only that workspace's agent home and optional read-only API-key secret; Amp desktops receive no runner home. Anyone who can sign in still receives a terminal, browser network access, agent credentials, and read-write control of the repository, so grant access as carefully as shell access.

This is a local desktop counterpart. It does not register as an Amp portal, attach to an orb thread, or inherit Amp-managed OIDC and secrets.

### Feature Compatibility

| Capability | Self-hosted runner | Notes |
| --- | --- | --- |
| Independent Codex and Claude workspaces | Yes | Persistent Docker home, repository, CLI/shell access, interactive login or API key |
| Claude native Remote Control | Yes | Documented headless, outbound-only relay with account login and web/mobile sessions |
| Codex native Remote Control | Experimental | Opt-in shipped CLI daemon and pairing command; not a publicly supported substitute for OpenAI's desktop Remote workflow |
| Remote thread creation | Yes | Amp web, app, TUI, and plugins can target a live runner ID |
| Web terminal | Yes | Enable per runner with `--remote-terminal` or the dashboard |
| Secure browser workspace | Yes | Tailnet HTTPS or SSH tunnel, generated login, terminal, Chromium, Firefox, and Thunar |
| Amp modes, Fast, plugins, skills, MCP, schedules | Yes | Modes and Fast are selected by the client per thread; the runner must remain online |
| Browser automation | Host and generic Docker modes | `agent-browser` supports headless and Xvfb-backed headed sessions; project dev containers control their own tools |
| Fresh machine and clone per thread | No | A runner reuses its checkout and machine |
| Portals, apps, orb service supervision | No | `amp orb portal` and `.amp/services.yaml` require an Amp-managed orb |
| OIDC, orb secrets, webhook wakeups | No | These depend on Amp's managed identity and event infrastructure |
| Multiplayer orb access and `amp sync` | No | These are orb thread features |

Amp does not currently document a Desktop experimental switch. This project supplies its own per-runner Webtop rather than writing unknown values to Amp configuration. The desktop browser and mobile clients can still control a runner. The only documented CLI thread feature is Fast. Experimental custom agent modes are registered by plugins.

## Operations

### Commands

```bash
sudo amp-runner-setup list
sudo amp-runner-setup status build-1
sudo amp-runner-setup logs build-1 --follow
sudo amp-runner-setup restart build-1
sudo amp-runner-setup connect codex-build-1
sudo amp-runner-setup shell codex-build-1
sudo amp-runner-setup authenticate codex-build-1
sudo amp-runner-setup remote enable codex-build-1
sudo amp-runner-setup remote status codex-build-1
sudo amp-runner-setup remote pair codex-build-1
sudo amp-runner-setup credentials set codex-build-1 --token-file /secure/openai-key
sudo amp-runner-setup credentials clear codex-build-1
sudo amp-runner-setup configure build-1 --remote-terminal
sudo amp-runner-setup desktop enable build-1 --access tailscale
sudo amp-runner-setup desktop status build-1
sudo amp-runner-setup desktop access build-1 ssh
sudo amp-runner-setup desktop disable build-1
sudo amp-runner-setup desktop-update --all
sudo amp-runner-setup doctor
sudo amp-runner-setup update --all
sudo amp-runner-setup self-update
sudo amp-runner-setup auto-update status
sudo amp-runner-setup capabilities
sudo amp-runner-setup remove build-1
sudo amp-runner-setup remove build-1 --purge
```

Each workspace has an `amp-runner-ID.service` unit with `Restart=always`, a five-second restart delay, and a 45-second stop timeout. Amp units run the persistent runner. Codex and Claude units run their native Remote Control server when enabled, or hold an idle container when disabled. Logs go to journald. `doctor` checks required tools, memory, disk, and every service. Amp has no documented runner readiness endpoint, so these checks only prove the process is up. They do not prove registration with Amp's service. `amp-runner-setup update` resolves the latest Codex and Claude releases, rebuilds the generic image, updates Amp, and restarts selected services.

`remove` keeps workspaces and Docker home volumes by default. Retained home volumes contain Amp and Git-host credentials. `--purge` deletes them. `uninstall` removes services and this tool. Installed OS packages stay.

### Automatic Updates

Bootstrap enables `amp-runner-update.timer`. Every six hours, with a randomized delay, it:

1. Checks the latest GitHub release for this repository and installs newer setup files.
2. Resolves current Codex and Claude Code releases, runs their native installers during image rebuilds, and restarts agent containers only when the image changed.
3. Runs `amp update` in every Amp runner home.
4. Rebuilds enabled web workspace images and restarts affected services.

Amp also defaults `amp.updates.mode` to `auto`. The timer covers persistent headless runners explicitly and picks up installer, image, and browser-tool changes published by this project.

```bash
sudo amp-runner-setup auto-update enable
sudo amp-runner-setup auto-update disable
sudo journalctl -u amp-runner-update.service
```

Set `AMP_RUNNER_UPDATE_REPOSITORY=owner/repository` when maintaining a fork with its own GitHub releases.

### Persistent Paths

| Path | Contents |
| --- | --- |
| `/opt/amp-runner` | Installed setup tool and generic image source |
| `/etc/amp-runner/instances` | Non-secret instance metadata |
| `/etc/amp-runner/secrets` | Amp, OpenAI, and Anthropic API keys for token-authenticated services |
| `/srv/amp-runners/workspaces` | Default workspaces |
| `/srv/amp-runners/repositories` | Base repositories used by worktree mode |
| Docker volume `amp-runner-ID-home` | Amp state, or isolated Codex/Claude auth, configuration, sessions, GitHub CLI, and shell state |
| Docker volume `amp-runner-ID-desktop` | Web workspace home, browser profiles, and XFCE settings |

Override install locations with `AMP_RUNNER_INSTALL_DIR`, `AMP_RUNNER_CONFIG_DIR`, `AMP_RUNNER_DATA_DIR`, `AMP_RUNNER_IMAGE`, and `AMP_RUNNER_DESKTOP_IMAGE` when needed.

## Releases and Versioning

The project uses SemVer and Release Please. Release PRs keep `VERSION`, the release manifest, and `setup.sh` in sync. The manifest is empty only before the initial `v1.0.0` release.

- `fix:` commits produce patch releases.
- `feat:` commits produce minor releases.
- `BREAKING CHANGE:` or `!` produce major releases.
- Other commit types appear in history but do not force a release unless configured by Release Please.

CI runs the Bash tests and ShellCheck on pushes and pull requests. After releasable commits reach `master`, Release Please opens or updates one release PR with the version bump and `CHANGELOG.md`. Merging that PR creates `vX.Y.Z` and a GitHub release, which is the source consumed by `self-update` and the systemd timer.

The repository must allow GitHub Actions read/write access and allow Actions to create pull requests. The workflow uses the repository `GITHUB_TOKEN`; no release token is stored in the project.

## Lightsail Sizing

Current public IPv4 Linux bundle prices on 2026-08-01 from the [Lightsail pricing page](https://aws.amazon.com/lightsail/pricing/):

| Workload | Suggested minimum | Current general-purpose bundle |
| --- | --- | --- |
| One host runner, light Node/Python work | 2 vCPU, 4 GB RAM, 80 GB disk | $24/month |
| One runner with a web workspace, browsers, Java, or Docker builds | 2 vCPU, 8 GB RAM, 160 GB disk | $44/month |
| Two to four container runners | 4 vCPU, 16 GB RAM, 320 GB disk | $84/month |
| CPU-heavy builds | 4 vCPU, 8 GB RAM, 320 GB disk | $84/month compute optimized |

The 1 GB and 2 GB plans are too small for the installed image and ordinary agent workloads. Concurrent compiler, browser, and language-server processes can use several gigabytes each. Watch memory, disk, Docker build cache, and inode use. Prefer a larger bundle over swap for sustained builds. A 2 to 4 GB swap file can absorb short spikes. Heavy swap pressure makes the runner unresponsive.

Lightsail instances continue billing while stopped. Snapshots and attached disks have separate charges. A static IPv4 address is free while attached to a running instance. Amp does not require one; the runner dials out.

## Networking and SSH

Amp runners need outbound HTTPS, DNS, and WebSocket access. Amp documents these required domains: `ampcode.com`, `auth.ampcode.com`, `production.ampworkers.com`, and `static.ampcode.com`. Git hosts, package registries, model-provider integrations, MCP servers, and Tailscale need their own outbound access.

For the Lightsail firewall:

1. Remove the default public HTTP rule unless another service needs it.
2. Restrict TCP 22 to your current public IP or VPN CIDR. Lightsail creates independent IPv4 and IPv6 firewalls, so change both.
3. Do not expose Docker port 2375, Webtop ports, databases, development servers, or headless browser debugging ports. Use Tailscale Serve or the generated SSH tunnel for a web workspace.
4. If Tailscale SSH is working, remove public SSH from both Lightsail firewalls. Keep the Lightsail browser console available as a recovery path.

Optional bootstrap SSH hardening disables password login, keyboard-interactive login, root login, and X11 forwarding. It refuses to run unless the admin account has an `authorized_keys` file. Open a second key-authenticated SSH session before enabling it. The script leaves TCP forwarding enabled because developers commonly use SSH tunnels.

Tailscale installation follows its signed Ubuntu repository. Run `sudo tailscale up`, or select the option during interactive bootstrap. Tailscale recommends disabling key expiry only for trusted servers, with prompt revocation after loss or compromise.

## Validation

Repository validation does not modify the host:

```bash
./tests/test.sh
```

It checks Bash syntax, SemVer source consistency, workspace-ID and fleet parsing, provider state and dispatch, project selection, help output, secret handling, Codex sandbox arguments, required security defaults, and the automatic updater. CI also runs ShellCheck. A full Docker build is intentionally separate because it downloads several gigabytes:

```bash
docker build --pull -t amp-runner:test .
docker run --rm amp-runner:test amp --version
docker run --rm amp-runner:test codex --version
docker run --rm amp-runner:test claude --version
```

## References

- [Amp Owner's Manual](https://ampcode.com/manual) (Runners, Projects, CLI, Configuration, Plugins)
- [Amp Orbs manual](https://ampcode.com/manual/orbs)
- [Amp security reference](https://ampcode.com/security)
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
- [OpenAI Codex authentication](https://developers.openai.com/codex/auth)
- [OpenAI Codex remote connections](https://developers.openai.com/codex/remote-connections)
- [OpenAI Codex secure dev-container profile](https://github.com/openai/codex/blob/main/.devcontainer/devcontainer.secure.json)
- [Anthropic Claude Code setup](https://code.claude.com/docs/en/setup)
- [Anthropic Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)
- [Anthropic Claude Code development containers](https://code.claude.com/docs/en/devcontainer)
- [Release Please](https://github.com/googleapis/release-please)
- [agent-browser](https://agent-browser.dev/installation)
- [LinuxServer Webtop](https://docs.linuxserver.io/images/docker-webtop/)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker daemon attack surface](https://docs.docker.com/engine/security/)
- [Dev Container CLI](https://github.com/devcontainers/cli)
- [GitHub CLI Linux installation](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Lightsail firewall rules](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-firewall-and-port-mappings-in-amazon-lightsail.html)
