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
# node:22 already ships a `node` user at uid 1000, so a plain `useradd -u 1000`
# fails with "UID 1000 is not unique" and the build exits 1. Remove it first:
# we need uid 1000 itself, not merely some unprivileged user.
RUN userdel -r node 2>/dev/null || true; \
    useradd -u 1000 -m -d /home/agent -s /bin/sh agent

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

# Box-wide deny rules (CIT-1572). A login-mode box uses a claude.ai login, so it
# loads every claude.ai connector on that account. The account's Citable
# connector is not limited to one brand and has write tools (publish, schedule,
# paid ads). Raft runs agents with --dangerously-skip-permissions, so a deny rule
# is the guard. A deny rule here applies to every agent on the box, and user or
# project settings cannot remove it. It is root-owned, so the agent user cannot
# edit it. The brand-locked MCP from entrypoint.sh is mcp__citable__ and stays.
COPY managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod 0644 /etc/claude-code/managed-settings.json

# --- Raft Computer -----------------------------------------------------------
# Installed with HOME=/opt/raft so the binary lands in the image; its runtime
# state goes under the volume instead (SLOCK_HOME follows HOME).
RUN HOME=/opt/raft sh -c 'curl -fsSL https://cdn.raft.build/computer/install.sh | sh' \
    && chmod -R a+rX /opt/raft

# Wrapper that drops to the agent user instead of a symlink. The Maritime
# console logs in as root, so the natural thing to type runs as root — and
# every way that fails points somewhere else:
#
#   * the daemon spawns `claude --dangerously-skip-permissions`, which refuses
#     under root, so the agent dies with "exit code 1" and a message about
#     permissions that has nothing to do with the task;
#   * a root daemon keeps running beside the agent's own and wins the launch
#     race, so killing and restarting the right one changes nothing;
#   * root-owned files appear under .slock and the agent user can no longer
#     read its own state, surfacing later as EACCES on a file nobody edited.
#
# All three survive a reboot. This cost two debugging sessions on two boxes, so
# the fix belongs in the image rather than in anyone's memory.
#
# A fourth failure, found 2026-10-11: the non-root branch below used to read
# 'export HOME=${HOME:-$AGENT_HOME_DIR}', which only falls back to AGENT_HOME
# when HOME is *unset*. Run as the agent user, HOME is already /home/agent from
# /etc/passwd, so AGENT_HOME was ignored and raft-computer resolved SLOCK_HOME
# to /home/agent/.slock. On citable-studio-box that made `raft-computer status`
# report "Service: stopped / Logged in: no / Attachments: none" while the daemon
# was running, all four agents were active and messages were flowing — three
# false alarms at once, on the box whose whole job is telling you the truth
# about itself. AGENT_HOME is explicit configuration and must beat the passwd
# home, so it is assigned unconditionally.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'REAL=/opt/raft/.local/bin/raft-computer' \
    'AGENT_HOME_DIR=${AGENT_HOME:-/data/agent}' \
    'if [ "$(id -u)" = "0" ]; then' \
    '    echo "raft-computer: running as the agent user, not root." >&2' \
    '    exec su agent -s /bin/sh -c "HOME=$AGENT_HOME_DIR $REAL $*"' \
    'fi' \
    'export HOME=$AGENT_HOME_DIR' \
    'exec "$REAL" "$@"' \
    > /usr/local/bin/raft-computer \
    && chmod 0755 /usr/local/bin/raft-computer

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY box-auth.sh /usr/local/lib/box-auth.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh && chmod 0644 /usr/local/lib/box-auth.sh

# Set per agent with `maritime env set <agent> ... --reload`:
#   AGENT_HOME   where state lives on the volume      (default /data/agent)
#   RAFT_SERVER  workspace slug, e.g. /my-workspace
#   NOTIFY_CMD   optional: a long-lived poller the supervisor keeps alive
#   MONITOR_CMD  optional: a command the supervisor runs on MONITOR_EVERY_H
#   AUTH_MODE    login (default: our boxes) or api_key (client boxes, CIT-1496)
#   ANTHROPIC_API_KEY  api_key mode only: from the client's capped Console workspace
ENV AGENT_HOME=/data/agent \
    RAFT_SERVER="" \
    NOTIFY_CMD="" \
    MONITOR_CMD="" \
    MONITOR_EVERY_H=24

# Deliberately NOT setting ENV HOME: injecting HOME into a Maritime container
# breaks `maritime exec` with a 502. The wrapper and entrypoint set it per
# process instead.

CMD ["/usr/local/bin/entrypoint.sh"]
