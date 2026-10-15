# syntax=docker/dockerfile:1
ARG BASE_IMAGE=docker.io/library/node:24-slim
ARG TRUST_STAGE=base
FROM ${BASE_IMAGE} AS base

FROM base AS custom-ca
COPY ca-certificates/ /usr/local/share/ca-certificates/agent-sandbox/
# Node may use bundled roots; add the updated system bundle without replacing them.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt

FROM ${TRUST_STAGE} AS common

ARG AGENT_UID=1000
ARG AGENT_GID=1000
ARG EXTRA_PACKAGES=""
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git ripgrep fd-find jq ${EXTRA_PACKAGES} \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && if getent passwd node >/dev/null; then userdel --remove node; fi \
 && groupadd --gid "${AGENT_GID}" agent \
 && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" --create-home --shell /bin/bash agent \
 && mkdir -p /home/agent/src /home/agent/.agent-state \
 && chown -R agent:agent /home/agent
ENV PATH="/home/agent/.local/bin:${PATH}"
USER agent
WORKDIR /home/agent/src
RUN git config --global user.name "Agent Sandbox" \
 && git config --global user.email "agent@no-mail.com" \
 && git config --global pull.rebase true \
 && git config --global rebase.autoStash true \
 && git config --global branch.master.rebase false \
 && git config --global branch.master.mergeoptions --ff-only \
 && git config --global branch.main.rebase false \
 && git config --global branch.main.mergeoptions --ff-only

FROM common AS codex
ARG AGENT_VERSION=latest
USER root
RUN npm install -g "@openai/codex@${AGENT_VERSION}"
USER agent
ENV CODEX_HOME=/home/agent/.agent-state CODEX_DISABLE_UPDATE_CHECK=1
CMD ["codex", "--sandbox", "danger-full-access", "--ask-for-approval", "never"]

FROM common AS claude
ARG AGENT_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${AGENT_VERSION}"
ENV CLAUDE_CONFIG_DIR=/home/agent/.agent-state DISABLE_AUTOUPDATER=1
CMD ["claude", "--dangerously-skip-permissions"]

FROM common AS pi
ARG AGENT_VERSION=latest
USER root
RUN npm install -g "@earendil-works/pi-coding-agent@${AGENT_VERSION}"
USER agent
ENV PI_CODING_AGENT_DIR=/home/agent/.agent-state PI_SKIP_UPDATE_CHECK=1
CMD ["pi", "--yolo"]
