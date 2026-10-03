#!/usr/bin/env bash
# Adversarial live driver: start the REAL bin/fm-supervise-daemon.sh process
# (no sourcing, no function stubs) against a disposable lab home and a private
# tmux socket, with stub harness CLIs on PATH, and observe its startup time and
# busy-deferral log line.
#   Case A: FM_DAEMON_PRIMARY_HARNESS=claude whose `claude --version` hangs.
#   Case B: FM_DAEMON_PRIMARY_HARNESS=cursor; `cursor-agent` prints a version,
#           `cursor` (the IDE launcher) must never run.
# Usage: <driver> <worktree>
set -u
ROOT=$1
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
REAL_TMUX=$(command -v tmux)
SOCK="fm-adv-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-adv.XXXXXX")
STUB="$WORK/stub"
CALLS="$WORK/calls.log"
mkdir -p "$STUB"
: > "$CALLS"
DAEMON_PID=
LAB=
cleanup() {
  [ -z "$DAEMON_PID" ] || { kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; }
  "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$STUB/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
EOF
cat > "$STUB/claude" <<EOF
#!/usr/bin/env bash
printf 'claude %s\n' "\$*" >> "$CALLS"
exec sleep 61.37
EOF
cat > "$STUB/cursor-agent" <<EOF
#!/usr/bin/env bash
printf 'cursor-agent %s\n' "\$*" >> "$CALLS"
printf '2026.10.01-stub\nsecond line\n'
EOF
cat > "$STUB/cursor" <<EOF
#!/usr/bin/env bash
printf 'cursor %s\n' "\$*" >> "$CALLS"
printf 'IDE-launcher-should-not-run\n'
EOF
chmod +x "$STUB"/*

run_case() {  # <label> <harness> <footer>
  local label=$1 harness=$2 footer=$3 pane t0 t1 i
  LAB="$WORK/lab-$label"
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; return 1; }
  printf 'off\n' > "$LAB/config/wedge-alarm"
  "$REAL_TMUX" -L "$SOCK" new-session -d -s "sup-$label" -x 200 -y 50 \
    "printf '%s\n' '$footer'; exec sleep 600"
  "$REAL_TMUX" -L "$SOCK" new-window -d -t "sup-$label" -n "fm-crew-$label" 'exec sleep 600'
  pane=$("$REAL_TMUX" -L "$SOCK" display-message -p -t "sup-$label:0" '#{pane_id}')
  sleep 0.5
  echo "== case $label: harness=$harness, supervisor pane $pane renders: $("$REAL_TMUX" -L "$SOCK" capture-pane -p -t "$pane" | grep -v '^$' | head -1)"
  # Away posture on for the lab home (presence gate).
  ( . "$DAEMON"; afk_enter "$LAB/state" )
  t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
    FM_HOME="$LAB" PATH="$STUB:$PATH" FM_DAEMON_PRIMARY_HARNESS="$harness" \
    FM_SUPERVISOR_TARGET="$pane" FM_SUPERVISOR_BACKEND=tmux \
    FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_STALE_ESCALATE_SECS=999999 FM_WEDGE_ALARM_CHANNEL=off \
    "$DAEMON" >"$WORK/daemon-$label.out" 2>"$WORK/daemon-$label.err" &
  DAEMON_PID=$!
  i=0
  until grep -q 'daemon starting' "$LAB/state/.supervise-daemon.log" 2>/dev/null; do
    [ "$i" -lt 300 ] || { echo "FAIL: daemon never logged start"; cat "$WORK/daemon-$label.err"; return 1; }
    sleep 0.1; i=$((i + 1))
  done
  t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
  echo "daemon start logged $(perl -e "printf '%.1f', $t1 - $t0")s after launch"
  echo "needs-decision: ask-user: adversarial probe gate ($label)" > "$LAB/state/crew-$label.status"
  i=0
  until [ "$(grep -c 'inject deferred: supervisor pane busy' "$LAB/state/.supervise-daemon.log" 2>/dev/null)" -ge 2 ]; do
    [ "$i" -lt 300 ] || { echo "FAIL: no busy deferral"; cat "$LAB/state/.supervise-daemon.log"; return 1; }
    sleep 0.1; i=$((i + 1))
  done
  echo "--- daemon log ($label):"
  sed "s#$WORK#<work>#g" "$LAB/state/.supervise-daemon.log" | grep -E 'daemon starting|escalate:|inject deferred' | head -6
  kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null; DAEMON_PID=
  echo "--- leftover hung --version processes: $(pgrep -f "sleep 61.37" | wc -l | tr -d ' ')"
  echo "--- harness CLI calls so far:"; cat "$CALLS"
}

run_case hung claude 'Working (esc to interrupt)'
run_case cursor cursor 'ctrl+c to stop'
