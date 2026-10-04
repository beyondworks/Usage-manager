#!/bin/bash
# Self-check of the Windows build, run in Git Bash on Windows — the shell Claude Code
# runs hook commands with. Every hook is invoked from the command written into the
# settings file, the way Claude Code would, against a disposable home (never the real
# one). The judgements themselves are covered by `cargo test`; this checks the wiring.
#   bash scripts/check.sh [path/to/UsageManager.exe]
set -euo pipefail
BIN="$(cygpath -m "$(realpath "${1:-$(dirname "$0")/../target/x86_64-pc-windows-gnu/release/UsageManager.exe}")")"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export USAGE_MANAGER_HOME="$(cygpath -w "$T")" USAGE_MANAGER_OFFLINE=1
fail() { echo "FAIL: $*"; exit 1; }
um() { "$BIN" "$@"; }
# setting statusLine.command  /  setting hooks.PreCompact.0.hooks.0.command
setting() { node -e 'let v=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));for(const k of process.argv[2].split("."))v=v?.[k];console.log(v)' "$(cygpath -w "$T/.claude/settings.json")" "$1"; }

mkdir -p "$T/.claude"
cat > "$T/.claude/settings.json" <<'EOF'
{"statusLine":{"type":"command","command":"cat >/dev/null; echo PREV-STATUS"},
 "env":{"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE":"72","KEEP_ME":"1"},
 "hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo user-hook"}]}]}}
EOF

um --hooks on | grep -q 'claude: true' || fail "install status"
grep -q 'echo user-hook' "$T/.claude/settings.json" || fail "user hook dropped"
um --hooks on >/dev/null
[ "$(grep -c -- '--prompt-hook' "$T/.claude/settings.json")" = 2 ] || fail "expected one prompt hook per event"

STATUS=$(setting statusLine.command)
PROMPT=$(setting hooks.PostToolUse.0.hooks.0.command)
GATE=$(setting hooks.PreCompact.0.hooks.0.command)
echo "  statusLine: $STATUS"

# statusLine: snapshot, chain the previous one, and feed the weekly row
SID=11111111-2222-3333-4444-555555555555
OUT=$(printf '{"session_id":"%s","context_window":{"context_window_size":200000},"rate_limits":{"seven_day":{"used_percentage":42,"resets_at":4102444800}}}' "$SID" | bash -c "$STATUS")
[ "$OUT" = "PREV-STATUS" ] || fail "previous statusLine not chained: '$OUT'"
[ -f "$T/.usage-manager/claude-status/$SID.json" ] || fail "no snapshot"
um --dump | grep -q 'quota Claude .anthropic.: weekly=42%' || fail "gauge did not read the snapshot"

# prompt hook: a queued notice, once
mkdir -p "$T/.usage-manager/alerts"
printf '"컨텍스트 90%% — SESSION_HANDOVER 갱신 후 마커"' > "$T/.usage-manager/alerts/$SID.txt"
OUT=$(printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$SID" | bash -c "$PROMPT")
echo "$OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")).hookSpecificOutput;process.exit(d.hookEventName=="PostToolUse"&&d.additionalContext.includes("SESSION_HANDOVER")?0:1)' \
  || fail "notice malformed: $OUT"
[ -z "$(printf '{"session_id":"%s","hook_event_name":"PostToolUse"}' "$SID" | bash -c "$PROMPT")" ] || fail "notice delivered twice"

# the gate: hold with exit 2, then the marker written with the instructed `touch` lets it through
GSID=33333333-cccc-dddd-eeee-ffffffffffff
TR="$T/gate.jsonl"
printf '{"type":"assistant","entrypoint":"cli","cwd":"C:\\\\work\\\\demo","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":900000}}}\n' > "$TR"
gate() { printf '{"session_id":"%s","hook_event_name":"PreCompact","trigger":"auto","transcript_path":"%s"}' "$GSID" "$(cygpath -m "$TR")" \
           | bash -c "$GATE" >/dev/null 2>&1; echo $?; }
[ "$(gate)" = 2 ] || fail "gate did not hold"
grep -q 'SESSION_HANDOVER' "$T/.usage-manager/alerts/$GSID.txt" || fail "gate left no notice"
HOME="$T" bash -c "touch ~/.usage-manager/pressed/$GSID"
[ "$(gate)" = 0 ] || fail "marker present but still held"
[ "$(cat "$T/.usage-manager/lastpass/$GSID")" = handover ] || fail "handover not recorded"

# sessions: a Windows transcript is listed with its folder name and size
mkdir -p "$T/.claude/projects/C--work-shop"
printf '{"type":"assistant","entrypoint":"cli","cwd":"C:\\\\work\\\\shop","timestamp":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":450000}}}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" > "$T/.claude/projects/C--work-shop/aaaabbbb-0000.jsonl"
um --dump | grep -q 'session\[aaaabb\] Claude Code shop 45% 450010/1000000' || fail "session not listed: $(um --dump | grep session)"

um --hooks off | grep -q 'claude: false' || fail "uninstall status"
[ "$(setting statusLine.command)" = "cat >/dev/null; echo PREV-STATUS" ] || fail "statusLine not restored"
[ "$(setting env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)" = 72 ] || fail "compaction point not restored"
grep -q UsageManager "$T/.claude/settings.json" && fail "our hooks left behind"

echo "OK windows"
