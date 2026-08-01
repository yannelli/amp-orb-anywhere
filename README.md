# Amp runner setup for Ubuntu 24.04 Lightsail

`setup.sh` provisions an Ubuntu 24.04 VM and manages one or more persistent Amp runners. It installs the development toolchain, asks for Amp authentication, lists the Amp projects available to that identity, prepares a matching Git checkout, and starts `amp --no-tui` under systemd.

The setup was checked against the Amp manual and Amp CLI `0.0.1785549193-gbb3f33` on 2026-08-01. Amp changes quickly. Check the [Owner's Manual](https://ampcode.com/manual) before changing the runner command or authentication flow.

## Start here

Create a fresh Ubuntu 24.04 Lightsail instance, copy this directory to it, then run:

```bash
chmod +x setup.sh scripts/*.sh tests/test.sh
sudo ./setup.sh bootstrap
sudo amp-runner-setup add
```

`bootstrap` is idempotent. It installs:

- Docker Engine, BuildKit, Buildx, and Compose from Docker's signed apt repository
- Git, Git LFS, GitHub CLI, build-essential, Clang, CMake, Ninja, and common native libraries
- Node.js 24 LTS, the current Go stable release, Rust stable, Python 3.12, and OpenJDK 21
- Browser and headless runtime libraries, Xvfb, ffmpeg, and ImageMagick
- `gum`, `jq`, `ripgrep`, `fzf`, `shellcheck`, tmux, database clients, and standard diagnostics
- unattended security updates, fail2ban, and Docker log rotation

The Node major can be changed with `NODE_MAJOR`; `GO_VERSION` and `RUST_TOOLCHAIN` can pin those runtimes when running `bootstrap`. The default Go and Rust versions are resolved at install time.

Run `sudo amp-runner-setup` later to add another runner or manage existing ones. The plain CLI is available for automation:

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

Delete the source token file after setup. The installed copy is under `/etc/amp-runner/secrets` with mode `0400` and is loaded by systemd as a credential.

## Instance types

| Type | Intended use | Separation | Docker inside runner | Main risk |
| --- | --- | --- | --- | --- |
| `host` | One trusted runner on a dedicated VM | None | Full host daemon access | Amp and repository code act as the VM user. Docker access is equivalent to host root. |
| `docker` | Several independent runners on one VM | Container filesystem, process, per-runner bridge network, home volume, and workspace | Off by default; optional host socket | Containers share the host kernel. Mounting the Docker socket removes the meaningful host boundary. |
| `worktree` | Trusted concurrent work on one repository | Separate Git worktree only | Host access if the account is in `docker` | Every worktree runner uses the same Unix identity and Git object database. It is not a security boundary. |
| `devcontainer` | A project that already defines its toolchain in `devcontainer.json` | Whatever the project configuration provides | Controlled by `devcontainer.json` | Lifecycle commands are trusted code. `privileged`, host mounts, and Docker socket mounts can give host access. |

Use `host` on a VM dedicated to one trusted project. Use `docker` without `--docker-access socket` when runners on the same VM should not read each other's files. Use separate VMs for hostile repositories, separate trust domains, or credentials that must not be reachable by another runner. Linux containers are weaker isolation than a VM.

The generic Docker image has broad development packages preinstalled. The service container drops all capabilities and enables `no-new-privileges`, so its `amp` user cannot elevate with sudo at runtime. Rebuild the image to add OS packages. Docker-based project builds will fail unless you opt into the host socket or configure a separate remote builder.

Dev-container mode uses the project's existing `.devcontainer/devcontainer.json` or `.devcontainer.json`. It mounts a named volume at `/amp-runner-home`, installs Amp there, and reuses it across container rebuilds. The setup tool does not rewrite project configuration or override its security settings.

## Amp authentication and project selection

Interactive authentication runs the supported `amp login` command. On an SSH host it prints a URL for completing sign-in. Token authentication uses the documented `AMP_API_KEY` environment variable. Create an access token in [Amp security settings](https://ampcode.com/settings/security#access-token).

The selection screen is populated by `amp projects list --json`. A selected project's `repositoryURL` is set as the checkout's `origin`. `amp projects status --json` then matches the project by that remote. There is no runner-level project flag. The `--project` CLI option applies to `--orb-execute`, not `amp --no-tui`.

Amp authentication and Git-host authentication are separate. `amp clone namespace/name` handles Amp-hosted repositories. The setup offers `gh auth login` for GitHub repositories. Other private Git hosts need SSH keys, a credential helper, or another Git-supported credential mechanism in the runner identity.

Dev-container interactive setup can prompt for Amp login twice. The host login is needed to list projects before a repository and its `devcontainer.json` exist. The second login is stored in the dev-container home volume and authenticates the runner. GitHub CLI and SSH behavior inside a project dev container depends on that project's configuration; configure those credentials inside `/amp-runner-home` if the runner must push from the container.

Interactive credentials are stored by Amp in the runner's persistent home. Amp currently uses `~/.local/share/amp/secrets.json` on Linux. A container's home is a named Docker volume. Token mode stores the token under `/etc/amp-runner/secrets` and passes it to Amp at process start. Commands launched by Amp can share its process environment, so use a dedicated, revocable token and assume the agent can act with that identity.

Do not put an Amp token, GitHub token, Tailscale reusable key, or SSH private key in Lightsail user data. Cloud-init logs and the instance metadata can retain user data. Complete interactive login over SSH or transfer a short-lived token file, use it, and delete the source file.

## Runner and orb behavior

A self-hosted runner is a persistent Amp CLI process. It is not an Amp orb.

- The service command is `amp --no-tui --runner-id ID`. Runner IDs are stable lowercase DNS labels in this tool.
- `--remote-control-terminal` is opt-in because it grants terminal access to users who can control the thread.
- Threads use the runner's current checkout. They do not receive a fresh clone or fresh machine.
- Amp project, workspace, and personal secrets configured for orbs are not automatically injected into this VM.
- `.agents/setup`, `.agents/resume`, `.amp/services.yaml`, orb portals, orb OIDC, and orb webhooks are orb features. Do not rely on them for runner lifecycle management.
- Project plugins in `.amp/plugins/*.ts` load from the checkout. System plugins under `~/.config/amp/plugins/*.ts` persist in the runner home. Plugins execute trusted code with the same access as Amp.
- OAuth MCP servers can require an interactive callback and persistent token storage. Test each server in the chosen mode. The Amp manual currently calls out an OAuth limitation for orbs, not self-hosted runners.

The agent executes tools without approval by default. Use an Amp policy plugin or permissions configuration for repositories that need command restrictions. A policy running inside the same account is a guardrail, not protection from malicious code that already has host execution.

## Operations

```bash
sudo amp-runner-setup list
sudo amp-runner-setup status build-1
sudo amp-runner-setup logs build-1 --follow
sudo amp-runner-setup doctor
sudo amp-runner-setup update --all
sudo amp-runner-setup remove build-1
sudo amp-runner-setup remove build-1 --purge
```

Each runner has an `amp-runner-ID.service` unit with `Restart=always`, a five-second restart delay, and a 45-second stop timeout. Logs go to journald. `doctor` checks required tools, memory, disk, and every service. Amp has no documented runner readiness endpoint, so these are process checks and do not prove that the runner is registered with Amp's service. Amp's default `amp.updates.mode` is `auto`; `amp-runner-setup update` forces CLI updates, rebuilds the generic container image, and restarts selected services.

`remove` keeps workspaces and Docker home volumes by default. Retained home volumes contain Amp and Git-host credentials. `--purge` deletes them. `uninstall` removes services and this tool but leaves installed OS packages in place.

Persistent paths:

| Path | Contents |
| --- | --- |
| `/opt/amp-runner` | Installed setup tool and generic image source |
| `/etc/amp-runner/instances` | Non-secret instance metadata |
| `/etc/amp-runner/secrets` | Amp access tokens for token-authenticated services |
| `/srv/amp-runners/workspaces` | Default workspaces |
| `/srv/amp-runners/repositories` | Base repositories used by worktree mode |
| Docker volume `amp-runner-ID-home` | Amp, GitHub CLI, plugin, and shell state for container modes |

## Lightsail size and disk

Current public IPv4 Linux bundle prices on 2026-08-01 are listed on the [Lightsail pricing page](https://aws.amazon.com/lightsail/pricing/):

| Workload | Suggested minimum | Current general-purpose bundle |
| --- | --- | --- |
| One host runner, light Node/Python work | 2 vCPU, 4 GB RAM, 80 GB disk | $24/month |
| One runner with browsers, Java, or Docker builds | 2 vCPU, 8 GB RAM, 160 GB disk | $44/month |
| Two to four container runners | 4 vCPU, 16 GB RAM, 320 GB disk | $84/month |
| CPU-heavy builds | 4 vCPU, 8 GB RAM, 320 GB disk | $84/month compute optimized |

The 1 GB and 2 GB plans are too small for the installed image and ordinary agent workloads. Concurrent compiler, browser, and language-server processes can use several gigabytes each. Watch memory, disk, Docker build cache, and inode use. Prefer a larger bundle over swap for sustained builds. A small 2 to 4 GB swap file can absorb short spikes, but severe swap pressure makes the runner unresponsive.

Lightsail instances continue billing while stopped. Snapshots and attached disks have separate charges. The static IPv4 address is free while attached to a running instance and is not required by Amp because the runner opens outbound connections.

## Lightsail networking and SSH

Amp runners need outbound HTTPS, DNS, and WebSocket access. Amp documents these required domains: `ampcode.com`, `auth.ampcode.com`, `production.ampworkers.com`, and `static.ampcode.com`. Git hosts, package registries, model-provider integrations, MCP servers, and Tailscale need their own outbound access.

No inbound port is needed by Amp. For the Lightsail firewall:

1. Remove the default public HTTP rule unless another service needs it.
2. Restrict TCP 22 to your current public IP or VPN CIDR. Lightsail creates independent IPv4 and IPv6 firewalls, so change both.
3. Do not expose Docker port 2375, databases, development servers, or headless browser debugging ports.
4. If Tailscale SSH is working, remove public SSH from both Lightsail firewalls. Keep the Lightsail browser console available as a recovery path.

The optional bootstrap SSH hardening disables password login, keyboard-interactive login, root login, and X11 forwarding. It refuses to run unless the admin account has an `authorized_keys` file. Open a second key-authenticated SSH session before enabling it. The script leaves TCP forwarding enabled because developers commonly use SSH tunnels.

Tailscale installation follows its signed Ubuntu repository. Run `sudo tailscale up`, or select the option during interactive bootstrap. Tailscale recommends disabling key expiry only for trusted servers, with prompt revocation after loss or compromise.

## Cloud-init

[`cloud-init.yaml`](cloud-init.yaml) prepares a fresh instance without embedding credentials. Replace its repository URL and path before pasting it into Lightsail's launch script field. It runs the non-interactive host bootstrap, then leaves Amp and Tailscale authentication for the first SSH session:

```bash
sudo amp-runner-setup add
sudo tailscale up  # when Tailscale was requested
```

Cloud-init can take 10 to 25 minutes because it installs native toolchains and builds the runner image. Inspect it with:

```bash
cloud-init status --wait
sudo journalctl -u cloud-final.service
sudo tail -n 200 /var/log/cloud-init-output.log
```

## Validation

The repository validation does not modify the host:

```bash
./tests/test.sh
```

It checks Bash syntax, runner-ID validation, project selection parsing, help output, required security defaults, and the absence of unsupported runner flags. A full Docker build is intentionally separate because it downloads several gigabytes:

```bash
docker build --pull -t amp-runner:test .
docker run --rm amp-runner:test amp --version
```

Primary references:

- [Amp Owner's Manual](https://ampcode.com/manual), including Runners, Projects, CLI, Configuration, and Plugins
- [Amp Orbs manual](https://ampcode.com/manual/orbs)
- [Amp security reference](https://ampcode.com/security)
- [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker daemon attack surface](https://docs.docker.com/engine/security/)
- [Dev Container CLI](https://github.com/devcontainers/cli)
- [GitHub CLI Linux installation](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)
- [Tailscale Linux installation](https://tailscale.com/docs/install/linux)
- [Lightsail firewall rules](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-firewall-and-port-mappings-in-amazon-lightsail.html)
