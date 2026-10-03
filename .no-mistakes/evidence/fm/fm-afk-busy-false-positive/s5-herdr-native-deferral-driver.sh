#!/usr/bin/env bash
# Live driver: real away daemon (bin/fm-supervise-daemon.sh as its own process)
# against a real Claude Code pane in a named non-default fm-lab-* Herdr session,
# every Herdr call routed through bin/fm-herdr-lab.sh. While Claude runs a real
# foreground Bash turn, an ask-user escalation must defer and the deferral must
# name source=native, backend=herdr, harness=claude and the real Claude version
# probed at daemon start; once the turn ends the escalation must be delivered.
# Usage: <driver> <worktree>
set -u
ROOT=$1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX TMUX_PANE
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name fm-afk-native)
ORIGINAL_PATH=$PATH
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-native.XXXXXX")
LABHOME="$WORK/home"
DAEMON_PID=
PANE=
say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
lab() { env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
cleanup() {
  local attempt=0
  trap - EXIT
  [ -z "$DAEMON_PID" ] || { kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; }
  if [ -n "$PANE" ]; then
    lab pane send-text "$PANE" '/exit' >/dev/null 2>&1; sleep 1
    lab pane send-keys "$PANE" enter >/dev/null 2>&1; sleep 3
  fi
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" >/dev/null 2>&1 && { say "lab session $SESSION torn down"; break; }
    sleep 2
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LABHOME" >/dev/null || exit 1
printf 'off\n' > "$LABHOME/config/wedge-alarm"
"$HELPER" provision "$SESSION" >/dev/null || { say "provision failed"; exit 1; }
say "provisioned $SESSION ($(herdr --version | head -1))"
mkdir -p "$WORK/shim"
cat > "$WORK/shim/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 98
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$WORK/shim/herdr"

WS=$(lab workspace create --cwd "$ROOT" --label afknative --no-focus) || { say "workspace create failed"; exit 1; }
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id') || exit 1
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME='$LABHOME' DISABLE_AUTOUPDATER=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null || exit 1
ready=0
for _ in $(seq 1 60); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*) ready=1; break ;;
  esac
  sleep 1
done
[ "$ready" = 1 ] || { say "Claude composer never rendered"; exit 1; }
say "Claude $(claude --version | head -1) idle in $TARGET"
lab pane send-text "$PANE" 'Reply with exactly WARM_READY and stop.' >/dev/null
warm=0
for i in $(seq 1 90); do
  if [ $((i % 3)) = 1 ]; then lab pane send-keys "$PANE" enter >/dev/null; fi
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'⏺ WARM_READY'*'❯'*) warm=1; break ;; esac
  sleep 1
done
[ "$warm" = 1 ] || { say "warm-up round trip failed"; exit 1; }
say "warm-up round trip done"

# A real foreground Bash turn (Claude Code blocks a standalone foreground sleep).
# shellcheck disable=SC2016
lab pane send-text "$PANE" 'Run the Bash tool command `ping -c 40 -i 1 127.0.0.1 >/dev/null` in the foreground (not in the background), then reply exactly TURN_DONE.' >/dev/null
sleep 1
lab pane send-keys "$PANE" enter >/dev/null
working=0
for _ in $(seq 1 30); do
  [ "$(lab agent get "$PANE" | jq -r '.result.agent.agent_status // empty')" = working ] && { working=1; break; }
  sleep 1
done
[ "$working" = 1 ] || { say "Claude never reported working"; exit 1; }
say "Herdr native agent_status=working; rendered tail: $(lab pane read "$PANE" --source visible 2>/dev/null | grep -v '^[[:space:]]*$' | tail -6 | tr '\n' '|')"

# Away posture on, a fixer's ask-user gate pending, then start the real daemon.
( . "$ROOT/bin/fm-supervise-daemon.sh"; afk_enter "$LABHOME/state" )
echo 'needs-decision: ask-user: keep the legacy --since flag name or rename it to --after? (fixer-native)' > "$LABHOME/state/fixer-native.status"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LABHOME" PATH="$WORK/shim:$ORIGINAL_PATH" HERDR_SESSION="$SESSION" \
  FM_DAEMON_PRIMARY_HARNESS=claude FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
  FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=2 FM_SIGNAL_GRACE=1 FM_HEARTBEAT_SCAN_SECS=5 \
  FM_STALE_ESCALATE_SECS=999999 FM_WEDGE_ALARM_CHANNEL=off \
  "$ROOT/bin/fm-supervise-daemon.sh" >"$WORK/daemon.out" 2>"$WORK/daemon.err" &
DAEMON_PID=$!
LOG="$LABHOME/state/.supervise-daemon.log"
deferred=0
for _ in $(seq 1 60); do
  grep -q 'inject deferred: supervisor pane busy' "$LOG" 2>/dev/null && { deferred=1; break; }
  sleep 0.5
done
say "native agent_status at first deferral check: $(lab agent get "$PANE" | jq -r '.result.agent.agent_status // empty')"
[ "$deferred" = 1 ] || { say "no busy deferral"; cat "$LOG" "$WORK/daemon.err"; exit 1; }
delivered=0
for _ in $(seq 1 90); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'Firstmate operational input waiting'*) delivered=1; break ;; esac
  sleep 1
done
say "--- daemon log:"
sed "s#$WORK#<work>#g" "$LOG"
say "--- pane after turn end:"
lab pane read "$PANE" --source visible 2>/dev/null | grep -v '^[[:space:]]*$' | tail -16 | sed "s#$WORK#<work>#g"
[ "$delivered" = 1 ] || { say "deferred escalation never delivered after the turn ended"; exit 1; }
sleep 15
say "--- pane after Claude handled the escalation:"
lab pane read "$PANE" --source visible 2>/dev/null | grep -v '^[[:space:]]*$' | tail -12 | sed "s#$WORK#<work>#g"
say "RESULT: deferred mid-turn, delivered after turn"
