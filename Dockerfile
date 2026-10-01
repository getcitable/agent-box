# Agent box — generic infrastructure for running a Raft Computer with Claude Code
# on a Maritime micro-VM.
#
# Deliberately contains NO business content: no skills, no instructions, no brand
# data, no credentials. Those live on the runtime volume at /data and are pushed
# separately. This image is just the plumbing, which is why it can be public
# while everything that matters stays private.
FROM node:22-bookworm-slim

# The Raft installer needs curl, sha256sum, mktemp, uname and awk.
# procps gives a working `ps`; git is needed for most real agent work.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git mawk procps tar xz-utils \
    && rm -rf /var/lib/apt/lists/*

# --- unprivileged user -------------------------------------------------------
# MANDATORY, not hygiene: Raft launches Claude Code with
# --dangerously-skip-permissions, which Claude Code refuses to run as root
# ("cannot be used with root/sudo privileges", exit 1). uid 1000 is pinned
# because /data ownership is created against it and /data outlives the image.
RUN useradd -u 1000 -m -d /home/agent -s /bin/sh agent

# --- Claude Code -------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code \
    && mv "$(command -v claude)" /usr/local/bin/claude-real

# Wrapper forcing HOME onto the persistent volume. Raft resolves `claude` from
# PATH; the real binary would otherwise look in the container's HOME (/) and
# report "Not logged in". AGENT_HOME is substituted at boot by the entrypoint.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'export HOME=${AGENT_HOME:-/data/agent}' \
    'exec /usr/local/bin/claude-real "$@"' \
    > /usr/local/bin/claude \
    && chmod 0755 /usr/local/bin/claude

# --- Raft Computer -----------------------------------------------------------
# Installed with HOME=/opt/raft so the binary lands in the image; its runtime
# state goes under the volume instead (SLOCK_HOME follows HOME).
RUN HOME=/opt/raft sh -c 'curl -fsSL https://cdn.raft.build/computer/install.sh | sh' \
    && ln -s /opt/raft/.local/bin/raft-computer /usr/local/bin/raft-computer \
    && chmod -R a+rX /opt/raft

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Set per agent with `maritime env set <agent> ... --reload`:
#   AGENT_HOME   where state lives on the volume      (default /data/agent)
#   RAFT_SERVER  workspace slug, e.g. /my-workspace
#   NOTIFY_CMD   optional: a long-lived poller the supervisor keeps alive
#   MONITOR_CMD  optional: a command the supervisor runs on MONITOR_EVERY_H
ENV AGENT_HOME=/data/agent \
    RAFT_SERVER="" \
    NOTIFY_CMD="" \
    MONITOR_CMD="" \
    MONITOR_EVERY_H=24

# Deliberately NOT setting ENV HOME: injecting HOME into a Maritime container
# breaks `maritime exec` with a 502. The wrapper and entrypoint set it per
# process instead.

CMD ["/usr/local/bin/entrypoint.sh"]
