#!/bin/sh
# PID 1 for the agent box.
#
# This is the piece that `maritime exec` cannot provide: a process the container
# itself owns, so it survives when an exec session ends. Anything that must run
# on a schedule has to be started from here.
#
#   1. prepare the runtime volume (/data is the only persistent path)
#   2. rebuild the ephemeral half (user record, wrapper)
#   3. start and supervise the Raft Computer
#   4. supervise NOTIFY_CMD, a long-lived poller (e.g. a chat approval bridge)
#   5. run MONITOR_CMD on an interval, if one is configured
#
# First boot has no credentials — they need interactive logins — so the box comes
# up idle and says what to do rather than crash-looping.

set -u

HOME_DIR="${AGENT_HOME:-/data/agent}"
SLOCK_RUN="$HOME_DIR/.slock/computer/run"
BOXPATH="$HOME_DIR/.local/bin:/data/.local/bin:/usr/local/bin:/usr/bin:/bin"
EVERY_H="${MONITOR_EVERY_H:-24}"
STAMP="$HOME_DIR/local/monitor.stamp"
NOTIFY_PIDFILE="$HOME_DIR/local/notify.pid"

log() { echo "[box] $*"; }
as_agent() { su agent -s /bin/sh -c "export HOME=$HOME_DIR; export AGENT_HOME=$HOME_DIR; export PATH=$BOXPATH; $1"; }

# --- 1 & 2: volume and the ephemeral half ------------------------------------
mkdir -p "$HOME_DIR/local" "$HOME_DIR/.claude"
# uid 1000 is not optional: /data is owned by it and the user record lives on
# the ephemeral root filesystem, so it is recreated on every boot.
id agent >/dev/null 2>&1 || useradd -u 1000 -d "$HOME_DIR" -s /bin/sh agent
if [ "$(stat -c %u "$HOME_DIR" 2>/dev/null)" != "1000" ]; then
    chown -R agent:agent "$HOME_DIR" 2>/dev/null || true
fi
# Skills are NOT linked globally. A symlink here puts every skill in front of
# every agent on the box, which silently defeats whatever the roster says each
# agent is allowed to do: a reviewer ends up holding a writing skill, a writer
# ends up able to grade its own work. Prompts cannot undo that — the agent can
# see the skill, so it can use it.
#
# Skills belong in each agent's own working directory:
#   <home>/.slock/agents/<id>/.claude/skills/<only-what-that-agent-may-use>
#
# Deployment places them per agent; nothing here should widen that. If an old
# box carries the global link from a previous image, remove it rather than
# leaving a boundary that exists in the roster and not on disk.
if [ -L "$HOME_DIR/.claude/skills" ]; then
    rm -f "$HOME_DIR/.claude/skills"
    log "removed the global skills symlink — skills are scoped per agent"
fi

have_claude() { [ -f "$HOME_DIR/.claude/.credentials.json" ]; }
have_raft()   { [ -f "$HOME_DIR/.slock/computer/user-session.json" ]; }

have_claude || log "Claude Code NOT authenticated — in the console: su agent -s /bin/sh; export HOME=$HOME_DIR; claude auth login"
have_raft   || log "Raft NOT logged in — as agent: raft-computer login && raft-computer setup \$RAFT_SERVER -y"
[ -n "$RAFT_SERVER" ] || log "RAFT_SERVER unset — maritime env set <agent> RAFT_SERVER=/your-workspace --reload"

# --- 2b: register a product MCP, if a key is configured -----------------------
# CITABLE_MCP_KEY is the brand-locked key for the Citable platform MCP. Without
# this block every box needs the registration done by hand, which is invisible
# until an agent answers a question with no data and nobody knows why.
#
# --scope user is load-bearing. Registered at project scope, the server attaches
# to the directory the command ran in — so `claude mcp list` reports "Connected"
# from a shell while the agents, which run in their own working directories, have
# no tools at all. It looks correct from outside and is broken where it matters.
if [ -n "$CITABLE_MCP_KEY" ] && have_claude; then
    if ! as_agent "claude mcp list" 2>/dev/null | grep -q "^citable:"; then
        as_agent "claude mcp add --scope user --transport http citable \
            https://app.getcitable.com/mcp/v1 \
            --header \"Authorization: Bearer $CITABLE_MCP_KEY\"" >/dev/null 2>&1 \
            && log "registered the citable MCP (user scope)" \
            || log "citable MCP registration FAILED — check CITABLE_MCP_KEY"
    fi
elif [ -z "$CITABLE_MCP_KEY" ]; then
    log "CITABLE_MCP_KEY unset — the Citable MCP will not be available to agents"
fi

# --- 3: supervise the Computer ------------------------------------------------
# Stale pid/sock survive a restart and make raft-computer report a dead service
# as running, which blocks every start attempt. Clear them before starting.
start_computer() {
    rm -f "$SLOCK_RUN/service.pid" "$SLOCK_RUN/service.sock" 2>/dev/null || true
    log "starting Raft Computer for $RAFT_SERVER"
    as_agent "raft-computer start $RAFT_SERVER" 2>&1 | sed 's/^/[raft] /'
}
computer_running() { as_agent "raft-computer status" 2>/dev/null | grep -qi "^Service:.*running"; }

# --- 4: the long-lived poller -------------------------------------------------
# Chat approval bridges need exactly one process holding the poll. Telegram's
# getUpdates is exclusive and stateful: with nothing polling, presses queue
# silently and the next short-lived poller consumes a stale one as the answer to
# a different question. That is why this belongs to PID 1 and not to a run.
notify_running() {
    [ -f "$NOTIFY_PIDFILE" ] || return 1
    kill -0 "$(cat "$NOTIFY_PIDFILE" 2>/dev/null)" 2>/dev/null
}

start_notify() {
    [ -n "${NOTIFY_CMD:-}" ] || return 0
    notify_running && return 0
    log "starting NOTIFY_CMD"
    su agent -s /bin/sh -c "export HOME=$HOME_DIR; export PATH=$BOXPATH; cd $HOME_DIR && exec $NOTIFY_CMD" \
        >> "$HOME_DIR/local/notify.log" 2>&1 &
    echo $! > "$NOTIFY_PIDFILE"
}

# --- 5: interval work ---------------------------------------------------------
# Elapsed-time check rather than a long sleep: when the VM sleeps the process is
# frozen, so sleep durations understate wall-clock.
maybe_monitor() {
    [ -n "$MONITOR_CMD" ] || return 0
    now=$(date -u +%s); last=0
    [ -f "$STAMP" ] && last=$(cat "$STAMP" 2>/dev/null || echo 0)
    [ $(( now - last )) -ge $(( EVERY_H * 3600 )) ] || return 0
    log "running MONITOR_CMD"
    if sh -c "cd $HOME_DIR && $MONITOR_CMD" 2>&1 | sed 's/^/[monitor] /'; then
        echo "$now" > "$STAMP"
    else
        log "MONITOR_CMD failed — stamp not advanced, will retry"
    fi
}

log "ready · claude=$(/usr/local/bin/claude-real --version 2>/dev/null || echo '?') · raft=$(raft-computer --version 2>/dev/null || echo '?') · home=$HOME_DIR"

FIRST=1
while true; do
    if [ -n "$RAFT_SERVER" ] && have_raft; then
        computer_running || { [ "$FIRST" = 1 ] || log "Computer down — restarting"; start_computer; }
    elif [ "$FIRST" = 1 ]; then
        log "idle: waiting on credentials and RAFT_SERVER (box is otherwise ready)"
    fi
    start_notify
    maybe_monitor
    FIRST=0
    sleep 300
done
