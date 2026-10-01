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
#   4. run MONITOR_CMD on an interval, if one is configured
#
# First boot has no credentials — they need interactive logins — so the box comes
# up idle and says what to do rather than crash-looping.

set -u

HOME_DIR="${AGENT_HOME:-/data/agent}"
SLOCK_RUN="$HOME_DIR/.slock/computer/run"
BOXPATH="$HOME_DIR/.local/bin:/data/.local/bin:/usr/local/bin:/usr/bin:/bin"
EVERY_H="${MONITOR_EVERY_H:-24}"
STAMP="$HOME_DIR/local/monitor.stamp"

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
# Link skills from the volume so a push updates them without a rebuild.
[ -d "$HOME_DIR/skills" ] && { rm -rf "$HOME_DIR/.claude/skills"; ln -s "$HOME_DIR/skills" "$HOME_DIR/.claude/skills"; }
chown -h agent:agent "$HOME_DIR/.claude/skills" 2>/dev/null || true

have_claude() { [ -f "$HOME_DIR/.claude/.credentials.json" ]; }
have_raft()   { [ -f "$HOME_DIR/.slock/computer/user-session.json" ]; }

have_claude || log "Claude Code NOT authenticated — in the console: su agent -s /bin/sh; export HOME=$HOME_DIR; claude auth login"
have_raft   || log "Raft NOT logged in — as agent: raft-computer login && raft-computer setup \$RAFT_SERVER -y"
[ -n "$RAFT_SERVER" ] || log "RAFT_SERVER unset — maritime env set <agent> RAFT_SERVER=/your-workspace --reload"

# --- 3: supervise the Computer ------------------------------------------------
# Stale pid/sock survive a restart and make raft-computer report a dead service
# as running, which blocks every start attempt. Clear them before starting.
start_computer() {
    rm -f "$SLOCK_RUN/service.pid" "$SLOCK_RUN/service.sock" 2>/dev/null || true
    log "starting Raft Computer for $RAFT_SERVER"
    as_agent "raft-computer start $RAFT_SERVER" 2>&1 | sed 's/^/[raft] /'
}
computer_running() { as_agent "raft-computer status" 2>/dev/null | grep -qi "^Service:.*running"; }

# --- 4: interval work ---------------------------------------------------------
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
    maybe_monitor
    FIRST=0
    sleep 300
done
