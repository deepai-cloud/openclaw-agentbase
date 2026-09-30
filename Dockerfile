FROM python:3.12-slim AS ca-bundle

FROM ubuntu:24.04

# Bootstrap TLS before apt installs ca-certificates into the final image.
COPY --from=ca-bundle /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

ARG YQ_VERSION=v4.53.3
ARG ARGOCD_VERSION=v3.4.3
ARG UV_VERSION=0.11.21
ARG AGE_VERSION=v1.3.1
ARG OPENCLAW_VERSION=2026.6.6
ARG CODEX_VERSION=0.144.6
ARG CLAUDE_CODE_VERSION=2.1.205
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System packages. Use HTTPS mirrors for networks that block plain HTTP.
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dnsutils \
        git \
        gnupg \
        iputils-ping \
        jq \
        make \
        netcat-openbsd \
        openssh-client \
        openssl \
        python3 \
        python3-pip \
        python3-venv \
        tini \
        tree \
        unzip \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Standalone tools: yq, Argo CD, and age.
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" -o /usr/local/bin/yq \
    && curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${arch}" -o /usr/local/bin/argocd \
    && chmod +x /usr/local/bin/yq /usr/local/bin/argocd \
    && curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${arch}.tar.gz" \
        | tar -xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen

# GitHub CLI and kubectl.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
        | gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg \
    && chmod 644 /usr/share/keyrings/githubcli-archive-keyring.gpg /usr/share/keyrings/kubernetes-apt-keyring.gpg \
    && printf 'deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list \
    && printf '%s\n' 'deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
        > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh kubectl \
    && rm -rf /var/lib/apt/lists/*

# Python tooling and document/image readers.
RUN curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh \
    && mv /root/.local/bin/uv /root/.local/bin/uvx /usr/local/bin/ \
    && uv pip install --system --break-system-packages --no-cache \
        "PyYAML>=6,<7" \
        "openpyxl>=3.1,<4" \
        "pypdf>=5,<7" \
        "python-docx>=1.1,<2" \
        "opencv-python-headless>=4.9,<5" \
        "numpy>=1.26,<3"

# Agent CLIs.
RUN npm install -g \
        "openclaw@${OPENCLAW_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# Fail the build if a tool or Python dependency is unavailable.
RUN node --version && npm --version && python3 --version \
    && gh --version && kubectl version --client && argocd version --client \
    && yq --version && jq --version && uv --version && age --version \
    && openclaw --version \
    && test "$(codex --version)" = "codex-cli ${CODEX_VERSION}" \
    && claude --version \
    && python3 -c "import yaml, openpyxl, pypdf, docx, cv2, numpy"

# Reuse Ubuntu's UID 1000 for the non-root runtime user.
RUN usermod -l openclaw -d /home/openclaw -m ubuntu \
    && groupmod -n openclaw ubuntu \
    && install -d -m 700 -o openclaw -g openclaw \
        /home/openclaw/.openclaw \
        /home/openclaw/.openclaw/workspace \
        /home/openclaw/.ssh \
    && chown -R openclaw:openclaw /home/openclaw

ENV HOME=/home/openclaw \
    OPENCLAW_WORKSPACE=/home/openclaw/.openclaw/workspace

USER openclaw
WORKDIR /home/openclaw/.openclaw/workspace

EXPOSE 18789

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -fsS http://127.0.0.1:18789/healthz || exit 1

# Supply gateway configuration at runtime and persist /home/openclaw/.openclaw.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["openclaw", "gateway", "--bind", "lan"]
