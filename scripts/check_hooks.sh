#!/bin/bash
# Self-check for the agent hooks, run against a disposable HOME (never the real one).
#   install keeps the user's own statusLine + hooks, snapshots statusLine input,
#   feeds the weekly gauge, delivers a queued notice once, and uninstall restores.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$ROOT/.build/debug/UsageManager}"
export USAGE_MANAGER_OFFLINE=1   # local file readers only; no live account lookups
T="$(mktemp -d "${TMPDIR:-/tmp}/um-check.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

mkdir -p "$T/.claude" "$T/.codex"
cat > "$T/.claude/settings.json" <<'EOF'
{"statusLine":{"type":"command","command":"cat >/dev/null; echo PREV-STATUS # other-statusline.sh"},
 "hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}
EOF
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo codex-stop"}]}]}}' > "$T/.codex/hooks.json"
chmod 600 "$T/.codex/hooks.json"

HOME="$T" "$BIN" --hooks on | grep -q 'claude: true, codex: true' || fail "install status"
grep -q 'echo user-hook' "$T/.claude/settings.json" || fail "user hook dropped"
grep -q 'codex-stop' "$T/.codex/hooks.json" || fail "codex hook dropped"
[ "$(stat -f %Lp "$T/.codex/hooks.json")" = 600 ] || fail "hooks.json permissions changed"
HOME="$T" "$BIN" --hooks on >/dev/null   # idempotent
[ "$(grep -c ctx-hook.sh "$T/.claude/settings.json")" = 2 ] || fail "expected one hook per event, no duplicates"
for ev in UserPromptSubmit PostToolUse; do
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if any('ctx-hook' in json.dumps(g) for g in d['hooks'][sys.argv[2]]) else 1)" "$T/.claude/settings.json" $ev || fail "claude $ev hook missing"
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if any('ctx-hook' in json.dumps(g) for g in d['hooks'][sys.argv[2]]) else 1)" "$T/.codex/hooks.json" $ev || fail "codex $ev hook missing"
done

# statusLine: replaced even when the old command shares our file name, snapshot + chain
SID=11111111-2222-3333-4444-555555555555
IN='{"session_id":"'$SID'","context_window":{"context_window_size":200000},"rate_limits":{"seven_day":{"used_percentage":42,"resets_at":4102444800}}}'
CMD=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$T/.claude/settings.json")
OUT=$(printf '%s' "$IN" | HOME="$T" sh -c "$CMD")
[ "$OUT" = "PREV-STATUS" ] || fail "previous statusLine not chained: $OUT"
[ -f "$T/.usage-manager/claude-status/$SID.json" ] || fail "no snapshot"
HOME="$T" "$BIN" --dump | grep -q 'quota Claude .anthropic.: weekly=42%' || fail "gauge did not read snapshot"

# prompt hook: delivers a queued notice exactly once, on either event
mkdir -p "$T/.usage-manager/alerts"
probe() {  # probe <session-id> <event> -> hook stdout
  printf '{"session_id":"%s","hook_event_name":"%s"}' "$1" "$2" \
    | HOME="$T" /bin/sh "$T/.usage-manager/bin/ctx-hook.sh"
}
arm() { printf '%s' "$1" > "$T/.usage-manager/alerts/$SID.txt"; }

# PostToolUse: reaches a long autonomous run that sends no prompt
arm '"컨텍스트 90% — /raw-press 후 /compact"'
OUT=$(probe "$SID" PostToolUse)
echo "$OUT" | python3 -c "import json,sys;d=json.load(sys.stdin)['hookSpecificOutput'];sys.exit(0 if d['hookEventName']=='PostToolUse' and 'raw-press' in d['additionalContext'] else 1)" \
  || fail "PostToolUse notice malformed: $OUT"
[ -z "$(probe "$SID" PostToolUse)" ] || fail "notice delivered twice"

# UserPromptSubmit: same file, event name echoed back from stdin
arm '"두 번째"'
probe "$SID" UserPromptSubmit | grep -q '"hookEventName":"UserPromptSubmit"' || fail "UserPromptSubmit notice malformed"

arm '"세 번째"'
[ -z "$(probe ../x PostToolUse)" ] || fail "unsafe id accepted"

# end to end: the app itself spots a session over the threshold and queues the notice
SID2=99999999-8888-7777-6666-555555555555
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
mkdir -p "$T/.claude/projects/-tmp-demo"
printf '%s\n' "{\"type\":\"assistant\",\"entrypoint\":\"cli\",\"cwd\":\"/tmp/demo\",\"timestamp\":\"$now\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":980000}}}" \
  > "$T/.claude/projects/-tmp-demo/$SID2.jsonl"   # 98% of a 1M window: over any allowed threshold
HOME="$T" "$BIN" > "$T/app.log" 2>&1 &
APP=$!
for _ in $(seq 1 40); do [ -f "$T/.usage-manager/alerts/$SID2.txt" ] && break; sleep 0.5; done
kill $APP 2>/dev/null || true; wait $APP 2>/dev/null || true
[ -f "$T/.usage-manager/alerts/$SID2.txt" ] || fail "app did not queue a notice for a 98% session"
grep -q 'raw-press' "$T/.usage-manager/alerts/$SID2.txt" || fail "queued notice lacks the raw-press instruction"
probe "$SID2" PostToolUse | grep -q 'raw-press' || fail "app-queued notice not delivered to the agent"
grep -q '\[notify\]' "$T/app.log" || fail "no push fired"

# model-level alert filter: Codex hosts both GPT (258k window) and Kimi (996k), so a
# Codex thread is alerted only when it runs Kimi.
codex_session() {  # codex_session <session-id> <model>
  d="$T/.codex/sessions/$(date -u +%Y/%m/%d)"; mkdir -p "$d"
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  { printf '{"type":"session_meta","payload":{"session_id":"%s","cwd":"/tmp/demo"}}\n' "$1"
    printf '{"type":"turn_context","payload":{"model":"%s"}}\n' "$2"
    printf '{"timestamp":"%s","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":980000},"model_context_window":1000000}}}\n' "$ts"
  } > "$d/rollout-$1.jsonl"
}
GPT=11111111-aaaa-bbbb-cccc-dddddddddddd
KIMI=22222222-aaaa-bbbb-cccc-dddddddddddd
codex_session "$GPT" "gpt-6-astra"
codex_session "$KIMI" "kimi/k3[1m]"
rm -f "$T/.usage-manager/alerts/"*.txt
HOME="$T" "$BIN" > "$T/app2.log" 2>&1 &
APP=$!
for _ in $(seq 1 40); do [ -f "$T/.usage-manager/alerts/$KIMI.txt" ] && break; sleep 0.5; done
kill $APP 2>/dev/null || true; wait $APP 2>/dev/null || true
[ -f "$T/.usage-manager/alerts/$KIMI.txt" ] || fail "Kimi session at 98% got no notice"
[ ! -f "$T/.usage-manager/alerts/$GPT.txt" ] || fail "GPT-model Codex session should not be alerted"
grep -q "ctx-$GPT" "$T/app2.log" && fail "GPT-model session pushed a notification"

HOME="$T" "$BIN" --hooks off | grep -q 'claude: false, codex: false' || fail "uninstall status"
grep -q 'PREV-STATUS' "$T/.claude/settings.json" || fail "statusLine not restored"
grep -q 'echo user-hook' "$T/.claude/settings.json" || fail "user hook lost on uninstall"
! grep -q ctx-hook "$T/.codex/hooks.json" || fail "codex hook left behind"
echo "OK hooks"
