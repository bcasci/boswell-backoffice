FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install system packages
RUN apt-get update && apt-get install -y \
    git \
    tmux \
    zsh \
    curl \
    wget \
    openssh-server \
    sudo \
    build-essential \
    ca-certificates \
    gnupg \
    # Additional utilities
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install global npm packages
RUN npm install -g n8n @anthropic-ai/claude-code

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

# AI Maestro will be installed at runtime to /data/ai-maestro to keep image small
# This avoids the 8GB uncompressed image limit on Fly.io

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

# Create data directories
RUN mkdir -p /data/n8n /data/ai-maestro /data/repos /data/worktrees \
    && chown -R agent:agent /data

# Switch to agent user
USER agent
WORKDIR /home/agent

# Symlink n8n data directory
RUN ln -s /data/n8n /home/agent/.n8n

# Copy entrypoint script
COPY --chown=agent:agent entrypoint.sh /home/agent/entrypoint.sh
RUN chmod +x /home/agent/entrypoint.sh

# Switch back to root for entrypoint (needs to start services)
USER root

EXPOSE 5678 22

ENTRYPOINT ["/home/agent/entrypoint.sh"]
