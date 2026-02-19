FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install system packages (python3 needed for native module compilation)
RUN apt-get update && apt-get install -y \
    git \
    tmux \
    zsh \
    curl \
    wget \
    openssh-server \
    sudo \
    build-essential \
    python3 \
    ca-certificates \
    gnupg \
    jq \
    unzip \
    # Ruby build dependencies (for compiling Ruby via asdf)
    libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev \
    libgdbm-dev libncurses5-dev autoconf bison libsqlite3-dev \
    # Rails app runtime dependencies
    libvips-dev libjemalloc2 pkg-config libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Version manifest — single source of truth for pinned dependencies
COPY versions.json /tmp/versions.json

# Install global npm packages (versions read from versions.json)
RUN CLAUDE_CODE_VERSION=$(jq -r '.["claude-code"]' /tmp/versions.json) \
    && N8N_VERSION=$(jq -r '.n8n' /tmp/versions.json) \
    && echo "Installing claude-code@${CLAUDE_CODE_VERSION}, n8n@${N8N_VERSION}" \
    && npm install -g \
        "n8n@${N8N_VERSION}" \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        yarn

# Install GitHub CLI
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install cloudflared
RUN wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
    && dpkg -i cloudflared-linux-amd64.deb \
    && rm cloudflared-linux-amd64.deb

# Install Caddy (auth reverse proxy for AI Maestro dashboard)
RUN apt-get update \
    && apt-get install -y debian-keyring debian-archive-keyring apt-transport-https \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update \
    && apt-get install -y caddy \
    && rm -rf /var/lib/apt/lists/*

# Install oauth2-proxy (for GitHub OAuth, used when GITHUB_OAUTH_CLIENT_ID is set)
RUN wget -q https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v7.7.1/oauth2-proxy-v7.7.1.linux-amd64.tar.gz \
    && tar xzf oauth2-proxy-v7.7.1.linux-amd64.tar.gz \
    && mv oauth2-proxy-v7.7.1.linux-amd64/oauth2-proxy /usr/local/bin/ \
    && rm -rf oauth2-proxy-*

# Clone and build AI Maestro (baked into image to avoid runtime network timeouts)
# Note: touch .help-build-success so the prebuild help-index step can fail gracefully
# (it requires CUDA/GPU for ONNX runtime which isn't available in the Docker builder)
# Post-build cleanup removes ~1GB of unnecessary files to stay under Fly.io 8GB rootfs limit
RUN git clone --depth 1 https://github.com/23blocks-OS/ai-maestro.git /opt/ai-maestro \
    && cd /opt/ai-maestro \
    && yarn install --network-timeout 300000 \
    && mkdir -p data && touch data/.help-build-success \
    && yarn build \
    # --- Post-build size reduction ---
    # Remove ONNX runtime native binaries (~700MB) - unusable without CUDA GPU
    && rm -rf node_modules/onnxruntime-node/bin \
    # Remove dev dependencies from node_modules
    && npm prune --production 2>/dev/null || true \
    # Remove build caches and unnecessary files
    && rm -rf .next/cache .next/types node_modules/.cache \
    && rm -rf .git tests .github infrastructure docs \
    && yarn cache clean 2>/dev/null || true \
    && rm -rf /tmp/* /root/.npm /root/.cache

# Install asdf version manager (plugins + installs live on /data/asdf persistent volume)
RUN git clone --depth 1 https://github.com/asdf-vm/asdf.git /opt/asdf --branch v0.16.7

# Create agent user with passwordless sudo
RUN useradd -m -s /bin/zsh -G sudo agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Configure SSH for agent user
RUN mkdir -p /home/agent/.ssh \
    && echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCwD9aC7Dwq3vZ6GZivD2YWW+HgLybuF7wnz8Pojgz8llyxO+rTJ+hpvMVe/ZsmYnSXEao/Jmfrta4xJagU0QlP1HpZav/a40Nt50V7cal+oynygM5UYkhA7XlgsHypj3uXdpxZ9JyNtiNuf3AG/rzylyHd2vm7gVQCDwY6zgw0FnxC4Y4Mb/S8Hq47SYmzm4twcVy/Yb8YtUoQhd//BlEVOROTkAHBP8VEYND5zSMjmsUFTdkT1RnCBNhU9JC2Kfp82skvzT0bF6GRjY5Vqchi9VEfYwtPlWNFxX1zXLsHkgAax8rcYfoX02H58SwYMwYURYMjag0uD21p/MsKDju5 brandon.casci@gmail.com" > /home/agent/.ssh/authorized_keys \
    && chmod 700 /home/agent/.ssh \
    && chmod 600 /home/agent/.ssh/authorized_keys \
    && chown -R agent:agent /home/agent/.ssh

# Configure SSH server
RUN mkdir -p /run/sshd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Create data directories (persistent volume mounted at /data)
RUN mkdir -p /data/n8n /data/ai-maestro /data/repos /data/worktrees /data/asdf \
    && chown -R agent:agent /data \
    && chown -R agent:agent /opt/ai-maestro \
    && chown -R agent:agent /opt/asdf

# Switch to agent user
USER agent
WORKDIR /home/agent

# Symlink n8n data directory
RUN ln -s /data/n8n /home/agent/.n8n

# Copy scripts, workflows, and entrypoint
COPY --chown=agent:agent scripts/build-faq.sh /opt/scripts/build-faq.sh
RUN chmod +x /opt/scripts/build-faq.sh
COPY --chown=agent:agent workflows/ /opt/workflows/
COPY --chown=agent:agent entrypoint.sh /home/agent/entrypoint.sh
RUN chmod +x /home/agent/entrypoint.sh

# Switch back to root for entrypoint (needs to start services)
USER root

EXPOSE 5678 23000 22

ENTRYPOINT ["/home/agent/entrypoint.sh"]
