#!/bin/sh
# Checks box-auth.sh without a box: sh test-box-auth.sh
set -u
cd "$(dirname "$0")"
fails=0
HOME_DIR=$(mktemp -d); trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/.claude"

# Each case runs in a fresh subshell: AUTH_MODE, key ("" = unset), login file?
run() { ( unset AUTH_MODE ANTHROPIC_API_KEY
          [ -n "$1" ] && AUTH_MODE=$1; [ -n "$2" ] && ANTHROPIC_API_KEY=$2
          if [ "$3" = login ]; then : > "$HOME_DIR/.claude/.credentials.json"; else rm -f "$HOME_DIR/.claude/.credentials.json"; fi
          . ./box-auth.sh; eval "$4" ); }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
starts() { run "$1" "$2" "$3" '[ -z "$(auth_blocker)" ] && echo starts || echo blocked'; }

check "api_key + key starts"                    "$(starts api_key sk-test none)"  starts
check "api_key + key + login is blocked"         "$(starts api_key sk-test login)" blocked
check "api_key without key is blocked"           "$(starts api_key '' none)"       blocked
check "api_key + login, no key is blocked"       "$(starts api_key '' login)"      blocked
check "default mode is login, unchanged"         "$(starts '' '' login)"           starts
check "login without credentials starts as before" "$(starts login '' none)"     starts
check "login without login is not authenticated" "$(run login sk-test none 'have_claude || echo no')" no
check "unknown AUTH_MODE is blocked"             "$(starts apikey sk-test none)"   blocked
check "api_key + key counts as authenticated"    "$(run api_key sk-test none 'have_claude && echo yes')" yes

check "blocker message never holds the key"      "$(run api_key sk-secret-123 login auth_blocker | grep -c sk-secret-123)" 0

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
