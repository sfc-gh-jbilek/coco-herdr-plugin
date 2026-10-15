#!/usr/bin/env bash
# Stub tests for both hook scripts. Runs each script against a fake herdr that
# records argv, then checks the calls, the event log, and the seq file.
# Usage: bash tests/run.sh          (pwsh is needed for the .ps1 checks)
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [ "$1" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3: got [$1] want [$2]"; fail=1; fi; }
INJ='x; rm -rf / && echo $(whoami) `id` | cat'

kinds="sh"
if command -v pwsh >/dev/null 2>&1; then kinds="sh ps1"; else echo "SKIP ps1 (pwsh not installed)"; fi

# The .sh suite runs once per bash found, so both the EPOCHREALTIME (bash 5)
# and the date-based (bash 3.2) clock branches are covered where possible.
BASHES=""
for b in /bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash; do
  [ -x "$b" ] && BASHES="$BASHES $b"
done

# Unit check of the EPOCHREALTIME arithmetic, copied from the script, across
# fraction lengths a real bash may emit (bash 5 gives 6 digits; zsh gives 10).
for pair in 1788454687.541790:1788454687541 1788454687.5417900085:1788454687541 1788454687.5:1788454687500 1788454687.000123:1788454687000; do
  t=${pair%%:*}; want=${pair##*:}
  F=${t#*.}000; NOW=$(( ${t%.*} * 1000 + 10#${F:0:3} ))
  check "$NOW" "$want" "clock arithmetic for fraction '${t#*.}'"
done

mkenv() { # fresh temp dir with a stub herdr that records argv; exported as TMPDIR
  # Each call is appended with one write by cat, so concurrent calls do not
  # interleave (bash line-buffers its own stdout, one write per line).
  T=$(TMPDIR=/tmp mktemp -d); STUB="$T/stub.sh"; ARGV="$T/argv.log"
  printf '#!/usr/bin/env bash\nr=\nfor a in "$@"; do r="$r$a"$'"'"'\\n'"'"'; done\ncat >> %s <<< "${r}--"\n[ -f %s/fail ] && exit 3\nexit 0\n' "$ARGV" "$T" > "$STUB"; chmod +x "$STUB"
  export TMPDIR="$T"
  if [ "$kind" = sh ]; then SEQF="$T/herdr-coco/seq.w1:p1" LOGF="$T/herdr-coco/events.w1:p1.log"; else SEQF="$T/herdr-coco/seq.w1_p1" LOGF="$T/herdr-coco/events.w1_p1.log"; fi
}
waitfor() { # $1 tenths of a second, rest = command polled until it succeeds
  local n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$(( n - 1 )); done; return 1
}
has_release() { grep -qx release-agent "$ARGV" 2>/dev/null; }
calls() { awk '$0=="--"{ print c; c=""; next } { c = c (c=="" ? "" : " ") $0 }' "$ARGV" 2>/dev/null; }
releases() { calls | grep '^pane release-agent '; }
reports() { calls | grep '^pane report-agent '; }
seq_of() { sed 's/.* --seq \([0-9]*\).*/\1/'; }
# Watchers are found by command line: "<script> __watch <parent pid> <seq>".
watcher_up() { pgrep -f "herdr-coco-state\.(sh|ps1) __watch $1 " >/dev/null 2>&1; }
no_watcher() { ! watcher_up "$1"; }
parent() { # $1 payload, $2 seconds the parent outlives the hook. Sets PP (parent) and RD.
  # The hook's stdout/stderr is a FIFO. $T/eof appears only when every writer
  # has closed it, so a watcher that inherits the hook's stdio delays it.
  printf '%s' "$1" > "$T/payload"; mkfifo "$T/out"
  ( cat "$T/out" > /dev/null; : > "$T/eof" ) & RD=$!
  /bin/bash -c 'd=$1 s=$2; shift 2; date +%s > "$d/t0"; env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$d/stub.sh" TMPDIR="$d" "$@" < "$d/payload" > "$d/out" 2>&1; echo $? > "$d/rc"; date +%s > "$d/t1"; sleep "$s"' _ "$T" "$2" "${HOOK[@]}" & PP=$!
  waitfor 100 test -e "$T/t1"
}
launcher() { # runs every $T/p.* payload as a hook at once, waits for all, exits. Sets PP.
  /bin/bash -c 'd=$1; shift; for f in "$d"/p.*; do env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$d/stub.sh" TMPDIR="$d" "$@" < "$f" > /dev/null 2>&1 & done; wait' _ "$T" "${HOOK[@]}" & PP=$!
  RD=
}
reap() { { pkill -f "herdr-coco-state\.(sh|ps1) __watch $PP "; kill $PP $RD; wait $PP $RD; } 2>/dev/null; rm -rf "$T"; unset TMPDIR; }

for kind in $kinds; do
 for BASH_BIN in $( [ "$kind" = sh ] && echo $BASHES || echo pwsh ); do
  if [ "$kind" = sh ]; then echo "== sh via $BASH_BIN ($($BASH_BIN -c 'echo $BASH_VERSION'))"; else echo "== ps1 via $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"; fi
  if [ "$kind" = sh ]; then HOOK=( "$BASH_BIN" "$R/scripts/herdr-coco-state.sh" ); else HOOK=( pwsh -NoProfile -File "$R/scripts/herdr-coco-state.ps1" ); fi
  mkenv
  run() { # $1 payload, $2 label, $3 optional extra env
    if [ "$kind" = sh ]; then printf '%s' "$1" | env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$STUB" ${3:-} "$BASH_BIN" "$R/scripts/herdr-coco-state.sh"
    else printf '%s' "$1" | env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$STUB" ${3:-} pwsh -NoProfile -File "$R/scripts/herdr-coco-state.ps1"; fi
    check "$?" "0" "$kind: exit 0 ($2)"
  }

  # No-op guard: no HERDR_* vars, nothing written.
  if [ "$kind" = sh ]; then printf '{"hook_event_name":"Stop"}' | env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_BIN_PATH "$BASH_BIN" "$R/scripts/herdr-coco-state.sh"; else printf '{"hook_event_name":"Stop"}' | env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_BIN_PATH pwsh -NoProfile -File "$R/scripts/herdr-coco-state.ps1"; fi
  check "$?" "0" "$kind: exit 0 outside Herdr"
  check "$(ls "$T" | grep -c herdr-coco)" "0" "$kind: no files written outside Herdr"

  run '{"hook_event_name":"SessionStart","session_id":"s1"}' SessionStart
  run '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}' UserPromptSubmit
  run '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"bash","tool_input":{"command":"ls"}}' PreToolUse
  run '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"bash"}' PostToolUse
  run '{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"edit"}' PermissionRequest
  run "{\"hook_event_name\":\"Notification\",\"session_id\":\"s1\",\"message\":\"$INJ\"}" Notification
  run '{"hook_event_name":"Notification","session_id":"s1","message":"Permission required: execute_command on git commit"}' approval-notification
  run 'garbage' garbage
  run '{"hook_event_name":"PermissionRequest","session_id":"--evil","tool_name":"--state working"}' option-injection
  touch "$T/fail"
  run '{"hook_event_name":"Stop","session_id":"s1"}' Stop-failing
  rm "$T/fail"
  run '{"hook_event_name":"SessionEnd","session_id":"s1"}' SessionEnd

  if [ "$kind" = sh ]; then LOG="$T/herdr-coco/events.w1:p1.log"; SEQF="$T/herdr-coco/seq.w1:p1"; else LOG="$T/herdr-coco/events.w1_p1.log"; SEQF="$T/herdr-coco/seq.w1_p1"; fi
  states=$(grep -A1 -x -- '--state' "$ARGV" | grep -vx -e '--state' -e '--' | tr '\n' ' ')
  check "$states" "idle working working working blocked blocked idle idle " "$kind: state sequence"
  check "$(grep -c '^s1$' "$ARGV")" "7" "$kind: session id on every report"
  check "$(grep -c -e '^--evil$' -e '^--state working$' "$ARGV")" "0" "$kind: option-like values dropped from argv"
  check "$(grep -c '^awaiting approval$' "$ARGV")" "1" "$kind: fallback message when tool name rejected"
  check "$(grep -c '^edit$' "$ARGV")" "1" "$kind: tool name as permission message"
  check "$(grep -c '^awaiting input$' "$ARGV")" "0" "$kind: shell-injection notification is not a user question"
  check "$(grep -c 'whoami' "$ARGV")" "0" "$kind: prompt text not sent to Herdr"
  check "$(grep -c '^w1:p1$' "$ARGV")" "12" "$kind: pane id verbatim"
  check "$(grep -c '^release-agent$' "$ARGV")" "0" "$kind: SessionEnd does not release while hook parent alive"
  seqs=$(grep -A1 -x -- '--seq' "$ARGV" | grep -vx -e '--seq' -e '--')
  check "$(printf '%s\n' "$seqs" | wc -l | tr -d ' ')" "8" "$kind: one seq per herdr call"
  prev=0; mono=yes; for s in $seqs; do [ "$s" -gt "$prev" ] || mono=no; prev=$s; done
  check "$mono" "yes" "$kind: seq strictly increasing"
  check "${#prev}" "13" "$kind: seq is a 13-digit ms timestamp"
  # Wall-clock check uses the first seq. It must run before the clock-stall
  # test below pre-seeds the seq file, or a stalled value would pass.
  now_ms=$(( $(date +%s) * 1000 )); first=$(printf '%s\n' "$seqs" | head -1)
  [ "$first" -gt $(( now_ms - 120000 )) ] && [ "$first" -lt $(( now_ms + 120000 )) ] && ok=yes || ok=no
  check "$ok" "yes" "$kind: seq within 2 min of wall clock"
  check "$(grep -c ' \[plugin\]$' "$LOG")" "11" "$kind: one log line per event"
  check "$(grep -c 'PreToolUse tool=bash' "$LOG")" "1" "$kind: tool name logged"
  check "$(grep -c 'Notification message: x; rm -rf' "$LOG")" "1" "$kind: notification message logged"
  check "$(grep -c 'Notification message: Permission required:' "$LOG")" "1" "$kind: approval notification logged"
  check "$(grep -c 'herdr report-agent failed rc=3' "$LOG")" "1" "$kind: failed herdr call logged"
  echo 9999999999999 > "$SEQF"
  run '{"hook_event_name":"Stop"}' clock-stall
  check "$(cat "$SEQF")" "10000000000000" "$kind: seq bumped past stored value"
  if [ "$kind" = sh ]; then
    check "$(stat -f %Lp "$T/herdr-coco" 2>/dev/null || stat -c %a "$T/herdr-coco")" "700" "sh: log dir mode 700"
    # No python3 on PATH: the fallback parser must still produce correct calls.
    # The bin dir holds every external the .sh calls; python3 is left out.
    # rmdir releases the seq lock; sleep runs only while waiting for it.
    mkdir -p "$T/bin"; for b in cat date wc tail mv mkdir grep head sed rmdir sleep; do ln -s "$(command -v $b)" "$T/bin/$b"; done; ln -s "$BASH_BIN" "$T/bin/bash"
    : > "$ARGV"; rm -f "$SEQF"
    printf '{"hook_event_name":"PermissionRequest","session_id":"s2","tool_name":"bash","tool_input":{"command":"ls"}}' | env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$STUB" PATH="$T/bin" "$BASH_BIN" "$R/scripts/herdr-coco-state.sh"
    check "$?" "0" "sh: exit 0 without python3"
    check "$(grep -A1 -x -- '--state' "$ARGV" | tail -1)" "blocked" "sh: state parsed without python3"
    check "$(grep -c '^s2$' "$ARGV")" "1" "sh: session id parsed without python3"
    check "$(grep -A1 -x -- '--message' "$ARGV" | tail -1)" "bash" "sh: tool name parsed without python3"
    check "$(cat "$SEQF" | wc -c | tr -d ' ')" "13" "sh: 13-digit seq without python3"
  fi
  rm -rf "$T"; unset TMPDIR

  # Deferred release (WI-41). Each case runs the hook from a disposable parent
  # in a fresh temp dir. T1: parent alive at hook return.
  mkenv; parent '{"hook_event_name":"SessionEnd","session_id":"s1"}' 3
  check "$(cat "$T/rc" 2>/dev/null)" "0" "$kind: exit 0 (SessionEnd, live parent)"
  t0=$(cat "$T/t0" 2>/dev/null || echo 0); t1=$(cat "$T/t1" 2>/dev/null || echo 99)
  check "$( [ $(( t1 - t0 )) -le 2 ] && echo yes || echo no)" "yes" "$kind: SessionEnd hook returns within 2 s"
  check "$(waitfor 10 test -e "$T/eof" && echo yes || echo no)" "yes" "$kind: SessionEnd leaves no process on hook stdio"
  check "$(grep -c '^release-agent$' "$ARGV")" "0" "$kind: no release-agent at hook return"
  check "$(waitfor 50 watcher_up $PP && echo yes || echo no)" "yes" "$kind: watcher running while parent alive"
  S=$(grep -A1 -x -- '--seq' "$ARGV" | grep -vx -e '--seq' -e '--' | head -1); S=${S:-0}
  check "$(cat "$SEQF" 2>/dev/null)" "$(( S + 1 ))" "$kind: SessionEnd reserves idle seq + 1"
  # T2: parent exits, the watcher releases once with the reserved seq.
  wait $PP 2>/dev/null; waitfor 50 has_release; sleep 1.5
  check "$(releases | wc -l | tr -d ' ')" "1" "$kind: one release-agent after parent exits"
  check "$(releases | head -1)" "pane release-agent w1:p1 --source custom:coco --agent coco --seq $(( S + 1 ))" "$kind: release-agent argv and seq"
  check "$(waitfor 50 no_watcher $PP && echo yes || echo no)" "yes" "$kind: watcher exits after release"
  reap
  # T3: a later event before the parent exits cancels the release, and the
  # watcher exits while the parent is still alive.
  mkenv; parent '{"hook_event_name":"SessionEnd","session_id":"s1"}' 8
  waitfor 50 watcher_up $PP
  run '{"hook_event_name":"SessionStart","session_id":"s3"}' SessionStart-after-SessionEnd
  check "$(waitfor 40 no_watcher $PP && kill -0 $PP 2>/dev/null && echo yes || echo no)" "yes" "$kind: later event stops the watcher while parent alive"
  wait $PP 2>/dev/null; sleep 1.5
  check "$(grep -c '^release-agent$' "$ARGV")" "0" "$kind: later event cancels the release"
  reap
  # T4: seq file removed, the watcher exits without releasing.
  mkenv; parent '{"hook_event_name":"SessionEnd","session_id":"s1"}' 8
  waitfor 50 watcher_up $PP
  rm -f "$SEQF"
  check "$(waitfor 40 no_watcher $PP && kill -0 $PP 2>/dev/null && echo yes || echo no)" "yes" "$kind: removed seq file stops the watcher while parent alive"
  wait $PP 2>/dev/null; sleep 1.5
  check "$(grep -c '^release-agent$' "$ARGV")" "0" "$kind: removed seq file cancels the release"
  reap
  # T5: the hook is reparented (double fork), so its parent is PID 1 (sh) or
  # unresolvable (ps1). No watcher starts and the log says so.
  mkenv; printf '%s' '{"hook_event_name":"SessionEnd","session_id":"s1"}' > "$T/payload"
  /bin/bash -c '( sleep 0.3; exec env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$1/stub.sh" TMPDIR="$1" "${@:2}" < "$1/payload" > /dev/null 2>&1 ) &' _ "$T" "${HOOK[@]}"
  PP=1; RD=
  check "$(waitfor 150 grep -qs 'unusable, no watcher' "$LOGF" && echo yes || echo no)" "yes" "$kind: reparented hook logs no watcher"
  sleep 1
  check "$(watcher_up 1 && echo yes || echo no)" "no" "$kind: no watcher for parent pid <= 1"
  check "$(reports | grep -c ' --state idle ')" "1" "$kind: reparented SessionEnd still reports idle"
  rm -rf "$T"; unset TMPDIR
  # T6: a malformed seq file is treated as 0.
  mkenv; mkdir -p "$T/herdr-coco"; echo abc > "$SEQF"
  run '{"hook_event_name":"Stop","session_id":"s1"}' malformed-seq
  check "$(reports | wc -l | tr -d ' ')" "1" "$kind: malformed seq file still reports"
  check "$(reports | seq_of | tr -d '\n' | wc -c | tr -d ' ')" "13" "$kind: malformed seq file gives a 13-digit seq"
  rm -rf "$T"; unset TMPDIR
  # T7: eight hooks at once for one pane, SessionEnd (session e) among them.
  mkenv; i=0
  for e in SessionStart UserPromptSubmit PreToolUse PostToolUse PermissionRequest Stop PostToolUse SessionEnd; do
    i=$(( i + 1 )); sid=c; [ "$e" = SessionEnd ] && sid=e
    printf '{"hook_event_name":"%s","session_id":"%s","tool_name":"bash"}' "$e" "$sid" > "$T/p.$i"
  done
  launcher; wait $PP 2>/dev/null
  check "$(reports | wc -l | tr -d ' ')" "8" "$kind: concurrent hooks each report once"
  check "$(reports | seq_of | sort -u | wc -l | tr -d ' ')" "8" "$kind: concurrent hooks get unique seqs"
  max=$(reports | seq_of | sort -n | tail -1); es=$(reports | grep -E ' --agent-session-id e( |$)' | seq_of)
  if [ "$es" = "$max" ]; then want=$(( max + 1 )) wantrel=1; else want=$max wantrel=0; fi
  check "$(cat "$SEQF" 2>/dev/null)" "$want" "$kind: seq file holds the last allocation (SessionEnd last: $wantrel)"
  check "$(waitfor 150 no_watcher $PP && echo yes || echo no)" "yes" "$kind: no watcher left after concurrent hooks"
  check "$(releases | wc -l | tr -d ' ')" "$wantrel" "$kind: release only if SessionEnd allocated last"
  check "$(ls "$T/herdr-coco" | grep -c -e '\.tmp\.' -e '\.lock$' | tr -d ' ')" "$( [ "$kind" = sh ] && echo 0 || echo 1)" "$kind: no temp file or held lock left"
  reap
  # T8: SessionEnd and SessionStart at once from one parent that then exits.
  # A release is correct only when SessionEnd allocated after SessionStart.
  mkenv
  printf '%s' '{"hook_event_name":"SessionEnd","session_id":"e"}' > "$T/p.1"
  printf '%s' '{"hook_event_name":"SessionStart","session_id":"s"}' > "$T/p.2"
  launcher; wait $PP 2>/dev/null
  es=$(reports | grep -E ' --agent-session-id e( |$)' | seq_of); ss=$(reports | grep -E ' --agent-session-id s( |$)' | seq_of)
  if [ "${es:-0}" -gt "${ss:-0}" ]; then order="SessionEnd last" wantrel=1; else order="SessionStart last" wantrel=0; fi
  [ "$wantrel" = 1 ] || check "$( [ "${ss:-0}" -gt $(( ${es:-0} + 1 )) ] && echo yes || echo no)" "yes" "$kind: SessionStart outranks the reserved seq ($order)"
  check "$(waitfor 150 no_watcher $PP && echo yes || echo no)" "yes" "$kind: watcher gone after race ($order)"
  check "$(releases | wc -l | tr -d ' ')" "$wantrel" "$kind: race releases only after a final SessionEnd ($order)"
  [ "$wantrel" = 1 ] && check "$(releases | seq_of)" "$(( es + 1 ))" "$kind: race release uses the reserved seq ($order)"
  reap
 done
done
[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAIL"; exit 1; }
