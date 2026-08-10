# =============================================================================
# Claude Code Sandbox + Antigravity CLI (agy)
# =============================================================================
# Extends the official Docker Claude Code sandbox template with the Google
# Antigravity CLI so that Claude can invoke `agy` for tasks like web search,
# file mapping, and other agentic workflows.
# =============================================================================
FROM docker/sandbox-templates:claude-code

# ---------------------------------------------------------------------------
# Install Antigravity CLI
# ---------------------------------------------------------------------------
# The official installer drops the binary into ~/.local/bin which is already
# on PATH in the base image.  We run it as the default non-root user so the
# binary lands in the right home directory.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash

# ---------------------------------------------------------------------------
# Install CodeGraph
# ---------------------------------------------------------------------------
RUN curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/v1.5.0/install.sh | sh
RUN codegraph install --yes
COPY --chown=1000:1000 scripts/codegraph-setup /home/agent/.local/bin/codegraph-setup
RUN chmod +x /home/agent/.local/bin/codegraph-setup

# ---------------------------------------------------------------------------
# Workspace trust helper for agy
# ---------------------------------------------------------------------------
# agy matches trustedWorkspaces entries as literal absolute paths (no glob
# support), so the workspace path must be added at runtime once it is known.
# The login banner hook below calls this for the shell's starting directory.
# ---------------------------------------------------------------------------
COPY scripts/agy-trust-workspace /usr/local/bin/agy-trust-workspace
RUN sudo chmod +x /usr/local/bin/agy-trust-workspace

# ---------------------------------------------------------------------------
# Install glab (GitLab CLI) — always fetches the latest release (.deb)
# ---------------------------------------------------------------------------
# Uses the GitLab releases permalink / API to discover the newest version,
# then installs the official .deb package for the build architecture.
# ---------------------------------------------------------------------------
RUN set -eux; \
    ARCH=$(dpkg --print-architecture); \
    GLAB_VERSION=$(curl -sI "https://gitlab.com/gitlab-org/cli/-/releases/permalink/latest" | grep -i "^location:" | sed -E 's/.*\/v([0-9.]+)/\1/' | tr -d '\r' || true); \
    if [ -z "${GLAB_VERSION}" ]; then \
      GLAB_VERSION=$(curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest" | grep -o '"tag_name":"v[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//' || true); \
    fi; \
    if [ -z "${GLAB_VERSION}" ]; then \
      GLAB_VERSION=$(curl -fsSL "https://gitlab.com/api/v4/projects/34675721/releases?per_page=1" | grep -o '"tag_name":"v[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//'); \
    fi; \
    echo "Installing glab ${GLAB_VERSION} for ${ARCH}"; \
    curl -fsSL "https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/packages/generic/glab/${GLAB_VERSION}/glab_${GLAB_VERSION}_linux_${ARCH}.deb" -o /tmp/glab.deb \
      || curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.deb" -o /tmp/glab.deb; \
    sudo dpkg -i /tmp/glab.deb; \
    rm -f /tmp/glab.deb; \
    glab --version

# ---------------------------------------------------------------------------
# Install Buildah — container image builder (works inside sandboxes)
# ---------------------------------------------------------------------------
# The sandbox lacks SYS_ADMIN capability and overlay kernel support, so we
# pre-configure buildah to use the vfs storage driver and chroot isolation.
# This avoids the need for a running Docker daemon to build OCI images.
# ---------------------------------------------------------------------------
RUN sudo apt-get update -qq \
 && sudo apt-get install -y --no-install-recommends buildah \
 && sudo rm -rf /var/lib/apt/lists/*

# Root storage config (for sudo buildah)
RUN sudo mkdir -p /etc/containers \
 && printf '[storage]\ndriver = "vfs"\n' | sudo tee /etc/containers/storage.conf

# Agent (rootless) storage config
RUN mkdir -p ~/.config/containers \
 && printf '[storage]\ndriver = "vfs"\n\n[storage.options]\nignore_chown_errors = "true"\n' \
      > ~/.config/containers/storage.conf \
 && printf 'unqualified-search-registries = ["docker.io"]\n' \
      > ~/.config/containers/registries.conf

# ---------------------------------------------------------------------------
# Verify the installation
# ---------------------------------------------------------------------------
RUN agy --version
RUN buildah --version

ENV TERM=xterm-256color
ENV COLORTERM=truecolor

# ---------------------------------------------------------------------------
# Pre-create skill & config directories for agy (Google Antigravity CLI)
# ---------------------------------------------------------------------------
RUN mkdir -p /home/agent/.gemini/config/rules \
             /home/agent/.gemini/config/skills \
             /home/agent/.gemini/antigravity/settings \
             /home/agent/.gemini/antigravity/conversations \
             /home/agent/.gemini/antigravity-cli/settings \
             /home/agent/.gemini/antigravity-cli/builtin/skills \
             /home/agent/.gemini/antigravity-cli/cache \
             /home/agent/.config/antigravity

RUN sudo mkdir -p /root/.gemini/config/rules \
                  /root/.gemini/config/skills \
                  /root/.gemini/antigravity/settings \
                  /root/.gemini/antigravity/conversations \
                  /root/.gemini/antigravity-cli/settings \
                  /root/.gemini/antigravity-cli/builtin/skills \
                  /root/.gemini/antigravity-cli/cache \
                  /root/.config/antigravity

# ---------------------------------------------------------------------------
# Seed GEMINI.md, settings, onboarding, terms, and skills exclusively for agy
# ---------------------------------------------------------------------------
COPY --chown=1000:1000 config/agy/GEMINI.md /home/agent/.gemini/config/GEMINI.md
COPY --chown=1000:1000 config/agy/config.json /home/agent/.gemini/config/config.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.gemini/settings.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.gemini/config/settings.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.gemini/antigravity/settings.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.gemini/antigravity/settings/settings.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.gemini/antigravity-cli/settings.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.gemini/antigravity-cli/settings/settings.json
COPY --chown=1000:1000 config/agy/settings.json /home/agent/.config/antigravity/settings.json
COPY --chown=1000:1000 config/agy/onboarding.json /home/agent/.gemini/antigravity-cli/onboarding.json
COPY --chown=1000:1000 config/agy/cache-onboarding.json /home/agent/.gemini/antigravity-cli/cache/onboarding.json
COPY --chown=1000:1000 config/agy/terms.json /home/agent/.gemini/antigravity-cli/terms.json
COPY --chown=1000:1000 config/agy/skills/ /home/agent/.gemini/config/skills/
COPY --chown=1000:1000 config/agy/skills/ /home/agent/.gemini/antigravity-cli/builtin/skills/

COPY config/agy/GEMINI.md /root/.gemini/config/GEMINI.md
COPY config/agy/config.json /root/.gemini/config/config.json
COPY config/agy/settings.json /root/.gemini/settings.json
COPY config/agy/settings.json /root/.gemini/config/settings.json
COPY config/agy/settings.json /root/.gemini/antigravity/settings.json
COPY config/agy/settings.json /root/.gemini/antigravity/settings/settings.json
COPY config/agy/settings.json /root/.gemini/antigravity-cli/settings.json
COPY config/agy/settings.json /root/.gemini/antigravity-cli/settings/settings.json
COPY config/agy/settings.json /root/.config/antigravity/settings.json
COPY config/agy/onboarding.json /root/.gemini/antigravity-cli/onboarding.json
COPY config/agy/cache-onboarding.json /root/.gemini/antigravity-cli/cache/onboarding.json
COPY config/agy/terms.json /root/.gemini/antigravity-cli/terms.json
COPY config/agy/skills/ /root/.gemini/config/skills/
COPY config/agy/skills/ /root/.gemini/antigravity-cli/builtin/skills/

# ---------------------------------------------------------------------------
# Display setup instructions on interactive terminal logon and docker exec
# ---------------------------------------------------------------------------
RUN sudo mkdir -p /etc/profile.d \
 && printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Display setup instructions for interactive shells' \
    'if [ -z "${_BANNER_SHOWN:-}" ]; then' \
    '  if [ -t 0 ] || [ -t 1 ] || [ -n "${PS1:-}" ] || [ -n "${SSH_TTY:-}" ]; then' \
    '    export _BANNER_SHOWN=1' \
    '    command -v agy-trust-workspace >/dev/null 2>&1 && agy-trust-workspace >/dev/null 2>&1' \
    '    echo ""' \
    '    echo "================================================================="' \
    '    echo " First Login Setup Instructions:"' \
    '    echo "   1. Run '\''agy login'\''"' \
    '    echo "   2. Run '\''codegraph-setup'\''"' \
    '    echo "================================================================="' \
    '    echo ""' \
    '  fi' \
    'fi' | sudo tee /etc/profile.d/banner.sh > /dev/null \
 && sudo chmod +x /etc/profile.d/banner.sh \
 && sudo bash -c "sed -i '1i [ -f /etc/profile.d/banner.sh ] && . /etc/profile.d/banner.sh' /etc/bash.bashrc" \
 && sudo bash -c "sed -i '1i [ -f /etc/profile.d/banner.sh ] && . /etc/profile.d/banner.sh' /etc/profile" \
 && touch /home/agent/.bashrc /home/agent/.profile \
 && sed -i '1i [ -f /etc/profile.d/banner.sh ] && . /etc/profile.d/banner.sh' /home/agent/.bashrc \
 && sed -i '1i [ -f /etc/profile.d/banner.sh ] && . /etc/profile.d/banner.sh' /home/agent/.profile \
 && sudo bash -c "touch /root/.bashrc /root/.profile" \
 && sudo bash -c "sed -i '1i [ -f /etc/profile.d/banner.sh ] && . /etc/profile.d/banner.sh' /root/.bashrc" \
 && sudo bash -c "sed -i '1i [ -f /etc/profile.d/banner.sh ] && . /etc/profile.d/banner.sh' /root/.profile"


# Default working directory (matches the base image convention)
WORKDIR /home/agent



