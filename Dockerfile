# syntax=docker/dockerfile:1
ARG UV_VERSION=0.11.21
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-binaries
FROM python:3.12-slim AS ca-bundle
FROM ubuntu:24.04
ARG YQ_VERSION=v4.53.3
ARG ARGOCD_VERSION=v3.4.3
ARG AGE_VERSION=v1.3.1
ARG OPENCLAW_VERSION=2026.6.6
ARG CODEX_VERSION=0.144.6
ARG CLAUDE_CODE_VERSION=2.1.205
# Override to match your Kubernetes API servers (within one minor version).
ARG KUBECTL_VERSION=v1.36.5
ARG NODE_MAJOR=22
ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]
# Bootstrap HTTPS before installing Ubuntu's own CA package.
COPY --from=ca-bundle /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=uv-binaries /uv /uvx /usr/local/bin/
# Build tools, diagnostics, document readers, OCR, and media utilities.
RUN sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git gnupg openssh-client openssl \
        build-essential cmake pkg-config python3 python3-dev python3-venv \
        dnsutils iputils-ping iproute2 netcat-openbsd hostname \
        jq ripgrep fd-find procps lsof file tree less \
        rsync patch zip unzip xz-utils sqlite3 tini \
        poppler-utils tesseract-ocr tesseract-ocr-eng ffmpeg \
        fonts-liberation fonts-noto-color-emoji xvfb xauth \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*
# Signed NodeSource and GitHub CLI repositories.
RUN curl -fsSL --retry 3 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --batch --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && curl -fsSL --retry 3 https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod 644 /usr/share/keyrings/nodesource.gpg \
        /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && printf 'deb [arch=%s signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' \
        "$(dpkg --print-architecture)" "$NODE_MAJOR" \
        > /etc/apt/sources.list.d/nodesource.list \
    && printf 'deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs gh \
    && rm -rf /var/lib/apt/lists/*
# Standalone tools. This image targets linux/amd64 and linux/arm64.
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in amd64|arm64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac \
    && curl -fsSL --retry 3 \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" \
        -o /usr/local/bin/yq \
    && curl -fsSL --retry 3 \
        "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${arch}" \
        -o /usr/local/bin/argocd \
    && curl -fsSL --retry 3 \
        "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${arch}.tar.gz" \
        -o /tmp/age.tar.gz \
    && tar -xzf /tmp/age.tar.gz -C /usr/local/bin --strip-components=1 age/age age/age-keygen \
    && chmod 755 /usr/local/bin/yq /usr/local/bin/argocd \
        /usr/local/bin/age /usr/local/bin/age-keygen \
    && rm /tmp/age.tar.gz
# Pinned kubectl with upstream SHA-256 verification.
RUN arch="$(dpkg --print-architecture)" \
    && base="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}" \
    && curl -fsSL --retry 3 "$base/kubectl" -o /tmp/kubectl \
    && curl -fsSL --retry 3 "$base/kubectl.sha256" -o /tmp/kubectl.sha256 \
    && printf '%s  /tmp/kubectl\n' "$(cat /tmp/kubectl.sha256)" | sha256sum -c - \
    && install -m 755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm /tmp/kubectl /tmp/kubectl.sha256
# Root-owned baseline Python environment; do not modify distro Python.
# Runtime additions belong in project environments: uv venv && uv pip install ...
RUN uv venv --no-cache --seed --python /usr/bin/python3 /opt/agent-venv \
    && uv pip install --no-cache --python /opt/agent-venv/bin/python \
        "PyYAML>=6,<7" \
        "openpyxl>=3.1,<4" \
        "pypdf>=5,<7" \
        "python-docx>=1.1,<2" \
        "python-pptx>=1,<2" \
        "Pillow>=10,<13" \
        "opencv-python-headless>=4.9,<5" \
        "numpy>=1.26,<3" \
        "pandas>=2.2,<4" \
        "requests>=2.32,<3" \
        "httpx>=0.27,<1" \
        "beautifulsoup4>=4.12,<5" \
        "lxml>=5,<7"
# Install bundled CLIs in a fixed, root-owned location.
RUN npm install --global --prefix /usr/local \
        "openclaw@${OPENCLAW_VERSION}" \
        "@openai/codex@${CODEX_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force
# Keep browser binaries OUTSIDE HOME so persistent home volumes cannot hide them.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
# Use OpenClaw's own Playwright version, not an independently chosen latest version.
RUN node /usr/local/lib/node_modules/openclaw/node_modules/playwright-core/cli.js \
        install --with-deps chromium \
    && browser="$(node -e 'console.log(require("/usr/local/lib/node_modules/openclaw/node_modules/playwright-core").chromium.executablePath())')" \
    && test -x "$browser" \
    && ln -s "$browser" /usr/local/bin/chromium \
    && printf '#!/bin/sh\nexec node /usr/local/lib/node_modules/openclaw/node_modules/playwright-core/cli.js "$@"\n' \
        > /usr/local/bin/playwright \
    && chmod 755 /usr/local/bin/playwright \
    && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH" \
    && rm -rf /var/lib/apt/lists/* /root/.cache /root/.npm
# Reuse Ubuntu's UID/GID 1000.
RUN usermod -l openclaw -d /home/openclaw -m -s /bin/bash ubuntu \
    && groupmod -n openclaw ubuntu \
    && install -d -m 700 -o openclaw -g openclaw \
        /home/openclaw/.openclaw \
        /home/openclaw/.openclaw/workspace \
        /home/openclaw/.local/bin \
