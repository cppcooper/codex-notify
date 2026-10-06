#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

wait_for_lines() {
    local file="$1"
    local expected_lines="$2"

    for _ in $(seq 1 40); do
        if [[ -f "$file" ]] && [[ $(wc -l < "$file") -ge "$expected_lines" ]]; then
            return 0
        fi
        sleep 0.05
    done

    return 1
}

run_codex_notifier() {
    local fake_path="$1"
    local payload="$2"

    PATH="$fake_path" \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
    CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=180 \
    bash "$NOTIFIER" codex "$payload"
}

write_codex_thread_metadata() {
    local thread_id="$1"
    local originator="$2"
    local source="${3:-vscode}"

    python3 - "$HOME/.codex/state_5.sqlite" "$HOME/.codex/sessions" "$thread_id" "$originator" "$source" <<'PY'
import json
import pathlib
import sqlite3
import sys

db_path = pathlib.Path(sys.argv[1])
sessions_dir = pathlib.Path(sys.argv[2])
thread_id = sys.argv[3]
originator = sys.argv[4]
source = sys.argv[5]

rollout_path = sessions_dir / f"{thread_id}.jsonl"
rollout_path.parent.mkdir(parents=True, exist_ok=True)
rollout_path.write_text(
    json.dumps(
        {
            "type": "session_meta",
            "payload": {
                "id": thread_id,
                "originator": originator,
                "source": source,
            },
        }
    )
    + "\n",
    encoding="utf-8",
)

with sqlite3.connect(db_path) as conn:
    cur = conn.cursor()
    cur.execute(
        """
        create table if not exists threads (
            id text primary key,
            source text,
            rollout_path text
        )
        """
    )
    cur.execute(
        "insert or replace into threads (id, source, rollout_path) values (?, ?, ?)",
        (thread_id, source, str(rollout_path)),
    )
    conn.commit()
PY
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CODEX_HOME="$HOME/.codex"
export CODE_NOTIFY_TAIL_SYNC=1
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
sound_file="$test_dir/custom.aiff"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$HOME/.codex" "$fake_bin" "$log_dir"

touch "$sound_file"
: > "$HOME/.claude/notifications/sound-enabled"
printf '%s\n' "$sound_file" > "$HOME/.claude/notifications/sound-custom"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        sound_log="$log_dir/afplay.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/afplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        sound_log="$log_dir/paplay.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/paplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for Codex notify test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"
(
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    enable_codex_hooks
)
run_attention_notifier() {
    printf '%s' "$1" | PATH="$fake_path" CODE_NOTIFY_CODEX_ATTENTION=1 bash "$NOTIFIER" notification codex
}
set_alerts() {
    printf '%s\n' "$1" > "$HOME/.claude/notifications/notify-types"
}

run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","cwd":"/tmp/demo","client":"codex-exec","input-messages":["Run tests"],"last-assistant-message":"All tests passed"}'
run_codex_notifier "$fake_path" '{"type":"request_permissions","cwd":"/tmp/demo","tool":"exec_command"}'
run_codex_notifier "$fake_path" '{"type":"approval_requested","cwd":"/tmp/demo","tool":"exec_command"}'
run_codex_notifier "$fake_path" '{"type":"approval_requested","cwd":"/tmp/demo","tool":"exec_command"}'
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","cwd":"/tmp/demo","client":"codex-app","last-assistant-message":"Desktop event"}'

write_codex_thread_metadata "desktop-thread" "Codex Desktop"
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","thread-id":"desktop-thread","cwd":"/tmp/demo","client":"codex-exec","last-assistant-message":"Desktop-backed event"}'

write_codex_thread_metadata "cli-thread" "Codex CLI" "shell"
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","thread-id":"cli-thread","cwd":"/tmp/demo","client":"codex-exec","last-assistant-message":"CLI event still notifies"}'

run_codex_notifier "$fake_path" '{"last-assistant-message":"No completion type"}'
run_codex_notifier "$fake_path" '{"type":"error","last-assistant-message":"permission requested"}'
run_codex_notifier "$fake_path" 'malformed'
printf '%s' '{"hook_event_name":"PermissionRequest","type":"permission_prompt"}' | PATH="$fake_path" bash "$NOTIFIER" notification codex

[[ $(wc -l < "$notification_log") -eq 2 ]] || fail "unknown, early approval or desktop events notified"
pass "Only explicit Codex completion events notify; early approvals stay silent"

run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 2 ]] || fail "approval alerted while disabled"
set_alerts "permission_prompt"
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 4 ]] || fail "repeated human approvals were rate-limited"
set_alerts "idle_prompt"
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
run_attention_notifier '{"type":"ask_user","cwd":"/tmp/demo","tool_input":{"questions":[{"question":"Which option?"}]}}'
[[ $(wc -l < "$notification_log") -eq 4 ]] || fail "removed approval or disabled question alerted"
set_alerts "ask_user"
run_attention_notifier '{"type":"ask_user","cwd":"/tmp/demo","tool_input":{"questions":[{"question":"Which option?"}]}}'
run_attention_notifier '{"type":"ask_user","cwd":"/tmp/demo","tool_input":{"questions":[{"question":"Which option?"}]}}'
wait_for_lines "$sound_log" 6 || fail "expected shared sound delivery for all six alerts"
[[ $(wc -l < "$notification_log") -eq 6 ]] || fail "blocking questions were rate-limited"
grep -q "Task Complete - demo" "$notification_log" || fail "completion UX changed"
grep -q "Input Required - demo" "$notification_log" || fail "approval UX changed"
grep -q "Question" "$notification_log" || fail "question UX not reused"
grep -q "Which option?" "$notification_log" || fail "question text was lost"

set_alerts "permission_prompt|ask_user"
run_attention_notifier '{"type":"permission_prompt","thread-id":"desktop-thread","client":"codex-cli","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 7 ]] || fail "CLI request from a Desktop-created thread was suppressed"
: > "$HOME/.claude/notifications/disabled"
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
run_attention_notifier '{"type":"ask_user","cwd":"/tmp/demo","tool_input":{"questions":[{"question":"Which option?"}]}}'
[[ $(wc -l < "$notification_log") -eq 7 ]] || fail "global kill switch ignored"
rm "$HOME/.claude/notifications/disabled"
(
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    disable_codex_hooks
)
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 7 ]] || fail "cn off codex ignored"
pass "Confirmed requests reuse question/approval delivery and honor live alert settings and disablement"

(
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    enable_codex_hooks
)
printf '%s' '{"hook_event_name":"Stop","cwd":"/tmp/native-project","last_assistant_message":"Approval work is finished"}' | \
    PATH="$fake_path" CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 bash "$NOTIFIER" stop codex
[[ $(wc -l < "$notification_log") -eq 8 ]] || fail "native Stop hook did not deliver completion"
grep -q "Task Complete - native-project" "$notification_log" || fail "native completion lost its project context"
pass "Native Codex Stop hooks retain completion and project context"

run_alerts_command() {
    PATH="$fake_path" CODE_NOTIFY_COMMAND_NAME=cn bash "$SCRIPT_DIR/../bin/code-notify" alerts "$@" > /dev/null
}
run_approval_request() {
    printf '%s' "$1" | PATH="$fake_path" bash "$NOTIFIER" ApprovalRequest codex
}

original_hooks=$(cat "$CODEX_HOME/hooks.json")
printf '%s' "$original_hooks" > "$test_dir/original-hooks.json"
original_config=$(cat "$CODEX_HOME/config.toml")
# Simulate upgrading a working install without the new dispatcher. The normal
# alert command must repair it, retaining the user's TOML and existing hooks.
python3 - "$CODEX_HOME/hooks.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data['hooks'].pop('PermissionRequest')
with open(path, 'w') as f:
    json.dump(data, f)
PY
run_alerts_command add approval-request
python3 - "$test_dir/original-hooks.json" "$CODEX_HOME/hooks.json" <<'PY'
import json, os, sys
def normalized(path):
    with open(path) as f:
        data = json.load(f)
    for entries in data['hooks'].values():
        for entry in entries:
            for hook in entry['hooks']:
                path, event, tool = hook['command'].rsplit(' ', 2)
                hook['command'] = ' '.join([os.path.normpath(path), event, tool])
    return data
assert normalized(sys.argv[1]) == normalized(sys.argv[2]), 'missing dispatcher was not restored'
PY
original_hooks=$(cat "$CODEX_HOME/hooks.json")
[[ "$(cat "$CODEX_HOME/config.toml")" == "$original_config" ]] || fail "alert upgrade changed unrelated TOML"
grep -q 'approval_request' "$HOME/.claude/notifications/notify-types" || fail "approval-request alias was not normalized"

run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo","autoAccepted":true}'
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
printf '%s' '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}' | PATH="$fake_path" bash "$NOTIFIER" notification codex
run_codex_notifier "$fake_path" '{"type":"approval_requested","cwd":"/tmp/demo","autoAccepted":true}'
run_codex_notifier "$fake_path" '{"type":"unknown","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 12 ]] || fail "all-request opt-in omitted an early/auto-accepted request or rate-limited it"
grep -q "Approval Requested - demo" "$notification_log" || fail "early approval alert was not labeled distinctly"
pass "All-request opt-in reports early and automatically resolved approvals, including legacy dispatchers"

run_alerts_command remove permission_prompt
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 12 ]] || fail "early opt-in implicitly enabled human-wait alerts"
run_alerts_command add permission_prompt
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 13 ]] || fail "early alerts suppressed a confirmed human wait"
run_alerts_command remove approval_request
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
printf '%s' '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}' | PATH="$fake_path" bash "$NOTIFIER" notification codex
run_codex_notifier "$fake_path" '{"type":"request_permissions","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 13 ]] || fail "removing the opt-in did not immediately silence early requests"
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 14 ]] || fail "removing the early opt-in disabled confirmed waits"
[[ "$(cat "$CODEX_HOME/hooks.json")" == "$original_hooks" ]] || fail "alert toggles rewrote installed hooks"
[[ "$(cat "$CODEX_HOME/config.toml")" == "$original_config" ]] || fail "alert toggles rewrote unrelated TOML"
pass "Both approval alert types are independent; live toggles preserve installed hooks and unrelated settings"

run_alerts_command add approval_request
: > "$HOME/.claude/notifications/disabled"
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
rm "$HOME/.claude/notifications/disabled"
printf '%s\n' "$(( $(date +%s) + 60 ))" > "$HOME/.claude/notifications/snooze-until"
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
rm "$HOME/.claude/notifications/snooze-until"
[[ $(wc -l < "$notification_log") -eq 14 ]] || fail "early requests ignored global disablement or snooze"

run_alerts_command persist add approval-request
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 15 ]] || fail "persistent approval-request alert was lost"
if [[ "$(uname -s)" == "Linux" ]]; then
    tail -n 1 "$notification_log" | grep -q -- '--urgency=critical' || fail "early opt-in did not reuse persistence"
fi
(
    source "$SCRIPT_DIR/../lib/code-notify/utils/sound.sh"
    [[ "$(sound_event_candidates ApprovalRequest)" == "permission question" ]]
) || fail "early approval did not reuse permission sounds"
wait_for_lines "$sound_log" 15 || fail "early requests did not reuse shared sound delivery"
run_alerts_command reset
[[ "$(cat "$HOME/.claude/notifications/notify-types")" == "idle_prompt" ]] || fail "reset did not remove the opt-in"
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
run_attention_notifier '{"type":"permission_prompt","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 15 ]] || fail "reset did not silence both approval types"

# With the opt-in off, no utility sourcing, JSON parser, or other external
# command should be needed by the synchronous PermissionRequest hook.
fast_output=$(PATH="$test_dir/no-commands" "$BASH" "$NOTIFIER" ApprovalRequest codex 2>&1)
[[ -z "$fast_output" ]] || fail "disabled early hook attempted to run external commands"
pass "Early alerts reuse sound, persistence and snooze; reset restores the lightweight disabled path"

(
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    disable_codex_hooks
)
run_alerts_command add approval_request
run_approval_request '{"hook_event_name":"PermissionRequest","cwd":"/tmp/demo"}'
[[ $(wc -l < "$notification_log") -eq 15 ]] || fail "all-request setting bypassed cn off codex"
if grep -q 'ApprovalRequest codex' "$CODEX_HOME/hooks.json"; then
    fail "changing alerts re-enabled disabled Codex hooks"
fi
pass "The opt-in honors cn off codex and does not enable disabled tool hooks"

# This is the live PostToolUse shape from a normal-mode question: the tool
# returns a JSON string after displaying the prompt, without blocking the turn.
async_question='{"hook_event_name":"PostToolUse","tool_name":"request_user_input_async","tool_use_id":"async-one","cwd":"/tmp/async-demo","session_id":"async-thread","tool_input":{"questions":[{"title":"Which café?","options":["One","Two"]}]},"tool_response":"{\"accepted\":true}"}'
run_async_question() {
    printf '%s' "${1:-$async_question}" | PATH="$fake_path" bash "$NOTIFIER" PostToolUse codex
}
async_count=$(wc -l < "$notification_log")
run_async_question
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "disabled ask_user alerted"
(
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    enable_codex_hooks
)
async_hooks=$(cat "$CODEX_HOME/hooks.json")
async_config=$(cat "$CODEX_HOME/config.toml")
run_alerts_command add ask_user

async_trace=$(printf '%s' "$async_question" | PATH="$fake_path" bash -x "$NOTIFIER" PostToolUse codex 2>&1)
async_count=$((async_count + 1))
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "accepted normal-mode question did not notify"
tail -n 1 "$notification_log" | grep -q 'Which café?' || fail "normal-mode question title was lost"
tail -n 1 "$notification_log" | grep -q 'Question - async-demo' || fail "normal-mode question did not reuse the question UX"
if printf '%s' "$async_trace" | grep -qE '^\++ tmux_running_(pause_for_input|stop)( |$)'; then
    fail "async question stopped Codex's running indicator"
fi
run_async_question "${async_question/async-one/async-two}"
async_count=$((async_count + 1))
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "separate normal-mode questions were rate-limited"

# Test the fallback parser against the same captured result. Restrict only
# command discovery for jq; all other commands and shared delivery stay real.
(
    command() {
        if [[ "$1" == "-v" && "${2:-}" == "jq" ]]; then return 1; fi
        builtin command "$@"
    }
    export -f command
    run_async_question "${async_question/async-one/async-python}"
)
async_count=$((async_count + 1))
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "Python fallback lost the normal-mode question"

python3 - "$async_question" <<'PYASYNC' > "$test_dir/unaccepted-questions.jsonl"
import json, sys
event = json.loads(sys.argv[1])
for response in ('{"accepted":false}', '{"accepted":1}', 'malformed', None):
    print(json.dumps({**event, "tool_response": response}))
print(json.dumps({**event, "tool_input": {"questions": []}}))
print(json.dumps({**event, "tool_input": {"questions": [{"title": None}]}}))
print(json.dumps({**event, "tool_name": "Bash"}))
PYASYNC
while IFS= read -r rejected; do
    run_async_question "$rejected"
done < "$test_dir/unaccepted-questions.jsonl"
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "unaccepted or unrelated tool events alerted"

# Ordinary PostToolUse events must retain their lightweight resume path.
ordinary_trace=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"pwd"}}' | PATH="$fake_path" bash -x "$NOTIFIER" PostToolUse codex 2>&1)
if printf '%s' "$ordinary_trace" | grep -qE '^\++ (source|jq|python3)( |$)'; then
    fail "ordinary tool hooks started a parser or sourced notification utilities"
fi
run_alerts_command remove ask_user
run_async_question
run_alerts_command add ask_user
: > "$HOME/.claude/notifications/disabled"
run_async_question
rm "$HOME/.claude/notifications/disabled"
printf '%s\n' "$(( $(date +%s) + 60 ))" > "$HOME/.claude/notifications/snooze-until"
run_async_question
rm "$HOME/.claude/notifications/snooze-until"
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "async questions ignored alert removal, disablement or snooze"
[[ "$(cat "$CODEX_HOME/hooks.json")" == "$async_hooks" ]] || fail "async alert changes rewrote hooks"
[[ "$(cat "$CODEX_HOME/config.toml")" == "$async_config" ]] || fail "async alert changes rewrote unrelated TOML"

run_alerts_command persist add ask_user
run_alerts_command persist timeout 0
run_async_question
async_count=$((async_count + 1))
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "persistent normal-mode question was lost"
if [[ "$(uname -s)" == "Linux" ]]; then
    tail -n 1 "$notification_log" | grep -q -- '--urgency=critical' || fail "async question did not reuse persistence"
    tail -n 1 "$notification_log" | grep -q -- '--expire-time=0' || fail "async question did not reuse persistence timeout"
fi
wait_for_lines "$sound_log" "$async_count" || fail "async questions did not reuse shared sound delivery"
(
    source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
    disable_codex_hooks
)
run_async_question
[[ $(wc -l < "$notification_log") -eq "$async_count" ]] || fail "async question bypassed cn off codex"
pass "Normal-mode questions notify only after acceptance, reuse shared delivery, and honor live settings without pausing Codex"
