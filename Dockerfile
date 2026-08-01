FROM ubuntu:24.04

ARG NODE_MAJOR=24
ARG GO_VERSION=latest
ARG RUST_TOOLCHAIN=stable

COPY scripts/install-packages.sh scripts/install-runtimes.sh /tmp/amp-runner/
RUN /tmp/amp-runner/install-packages.sh container \
	&& NODE_MAJOR="$NODE_MAJOR" GO_VERSION="$GO_VERSION" RUST_TOOLCHAIN="$RUST_TOOLCHAIN" /tmp/amp-runner/install-runtimes.sh \
	&& rm -rf /tmp/amp-runner

RUN userdel -r ubuntu 2>/dev/null || true; \
	groupdel ubuntu 2>/dev/null || true; \
	groupadd --gid 1000 amp \
	&& useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash amp \
	&& printf 'amp ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/amp \
	&& chmod 0440 /etc/sudoers.d/amp

USER amp
RUN curl -fsSL https://ampcode.com/install.sh | bash

USER root
RUN ln -s /home/amp/.amp/bin/amp /usr/local/bin/amp
COPY scripts/entrypoint.sh /usr/local/bin/amp-runner-entrypoint
RUN chmod 0755 /usr/local/bin/amp-runner-entrypoint

ENV PATH="/home/amp/.amp/bin:/opt/node/bin:/usr/local/go/bin:/opt/rust/cargo/bin:${PATH}"
ENV HOME=/home/amp
WORKDIR /workspace
USER amp

ENTRYPOINT ["/usr/local/bin/amp-runner-entrypoint"]
CMD ["amp", "--help"]
