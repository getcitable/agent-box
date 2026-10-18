# How this box's Claude Code is authenticated (CIT-1496). Sourced by
# entrypoint.sh; kept apart so test-box-auth.sh can check it without a box.
#
# AUTH_MODE picks exactly one:
#   login    our own boxes: an interactive `claude auth login`, which leaves
#            ~/.claude/.credentials.json. The default, so existing boxes don't change.
#   api_key  client boxes: ANTHROPIC_API_KEY, from a capped Console workspace.
#
# api_key fails closed if a login is also present. The console is root, so
# anyone could later run `claude auth login` "to fix something" and quietly
# give a client box a founder's Gmail, Drive and Calendar. A client box with a
# login on it does not start its agents.
#
# The key reaches the agent user through the environment only: a non-login
# `su agent` keeps the caller's environment (util-linux 2.38, checked on a
# live box). Never put it inside a `-c` string: that is argv, readable by every
# user in /proc/<pid>/cmdline.

: "${AUTH_MODE:=login}"
: "${ANTHROPIC_API_KEY:=}"

have_login() { [ -f "$HOME_DIR/.claude/.credentials.json" ]; }

have_claude() {
    case "$AUTH_MODE" in
        api_key) [ -n "$ANTHROPIC_API_KEY" ] ;;
        login)   have_login ;;
        *)       return 1 ;;
    esac
}

# Why the agents must not start, or nothing. Checked before every start. Login
# mode never blocks: our boxes behave exactly as before this file existed.
auth_blocker() {
    case "$AUTH_MODE" in
        api_key)
            have_login && { echo "client box has a Claude login; remove $HOME_DIR/.claude/.credentials.json (AUTH_MODE=api_key never uses one)"; return; }
            [ -n "$ANTHROPIC_API_KEY" ] || echo "AUTH_MODE=api_key but ANTHROPIC_API_KEY is unset — maritime env set <box> ANTHROPIC_API_KEY=... --reload"
            ;;
        login) ;;
        *) echo "AUTH_MODE='$AUTH_MODE' is not api_key or login" ;;
    esac
}

# Run every supervisor pass. Returns 0 when the agents may run. Otherwise logs
# the blocker when it changes and stops a Computer that is already up: a login
# created on the console later must not leave agents running beside it.
# Expects log, computer_running and stop_computer from the entrypoint.
AUTH_LAST=
auth_gate() {
    blocker=$(auth_blocker)
    if [ "$blocker" != "$AUTH_LAST" ]; then
        if [ -n "$blocker" ]; then log "NOT running the Raft Computer: $blocker"; else log "auth OK: the Raft Computer may start"; fi
        AUTH_LAST=$blocker
    fi
    [ -n "$blocker" ] || return 0
    computer_running && { log "stopping the Raft Computer and its agents"; stop_computer; }
    return 1
}

# api_key mode: does the running Raft Computer carry the keys, and is neither
# key in any process's argv? Names only, never values. printf is a shell
# builtin and grep reads the patterns from stdin, so the check adds no argv copy.
check_key_handoff() {
    [ "$AUTH_MODE" = "api_key" ] && [ -n "$ANTHROPIC_API_KEY" ] || return 0
    # `raft-computer start` daemonizes; give the service a moment to appear.
    for _ in 1 2 3 4 5; do
        pid=$(pgrep -u agent -f raft-computer | head -1)
        [ -n "$pid" ] && break
        sleep 2
    done
    for var in ANTHROPIC_API_KEY CITABLE_MCP_KEY; do
        eval "[ -n \"\${$var:-}\" ]" || continue
        if [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q "^$var=."; then
            log "api_key: the Raft Computer (pid $pid) has $var"
        else
            log "api_key: WARNING the Raft Computer does not have $var"
        fi
    done
    if printf '%s\n' "$ANTHROPIC_API_KEY" ${CITABLE_MCP_KEY:+"$CITABLE_MCP_KEY"} | grep -lFf - /proc/[0-9]*/cmdline 2>/dev/null | grep -q .; then
        log "api_key: WARNING a key appears in a process command line"
    else
        log "api_key: neither key is in any process command line"
    fi
}
