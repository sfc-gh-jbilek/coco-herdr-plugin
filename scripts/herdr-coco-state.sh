#!/usr/bin/env bash
# Report Cortex Code lifecycle state to Herdr.
# Does nothing outside a Herdr pane. Never fails the CoCo turn.
# Shipped by the "herdr" CoCo plugin. Invoked via ${CLAUDE_PLUGIN_ROOT}.
set -u

# Guard: act only inside a Herdr-managed pane.
[ "${HERDR_ENV:-}" = "1" ]   || exit 0
[ -n "${HERDR_PANE_ID:-}" ]  || exit 0
[ -n "${HERDR_BIN_PATH:-}" ] || exit 0
[ -x "${HERDR_BIN_PATH}" ]   || exit 0

SOURCE="custom:coco"
AGENT="coco"

# Monotonic sequence per pane. Herdr ignores a report whose --seq is not
# greater than the last one accepted for the same --source, and it keeps
# that value for the life of the server. A per-session counter that restarts
# at 1 is therefore ignored by every session after the first in a pane.
# Use a millisecond timestamp, bumped past the stored value if the clock
# has not advanced, so the sequence rises across sessions and restarts.
SEQ_DIR="${TMPDIR:-/tmp}/herdr-coco"
# The log can hold prompt text, so create the directory private to this user.
[ -d "$SEQ_DIR" ] || (umask 077; mkdir -p "$SEQ_DIR") 2>/dev/null || true
SEQ_FILE="$SEQ_DIR/seq.$HERDR_PANE_ID"
LOCK_DIR="$SEQ_FILE.lock"
# Per-pane event log for troubleshooting ($coco-herdr-plugin:doctor reads it).
LOG_FILE="$SEQ_DIR/events.$HERDR_PANE_ID.log"

herdr_call() {
  # Runs Herdr and records a failure in the log so $coco-herdr-plugin:doctor can see it.
  # The exit code is never propagated. Callers always pass "pane <subcommand>"
  # first, so $2 is the subcommand named in the log line.
  local rc=0
  "$HERDR_BIN_PATH" "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && return 0
  printf '%s   herdr %s failed rc=%s\n' "$(date '+%H:%M:%S')" "$2" "$rc" >> "$LOG_FILE" 2>/dev/null || true
}

# Watcher mode, started detached by SessionEnd: "__watch <cortex pid> <seq>".
# Releases the row once the Cortex process exits. Exits without releasing once
# the seq file holds a value above the reserved seq (a later hook event ran) or
# is gone. A non-numeric read is retried on the next tick. Lifetime cap: 24 h.
if [ "${1:-}" = "__watch" ]; then
  WPID=${2:-} WSEQ=${3:-}
  case "$WPID" in ''|*[!0-9]*) exit 0 ;; esac
  case "$WSEQ" in ''|*[!0-9]*) exit 0 ;; esac
  trap '' HUP
  n=0
  while [ "$n" -lt 86400 ]; do
    [ -e "$SEQ_FILE" ] || exit 0
    CUR=$(cat "$SEQ_FILE" 2>/dev/null)
    case "$CUR" in ''|*[!0-9]*) : ;; *) [ "$CUR" -gt "$WSEQ" ] 2>/dev/null && exit 0 ;; esac
    if ! kill -0 "$WPID" 2>/dev/null; then
      # Bound the release (~10 s) so a stuck herdr cannot keep the watcher alive.
      herdr_call pane release-agent "$HERDR_PANE_ID" --source "$SOURCE" --agent "$AGENT" --seq "$WSEQ" &
      HP=$! i=0
      while kill -0 "$HP" 2>/dev/null; do
        i=$(( i + 1 ))
        if [ "$i" -gt 100 ]; then
          kill "$HP" 2>/dev/null
          printf '%s   herdr release-agent timed out\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE" 2>/dev/null
          break
        fi
        sleep 0.1 2>/dev/null || break
      done
      exit 0
    fi
    sleep 1 2>/dev/null || exit 0
    n=$(( n + 1 ))
  done
  exit 0
fi

seq_lock() {
  # Serializes seq allocation per pane. mkdir is atomic. After ~2 s the lock is
  # taken over as stale, so a hook never waits longer than that.
  # LOCKED is set only when this hook holds the lock, so it never removes
  # another hook's lock.
  [ -d "$SEQ_DIR" ] && [ -w "$SEQ_DIR" ] || return 0
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$(( i + 1 ))
    if [ "$i" -ge 40 ]; then
      rmdir "$LOCK_DIR" 2>/dev/null; mkdir "$LOCK_DIR" 2>/dev/null && LOCKED=1
      return 0
    fi
    sleep 0.05 2>/dev/null || return 0
  done
  LOCKED=1
}
LOCKED=

PAYLOAD=$(cat 2>/dev/null || true)

# Parse the payload. python3 is preferred: one call emits the four fields
# separated by the ASCII unit separator (0x1F), and the shell never evaluates
# payload text. Defaults are set first so a failed parse leaves them empty.
EVENT= SESSION_ID= TOOL_NAME= MESSAGE=
if command -v python3 >/dev/null 2>&1; then
  FIELDS=$(printf '%s' "$PAYLOAD" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
def f(k):
    v = d.get(k)
    if isinstance(v, (dict, list)):
        v = json.dumps(v)
    return "" if v is None else str(v).replace("\x1f", " ")
sys.stdout.write("\x1f".join(f(k) for k in ("hook_event_name","session_id","tool_name","message")))
' 2>/dev/null || true)
  IFS=$'\x1f' read -r -d '' EVENT SESSION_ID TOOL_NAME MESSAGE <<< "$FIELDS" || true
  # The here-string adds a trailing newline to the last field read.
  MESSAGE=${MESSAGE%$'\n'}
  EVENT=${EVENT%$'\n'}
else
  # Fallback without python3: take the first "key":"value" match for each
  # simple field. Values are limited to a safe charset below, so payload text
  # cannot smuggle an option or a state. The free-text message is not parsed.
  simple_field() {
    printf '%s' "$PAYLOAD" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[A-Za-z0-9_.:-]*\"" 2>/dev/null \
      | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'
  }
  EVENT=$(simple_field hook_event_name)
  SESSION_ID=$(simple_field session_id)
  TOOL_NAME=$(simple_field tool_name)
  MESSAGE='# python3 absent, message not parsed'
fi

# Values that become argv elements must not look like options.
case "$SESSION_ID" in *[!A-Za-z0-9_.:-]*|-*) SESSION_ID= ;; esac
case "$TOOL_NAME"  in *[!A-Za-z0-9_.:-]*|-*) TOOL_NAME= ;; esac

[ -n "$EVENT" ] || EVENT="${1:-}"

seq_lock
LAST=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
# Millisecond clock without python3: bash 5 exposes EPOCHREALTIME; older bash
# falls back to whole seconds * 1000. Same-second events get LAST + 1.
if [ -n "${EPOCHREALTIME:-}" ]; then
  T=${EPOCHREALTIME/,/.}
  F=${T#*.}000            # pad so a short fraction still yields 3 digits
  NOW=$(( ${T%.*} * 1000 + 10#${F:0:3} ))
else
  NOW=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
fi
if [ "$NOW" -gt "$LAST" ] 2>/dev/null; then SEQ=$NOW; else SEQ=$(( 10#$LAST + 1 )); fi
# SessionEnd stores its reserved release seq (SEQ + 1) in the same lock hold, so
# no concurrent event can allocate a value at or below it.
STORE=$SEQ; [ "$EVENT" = SessionEnd ] && STORE=$(( SEQ + 1 ))
# Temp file + rename, so a reader never sees a partial value.
printf '%s' "$STORE" > "$SEQ_FILE.tmp.$$" 2>/dev/null && mv -f "$SEQ_FILE.tmp.$$" "$SEQ_FILE" 2>/dev/null || true
[ -n "$LOCKED" ] && { rmdir "$LOCK_DIR" 2>/dev/null || true; }

printf '%s %s tool=%s [plugin]\n' "$(date '+%H:%M:%S')" "$EVENT" "$TOOL_NAME" >> "$LOG_FILE" 2>/dev/null || true
[ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 400 ] && tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null

# Flags from the live Cortex process that a restarted session must keep.
# --profile is also stored on the session; --bypass and --no-auto-update are
# not. Anything else on the argv (a prompt, a path) is left out.
resume_flags() {
  command -v python3 >/dev/null 2>&1 || return 0
  "$HERDR_BIN_PATH" pane process-info --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
import json, re, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(0)
info = (d.get("result") or {}).get("process_info") or {}
argv = None
for proc in reversed(info.get("foreground_processes") or []):
    name = proc.get("name") or ""
    argv0 = proc.get("argv0") or ""
    if name in ("cortex", "cortex.exe") or argv0 in ("cortex", "cortex.exe") or name.endswith("/cortex"):
        argv = proc.get("argv") or []
        break
if not argv:
    sys.exit(0)
bools = {"--bypass", "--no-auto-update"}
vals = {"--profile"}
safe = []
i = 1
while i < len(argv):
    a = argv[i]
    if a in bools:
        safe.append(a)
        i += 1
        continue
    if a in vals and i + 1 < len(argv) and re.fullmatch(r"[A-Za-z0-9_.:-]+", argv[i + 1] or ""):
        safe.extend([a, argv[i + 1]])
        i += 2
        continue
    i += 1
sys.stdout.write("\x1f".join(safe))
' 2>/dev/null || true
}

report() {
  # $1 = state, $2 = optional message
  local state="$1" msg="${2:-}" extra
  local args=( pane report-agent "$HERDR_PANE_ID"
               --source "$SOURCE" --agent "$AGENT"
               --state "$state" --seq "$SEQ" )
  [ -n "$SESSION_ID" ] && args+=( --agent-session-id "$SESSION_ID" )
  # $msg can contain tool output. It is always one quoted argv element.
  [ -n "$msg" ] && args+=( --message "$msg" )
  # Herdr relaunches this command in the pane after a server restart.
  # The first element has to be a plain command name.
  if [ -n "$SESSION_ID" ]; then
    args+=( -- cortex )
    extra=$(resume_flags)
    if [ -n "$extra" ]; then
      IFS=$'\x1f' read -r -a extra_flags <<< "$extra"
      args+=( "${extra_flags[@]}" )
    fi
    args+=( --resume "$SESSION_ID" )
  fi
  herdr_call "${args[@]}"
}

# Cortex writes the conversation title as an OSC title, "<title> (cortex)".
# Herdr shows that on the tab only after a rename. Until then, and again after
# a row is released, the label stays the process name. Rename from the OSC
# title when the label is still that placeholder, or still the name this pane
# set last. A tab that holds another pane is left alone.
rename_tab_from_title() {
  local raw parsed base tab_id rawtab label panes lastf last
  command -v python3 >/dev/null 2>&1 || return 0
  raw=$("$HERDR_BIN_PATH" pane get "$HERDR_PANE_ID" 2>/dev/null) || return 0
  [ -n "$raw" ] || return 0
  parsed=$(printf '%s' "$raw" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(0)
p = (d.get("result") or {}).get("pane") or d.get("pane") or {}
title = (p.get("terminal_title_stripped") or p.get("terminal_title") or "").strip()
suffix = " (cortex)"
if title.endswith(suffix):
    title = title[: -len(suffix)].strip()
title = re.sub(r"^[^0-9A-Za-z]+", "", title).strip()
if not title or title.lower() in ("cortex", "coco"):
    sys.exit(0)
limit = 48
if len(title) > limit:
    cut = title[:limit]
    sp = cut.rfind(" ")
    title = (cut[:sp] if sp >= 24 else cut).rstrip()
tab = p.get("tab_id") or ""
if not tab or not title or title.startswith("-"):
    sys.exit(0)
sys.stdout.write(title + "\x1f" + tab)
' 2>/dev/null) || return 0
  [ -n "$parsed" ] || return 0
  IFS=$'\x1f' read -r base tab_id <<< "$parsed"
  [ -n "$base" ] && [ -n "$tab_id" ] || return 0
  rawtab=$("$HERDR_BIN_PATH" tab get "$tab_id" 2>/dev/null) || return 0
  label=$(printf '%s' "$rawtab" | python3 -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(0)
t = (d.get("result") or {}).get("tab") or d.get("tab") or {}
sys.stdout.write((t.get("label") or "") + "\x1f" + str(t.get("pane_count") or ""))
' 2>/dev/null) || return 0
  panes=${label#*$'\x1f'}
  label=${label%%$'\x1f'*}
  # A shared tab has one label. Renaming it would retitle the other pane.
  [ "$panes" = "1" ] || return 0
  lastf="$SEQ_DIR/tabname.$HERDR_PANE_ID"
  last=$(cat "$lastf" 2>/dev/null || true)
  if [ "$label" = "$base" ]; then
    printf '%s' "$base" > "$lastf" 2>/dev/null || true
    return 0
  fi
  case "$label" in
    ""|cortex|coco) ;;
    *)
      case "$label" in
        *[!0-9]*) [ "$label" = "$last" ] || return 0 ;;
      esac
      ;;
  esac
  "$HERDR_BIN_PATH" tab rename "$tab_id" "$base" >/dev/null 2>&1 || {
    printf '%s   herdr tab rename failed\n' "$(date '+%H:%M:%S')" >> "$LOG_FILE" 2>/dev/null || true
    return 0
  }
  printf '%s' "$base" > "$lastf" 2>/dev/null || true
  printf '%s   tab rename -> %.80s\n' "$(date '+%H:%M:%S')" "$base" >> "$LOG_FILE" 2>/dev/null || true
}

# PID the SessionEnd watcher should follow. Cortex runs the hook under a
# short-lived child that is not an ancestor of the Cortex process, so $PPID
# dies while Cortex is still at the prompt and a parent walk never sees it.
# Herdr's process list for this pane names the real cortex pid. Tests stub
# herdr with empty stdout, so they fall through to the immediate parent.
watch_pid() {
  local pid comm i=0
  if command -v python3 >/dev/null 2>&1; then
    pid=$("$HERDR_BIN_PATH" pane process-info --pane "$HERDR_PANE_ID" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    sys.exit(0)
try:
    d = json.loads(raw[i:])
except Exception:
    sys.exit(0)
info = (d.get("result") or {}).get("process_info") or {}
for proc in reversed(info.get("foreground_processes") or []):
    name = proc.get("name") or ""
    argv0 = proc.get("argv0") or ""
    if name in ("cortex", "cortex.exe") or argv0 in ("cortex", "cortex.exe") or name.endswith("/cortex"):
        pid = proc.get("pid")
        if isinstance(pid, int) and pid > 1:
            sys.stdout.write(str(pid))
        break
' 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$pid"; return 0 ;;
    esac
  fi
  pid="$PPID"
  while [ "${pid:-0}" -gt 1 ] 2>/dev/null && [ "$i" -lt 20 ]; do
    comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')
    case "$comm" in
      cortex|cortex.exe) printf '%s' "$pid"; return 0 ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    i=$(( i + 1 ))
  done
  if [ "$PPID" -gt 1 ] 2>/dev/null; then
    printf '%s' "$PPID"
    return 0
  fi
  return 1
}

needs_user_attention() {
  # Notification also carries team-worker lifecycle updates. Only mark the pane
  # blocked when the message asks the user to take an action or answer a question.
  case "$1" in
    *"<task-notification>"*|*"Discovery update from a sibling subagent"*|*"Team Mode Active"*|*"Plan mode is active"*)
      return 1 ;;
    *"<system-reminder>"*)
      return 1 ;;
    *"?"*|*"Please "*|*"please "*|*"Choose "*|*"choose "*|*"Select "*|*"select "*|*"Approve "*|*"approve "*|*"Confirm "*|*"confirm "*|*"Need your "*|*"need your "*|*"Awaiting your "*|*"awaiting your "*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

case "$EVENT" in
  SessionStart)                            report idle; rename_tab_from_title ;;
  UserPromptSubmit)                        report working; rename_tab_from_title ;;
  PreToolUse|PostToolUse)                  report working ;;
  PermissionRequest)
      # Fires when CoCo asks permission to run a tool.
      report blocked "${TOOL_NAME:-awaiting approval}" ;;
  Notification)
      # PermissionRequest is authoritative for tool approval. Notification also
      # carries team updates, so report blocked only for user-action prompts.
      printf '%s   Notification message: %.200s\n' "$(date '+%H:%M:%S')" "$MESSAGE" >> "$LOG_FILE" 2>/dev/null || true
      case "$MESSAGE" in
        "Permission required:"*) : ;;
        *) needs_user_attention "$MESSAGE" && report blocked "awaiting input" ;;
      esac ;;
  Stop)                                    report idle ;;
  SessionEnd)
      # Cortex fires SessionEnd on exit and on an in-process session switch
      # (/new). Releasing now would drop the row and its title on a switch.
      # Report idle with the seq + 1 reservation already stored, and release from
      # a detached watcher once the Cortex process exits. Herdr ignores a
      # release whose seq is not above the last accepted, so the next
      # SessionStart cancels it. A parent of PID 1 or below, with no cortex
      # ancestor, means the hook was reparented.
      report idle
      rename_tab_from_title
      WP=$(watch_pid) || WP=
      if [ -n "$WP" ]; then
        printf '%s   SessionEnd: watching pid %s\n' "$(date '+%H:%M:%S')" "$WP" >> "$LOG_FILE" 2>/dev/null || true
        "$BASH" "$0" __watch "$WP" "$(( SEQ + 1 ))" </dev/null >/dev/null 2>&1 &
      else
        printf '%s   SessionEnd: parent pid %s unusable, no watcher\n' "$(date '+%H:%M:%S')" "$PPID" >> "$LOG_FILE" 2>/dev/null || true
      fi
      ;;
  *) : ;;
esac

exit 0   # never block a CoCo turn
