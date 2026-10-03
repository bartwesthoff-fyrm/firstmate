# Evidence: away-supervisor busy-deferral diagnostics (fm/fm-afk-busy-false-positive @ b20ccf1)

All runs 2026-10-03 on Claude Code 2.1.288, Herdr 0.9.3, tmux, macOS.

| File | What it shows |
| --- | --- |
| `s1-idle-primary-with-daemon-background-task.txt` | Tmux lab: a real Claude primary ran `/afk` and started the away daemon as its own background Bash task. The footer reads `1 shell still running`, and the live `pane_is_busy` verdict on that idle pane is `IDLE`. |
| `s1-s3-supervise-daemon.log` | The real daemon's log from that lab. Five ask-user `needs-decision` escalations. Four went straight to the idle pane. One was raised during a real foreground Bash turn: it was deferred with `source=rendered, backend=tmux, harness=claude, version_at_daemon_start=2.1.288 (Claude Code)` and delivered once the turn ended. The harness was detected from process ancestry (`FM_DAEMON_PRIMARY_HARNESS` was not set). No `inject failed` lines. |
| `s1-s3-primary-pane-full-history.txt`, `s1-s3-operational-inbox/` | The Claude pane received five doorbells and handled each one (captain-held for return). The inbox holds the five distinct records. |
| `s3-midturn-primary-pane.txt` | The primary pane during the foreground `ping` turn, when the deferral was logged. |
| `s4-real-daemon-version-probe*.{sh,txt}` | Adversarial test on a real daemon process. A hung `claude --version` is cut off by the 5s bound: start is logged 6.7s after launch, the log says `version_at_daemon_start=unavailable`, and no probe process is left behind. A `cursor` primary probes `cursor-agent --version` once and never runs `cursor`. |
| `s5-herdr-native-deferral*.{sh,txt}` | Named `fm-lab-*` Herdr session: a real daemon and a real Claude pane. During a foreground turn (Herdr `agent_status=working`), every deferral logs `source=native, backend=herdr, harness=claude, version_at_daemon_start=2.1.288 (Claude Code)`. The ask-user escalation was delivered once the turn ended. |
| `herdr-claude-busy-live-guard.txt` | `FM_AFK_CLAUDE_BUSY_LIVE=1 tests/fm-afk-claude-busy-live-e2e.test.sh` passed: background task and one-line reply read idle, mid-turn reads busy. |
| `targeted-tests-with-harness-tripwire.txt` | `tests/fm-afk-inject-e2e.test.sh` (including Scenario D: real daemon start logs the stub version on a busy deferral) and `tests/fm-daemon.test.sh` both passed, with a PATH tripwire recording zero host harness CLI calls. |
