#!/bin/bash

# The stop rate limit exists to keep parallel sub-agents from spamming toasts.
# Its key (last_stop_notification) is a single process-wide file — not scoped by
# agent, project or window — so any agent finishing anywhere silences the next
# completion from everywhere for STOP_RATE_LIMIT_SECONDS.
#
# That is fine for the toast, but it used to take the tmux badge with it: the
# notifier exited before the badge, while the running-marker teardown had
# already run (it deliberately precedes the suppression check). The window ended
# up with neither spinner nor badge — a completed turn looking untouched, with
# nothing to re-light it. Observed live: a Codex completion at 18:28:01 blanked
# an unrelated Claude window's completion badge one second later.
#
# A rate-limited stop must therefore still badge its window, while every hard
# suppressor (snooze, kill switch, stop_hook_active, auto-accept) still
# withholds the badge along with the alert.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
state_dir="$test_dir/state"
# notifications.log is only written when the directory already exists, so create
# it — otherwise the "no log entry" assertions below would pass vacuously.
mkdir -p "$HOME/.claude/notifications/state" "$HOME/.claude/logs" \
    "$fake_bin" "$state_dir"
notify_log="$HOME/.claude/logs/notifications.log"

deliver_log="$test_dir/deliver.log"
: > "$deliver_log"
for tool in terminal-notifier osascript notify-send; do
    printf '#!/bin/bash\necho "%s" >> "%s"\nexit 0\n' "$tool" "$deliver_log" \
        > "$fake_bin/$tool"
    chmod +x "$fake_bin/$tool"
done

# Stateful fake tmux: options and the window name persist as files so they
# round-trip across notifier processes the way real tmux options do.
# rename-window is honoured, so the badge is asserted on the visible name and
# not merely on the bookkeeping options. The window reports itself as hidden
# (third display-message field 0) — the ordinary case for a missed badge.
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
args=("$@")
cmd="${args[0]}"
args=("${args[@]:1}")
target=""
unset_opt=0
rest=()
while (( ${#args[@]} )); do
    a="${args[0]}"
    case "$a" in
        -t) target="${args[1]}"; args=("${args[@]:2}") ;;
        -F|-d) args=("${args[@]:2}") ;;
        -*) [[ "$a" == *u* ]] && unset_opt=1; args=("${args[@]:1}") ;;
        *) rest+=("$a"); args=("${args[@]:1}") ;;
    esac
done
scope="${target:-_global}"
window_name_file="$FAKE_TMUX_STATE/@1.window_name"
case "$cmd" in
    set-option)
        if (( unset_opt )); then
            rm -f "$FAKE_TMUX_STATE/$scope.${rest[0]}"
        else
            printf '%s' "${rest[1]:-}" > "$FAKE_TMUX_STATE/$scope.${rest[0]}"
        fi
        ;;
    show-options)
        cat "$FAKE_TMUX_STATE/$scope.${rest[0]}" 2>/dev/null || true
        ;;
    rename-window)
        printf '%s' "${rest[0]}" > "$window_name_file"
        ;;
    display-message)
        name="$(cat "$window_name_file" 2>/dev/null || echo proj)"
        if [[ "${rest[0]}" == "#{window_id}" ]]; then
            printf '@1\n'
        elif [[ "${rest[0]}" == *"|"* ]]; then
            printf '@1|off|0|%s\n' "$name"
        else
            printf '$1 @1 %%1\n'
        fi
        ;;
    list-windows)
        ;;
esac
exit 0
EOF
chmod +x "$fake_bin/tmux"

export PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"
export FAKE_TMUX_STATE="$state_dir"
export TMUX="$test_dir/fake-socket,1,\$1"
export TMUX_PANE="%1"

stop_stamp="$HOME/.claude/notifications/state/last_stop_notification"

window_name() {
    cat "$state_dir/@1.window_name" 2>/dev/null || echo proj
}

# Return the window to a clean, unbadged state between cases.
reset_window() {
    local opt_name
    for opt_name in @code_notify_orig_name @code_notify_badged_name \
        @code_notify_clear_mode @code_notify_autorename @code_notify_agent_pid \
        @code_notify_running @code_notify_run_gen; do
        rm -f "$state_dir/@1.$opt_name"
    done
    rm -f "$state_dir/@1.@code_notify_queued_prompt"
    printf '%s' "proj" > "$state_dir/@1.window_name"
    : > "$deliver_log"
    : > "$notify_log"
}

# Run a claude Stop through the real notifier. Extra env assignments are passed
# as NAME=VALUE arguments. --global omits the project argument, which is what
# makes a hook global-scoped (a project-scoped hook deliberately opts out of the
# global kill switch — see is_project_scoped_notification).
run_stop() {
    local hook_data='{"session_id":"sess1","stop_hook_active":false}'
    local -a hook_args=(stop claude proj)
    while true; do
        case "${1:-}" in
            --hook-data) hook_data="$2"; shift 2 ;;
            --global) hook_args=(stop claude); shift ;;
            *) break ;;
        esac
    done
    printf '%s\n' "$hook_data" | \
        env "$@" CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        FAKE_TMUX_STATE="$state_dir" \
        bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" "${hook_args[@]}" \
        >/dev/null 2>&1 || true
}

# 1. Control: an unlimited stop toasts, stamps the key, and badges the window.
#    Asserting this first means an empty delivery log later proves suppression
#    rather than broken recording fakes.
reset_window
rm -f "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ -s "$deliver_log" ]] || fail "control stop should reach desktop delivery"
[[ -f "$stop_stamp" ]] || fail "control stop should stamp the rate limiter"
[[ -s "$notify_log" ]] || fail "control stop should write a notifications.log entry"
[[ "$(window_name)" == "🟢 proj" ]] \
    || fail "control stop should badge the window (got: $(window_name))"
[[ "$(cat "$state_dir/@1.@code_notify_clear_mode" 2>/dev/null)" == "engage" ]] \
    || fail "a claude completion badge should be engage-clear"
pass "an unlimited stop toasts, stamps and badges"

# 2. THE FIX: a stop suppressed purely by the rate limit still badges. It must
#    not toast, and must not stamp the key either — stamping would push the
#    next real completion's alert out by another window.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] \
    || fail "a rate-limited stop must not deliver a desktop notification"
[[ ! -s "$HOME/.claude/logs/notifications.log" ]] \
    || fail "a rate-limited stop must not write a notifications.log entry"
[[ "$(window_name)" == "🟢 proj" ]] \
    || fail "a rate-limited stop must still badge its window (got: $(window_name))"
[[ "$(cat "$state_dir/@1.@code_notify_clear_mode" 2>/dev/null)" == "engage" ]] \
    || fail "the rate-limited badge should carry the normal engage-clear mode"
pass "a rate-limited stop badges the window without toasting"

# 3. The badge-only downgrade must leave the rate-limit key untouched, so the
#    next completion elsewhere still alerts on time rather than being pushed out
#    by a stop that never made a sound.
#
#    The seed is deliberately a minute old rather than "now": an erroneous
#    refresh writes date +%s, which within the same wall-clock second is
#    byte-identical to a "now" seed, so this assertion would have passed through
#    the very bug it exists to catch. Backdating makes any refresh observable
#    while 60 < 600 keeps the run rate limited.
reset_window
now_stamp="$(( $(date +%s) - 60 ))"
printf '%s' "$now_stamp" > "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ "$(cat "$stop_stamp")" == "$now_stamp" ]] \
    || fail "a rate-limited badge-only stop must not stamp the rate limiter (got: $(cat "$stop_stamp"), expected $now_stamp)"
[[ "$(window_name)" == "🟢 proj" ]] \
    || fail "precondition: this run should still have been rate limited and badged"
pass "a rate-limited stop leaves the rate-limit key unstamped"

# 4. Ordering guard: stop_hook_active is a hard suppressor and must win over
#    the rate limit, so a nested stop gets no badge. This is what makes the
#    rate-limit check's position (last in should_suppress_notification)
#    load-bearing — checked before the hard suppressors, it would have let
#    these through as badges.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop --hook-data '{"session_id":"sess1","stop_hook_active":true}' \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] || fail "a stop_hook_active stop must not deliver"
[[ "$(window_name)" == "proj" ]] \
    || fail "a stop_hook_active stop must not badge, even when rate limited (got: $(window_name))"
pass "stop_hook_active suppresses the badge even while rate limited"

# 5. Same for auto-accept, the other hard suppressor that shares the stop path.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop --hook-data '{"session_id":"sess1","autoAccepted":true}' \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ "$(window_name)" == "proj" ]] \
    || fail "an auto-accepted stop must not badge, even when rate limited (got: $(window_name))"
pass "an auto-accepted stop suppresses the badge even while rate limited"

# 6. Snooze is an explicit request for quiet, not spam control: it withholds
#    the badge too. Seeded with an ACTIVE rate limit so both suppressors apply
#    at once — with the limit inert this would pass without ever exercising the
#    badge-only conversion snooze has to win against.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
printf '%s' "$(( $(date +%s) + 3600 ))" > "$HOME/.claude/notifications/snooze-until"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] || fail "a snoozed stop must not deliver"
[[ "$(window_name)" == "proj" ]] \
    || fail "snooze must beat the rate-limit badge-only conversion (got: $(window_name))"
rm -f "$HOME/.claude/notifications/snooze-until"
pass "snooze suppresses the badge even while rate limited"

# 7. The kill switch (cn off) likewise silences the badge, and likewise has to
#    beat an active rate limit. Global scope: a project-scoped hook deliberately
#    ignores the global switch.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
touch "$HOME/.claude/notifications/disabled"
run_stop --global CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] || fail "a disabled stop must not deliver"
[[ "$(window_name)" == "proj" ]] \
    || fail "the kill switch must beat the rate-limit badge-only conversion (got: $(window_name))"
rm -f "$HOME/.claude/notifications/disabled"
pass "the kill switch suppresses the badge even while rate limited"

# 8. The badge-only path must not paint over a successor turn. A queued-prompt
#    hint makes this Stop preserve the running marker for the turn that is
#    already starting; the badge block is skipped on that preserve
#    (TMUX_RUNNING_STOP_PRESERVED), and being rate limited must not change that
#    — otherwise the fix would trade a missing badge for a stolen spinner.
reset_window
printf '%s' "$(date +%s)" > "$state_dir/@1.@code_notify_running"
printf '%s' "$(date +%s)" > "$state_dir/@1.@code_notify_queued_prompt"
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ -s "$state_dir/@1.@code_notify_running" ]] \
    || fail "a preserving stop must keep the running marker for the successor turn"
[[ "$(window_name)" == "proj" ]] \
    || fail "a rate-limited preserving stop must not badge over a live successor (got: $(window_name))"
pass "a rate-limited stop leaves a preserved successor turn alone"

# Delegated lifecycle alerts may toast, but must not cover a running session
# with an individual task's badge. Exercise the real notifier and badge lock.
printf '%s' 'stop|SubagentStart|SubagentStop|TeammateIdle|TaskCreated|TaskCompleted|permission_prompt' \
    > "$HOME/.claude/notifications/notify-types"
for event in SubagentStart SubagentStop TeammateIdle TaskCreated TaskCompleted; do
    reset_window
    date +%s > "$state_dir/@1.@code_notify_running"
    printf '%s\n' '{"session_id":"sess1"}' | \
        CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" "$event" claude proj \
        >/dev/null 2>&1 || fail "$event should exit cleanly"
    [[ -s "$state_dir/@1.@code_notify_running" ]] \
        || fail "$event must preserve the running epoch"
    [[ "$(window_name)" == "proj" ]] \
        || fail "$event must not cover the spinner with an event badge"
    [[ -s "$deliver_log" ]] || fail "$event should still deliver its enabled alert"
done
pass "delegated lifecycle alerts preserve the spinner while still notifying"

for delegate in subagent workflow; do
    reset_window
    touch "$HOME/.claude/notifications/tmux-spinner-enabled"
    date +%s > "$state_dir/@1.@code_notify_running"
    run_stop --hook-data "{\"session_id\":\"sess1\",\"background_tasks\":[{\"type\":\"$delegate\",\"status\":\"running\"}]}" \
        CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
    [[ -s "$state_dir/@1.@code_notify_running" ]] \
        || fail "Stop with a running $delegate must preserve the spinner"
    [[ -s "$state_dir/@1.@code_notify_delegated" ]] \
        || fail "Stop with a running $delegate must select the delegated spinner"
    [[ "$(window_name)" == "proj" && ! -s "$deliver_log" ]] \
        || fail "Stop with a running $delegate must not announce completion"
    run_stop --hook-data '{"session_id":"sess1","background_tasks":[]}' \
        CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
    [[ ! -s "$state_dir/@1.@code_notify_running" && "$(window_name)" == "🟢 proj" ]] \
        || fail "Stop after $delegate completion must replace the spinner with completion"
    [[ ! -e "$state_dir/@1.@code_notify_delegated" ]] \
        || fail "Stop after $delegate completion must clear the delegated spinner"
    rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
done
pass "delegated Stop preserves the spinner until the registry is clear"

reset_window
date +%s > "$state_dir/@1.@code_notify_running"
printf '1' > "$state_dir/@1.@code_notify_delegated"
printf '%s\n' '{"session_id":"sess1"}' | \
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
    bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" UserPromptSubmit claude proj \
    >/dev/null 2>&1 || fail "new prompt should exit cleanly"
[[ ! -e "$state_dir/@1.@code_notify_delegated" ]] \
    || fail "new prompt must reset the delegated spinner"
pass "new prompt restores the normal running spinner"

# A teammate is listed as running in the Stop payload whether it works or is
# parked; only an unanswered SubagentStart says it works. While it works, the
# lead's Stop and idle reminder still notify, but the window keeps the clock
# spinner instead of the completion badge.
run_claude_event() {
    local event="$1" data="$2"
    printf '%s\n' "$data" | \
        CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" "$event" claude proj \
        >/dev/null 2>&1 || fail "$event should exit cleanly"
}
teammate_stop='{"session_id":"sess1","background_tasks":[{"type":"teammate","status":"running"}]}'
printf '%s' 'stop|idle_prompt|SubagentStart|TeammateIdle' \
    > "$HOME/.claude/notifications/notify-types"
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
reset_window
rm -f "$state_dir/@1.@code_notify_delegated" "$state_dir/@1.@code_notify_teammate_busy"
date +%s > "$state_dir/@1.@code_notify_running"
run_claude_event SubagentStart '{"session_id":"sess1"}'
[[ -s "$state_dir/@1.@code_notify_teammate_busy" ]] \
    || fail "SubagentStart must record the unanswered teammate start"
: > "$deliver_log"
run_stop --hook-data "$teammate_stop" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ -s "$state_dir/@1.@code_notify_running" && "$(cat "$state_dir/@1.@code_notify_delegated")" == "1" ]] \
    || fail "Stop with a working teammate must keep the clock spinner"
[[ "$(window_name)" == "proj" ]] \
    || fail "Stop with a working teammate must not badge over the spinner (got: $(window_name))"
[[ -s "$deliver_log" ]] || fail "Stop with a working teammate must still notify"
[[ "$(tail -n 1 "$HOME/.claude/logs/notifications.log" 2>/dev/null)" == *teammate* ]] \
    || fail "Stop with a working teammate must say the teammate still runs"

: > "$deliver_log"
run_claude_event notification '{"session_id":"sess1","notification_type":"idle_prompt"}'
[[ -s "$state_dir/@1.@code_notify_running" && "$(window_name)" == "proj" ]] \
    || fail "idle reminder while a teammate works must keep the spinner"
[[ -s "$deliver_log" ]] || fail "idle reminder while a teammate works must still notify"
[[ "$(tail -n 1 "$HOME/.claude/logs/notifications.log" 2>/dev/null)" == *teammate* ]] \
    || fail "idle reminder while a teammate works must say the teammate still runs"

run_claude_event UserPromptSubmit '{"session_id":"sess1"}'
[[ ! -e "$state_dir/@1.@code_notify_queued_prompt" ]] \
    || fail "a held teammate spinner is not a queued-successor turn"
run_stop --hook-data "$teammate_stop" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ "$(cat "$state_dir/@1.@code_notify_delegated" 2>/dev/null)" == "1" && "$(window_name)" == "proj" ]] \
    || fail "a later lead Stop must hold the clock while the teammate still works"

run_claude_event TeammateIdle '{"session_id":"sess1"}'
[[ ! -e "$state_dir/@1.@code_notify_teammate_busy" && ! -e "$state_dir/@1.@code_notify_delegated" ]] \
    || fail "TeammateIdle must answer the teammate start and drop the clock"
[[ -s "$state_dir/@1.@code_notify_running" ]] \
    || fail "TeammateIdle must keep the spinner for the lead picking up the report"
run_stop --hook-data "$teammate_stop" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ ! -s "$state_dir/@1.@code_notify_running" && "$(window_name)" == "🟢 proj" ]] \
    || fail "Stop with only a parked teammate must complete (got: $(window_name))"

reset_window
date +%s > "$state_dir/@1.@code_notify_running"
date +%s > "$state_dir/@1.@code_notify_teammate_busy"
run_stop --hook-data '{"session_id":"sess1","background_tasks":[]}' \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ "$(window_name)" == "🟢 proj" && ! -e "$state_dir/@1.@code_notify_teammate_busy" ]] \
    || fail "Stop with no running teammate must complete and drop a stale teammate start"

# A queued prompt's hint must survive a teammate hold that lands after it: a
# later queued prompt must not clear it, or the running turn's Stop runs that
# successor dark once the teammate retires.
reset_window
rm -f "$state_dir/@1.@code_notify_delegated" "$state_dir/@1.@code_notify_teammate_busy" \
    "$state_dir/@1.@code_notify_queued_prompt"
date +%s > "$state_dir/@1.@code_notify_running"
run_claude_event SubagentStart '{"session_id":"sess1"}'
run_claude_event UserPromptSubmit '{"session_id":"sess1"}'
[[ -s "$state_dir/@1.@code_notify_queued_prompt" ]] \
    || fail "a prompt queued behind a running turn must leave the hint"
run_stop --hook-data "$teammate_stop" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ "$(cat "$state_dir/@1.@code_notify_delegated" 2>/dev/null)" == "1" ]] \
    || fail "a late Stop with a working teammate must hold the clock"
run_claude_event UserPromptSubmit '{"session_id":"sess1"}'
[[ -s "$state_dir/@1.@code_notify_queued_prompt" ]] \
    || fail "a prompt after a teammate hold must keep the existing hint"
run_claude_event TeammateIdle '{"session_id":"sess1"}'
run_stop --hook-data "$teammate_stop" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ -s "$state_dir/@1.@code_notify_running" && "$(window_name)" == "proj" ]] \
    || fail "the preserved hint must keep the queued successor's spinner (got: $(window_name))"
[[ ! -e "$state_dir/@1.@code_notify_queued_prompt" ]] \
    || fail "the Stop must consume the preserved hint"
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
pass "a working teammate keeps the clock spinner without holding back notifications"

reset_window
date +%s > "$state_dir/@1.@code_notify_running"
printf '%s\n' '{"session_id":"sess1","notification_type":"permission_prompt"}' | \
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
    bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" notification claude proj \
    >/dev/null 2>&1 || fail "permission prompt should exit cleanly"
[[ ! -s "$state_dir/@1.@code_notify_running" ]] \
    || fail "permission prompt must pause the spinner"
[[ "$(window_name)" != "proj" && -s "$deliver_log" ]] \
    || fail "permission prompt must still badge and notify"
pass "approval requests still take priority over the spinner"

echo "All stop rate-limit badge tests passed"
