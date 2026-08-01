FROM ubuntu:24.04

ARG NODE_MAJOR=24
ARG GO_VERSION=latest
ARG RUST_TOOLCHAIN=stable
ARG CODEX_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest

COPY scripts/install-packages.sh scripts/install-runtimes.sh /tmp/amp-runner/
RUN /tmp/amp-runner/install-packages.sh container \
	&& NODE_MAJOR="$NODE_MAJOR" GO_VERSION="$GO_VERSION" RUST_TOOLCHAIN="$RUST_TOOLCHAIN" /tmp/amp-runner/install-runtimes.sh \
	&& rm -rf /tmp/amp-runner

RUN userdel -r ubuntu 2>/dev/null || true; \
	groupdel ubuntu 2>/dev/null || true; \
	groupadd --gid 1000 amp \
	&& useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash amp \
	&& install -d -o amp -g amp /agent-home

USER amp
RUN HOME=/agent-home CODEX_HOME=/agent-home/.codex CODEX_INSTALL_DIR=/agent-home/.local/bin CODEX_NON_INTERACTIVE=true \
		sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh -s -- --release "$1"' _ "$CODEX_VERSION" \
	&& HOME=/agent-home sh -c 'curl -fsSL https://claude.ai/install.sh | bash -s "$1"' _ "$CLAUDE_CODE_VERSION" \
	&& curl -fsSL https://ampcode.com/install.sh | bash

USER root
COPY scripts/agent-cli-launcher /usr/local/libexec/agent-cli-launcher
RUN chmod 0755 /usr/local/libexec/agent-cli-launcher \
	&& chmod u+s /usr/bin/bwrap \
	&& ln -s /usr/local/libexec/agent-cli-launcher /usr/local/bin/codex \
	&& ln -s /usr/local/libexec/agent-cli-launcher /usr/local/bin/claude \
	&& ln -s /home/amp/.amp/bin/amp /usr/local/bin/amp
COPY scripts/entrypoint.sh /usr/local/bin/amp-runner-entrypoint
RUN chmod 0755 /usr/local/bin/amp-runner-entrypoint

ENV PATH="/home/amp/.amp/bin:/opt/node/bin:/usr/local/go/bin:/opt/rust/cargo/bin:${PATH}"
ENV HOME=/home/amp
WORKDIR /workspace
USER amp

ENTRYPOINT ["/usr/local/bin/amp-runner-entrypoint"]
CMD ["amp", "--help"]
