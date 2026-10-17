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

for kind in $kinds; do
 for BASH_BIN in $( [ "$kind" = sh ] && echo $BASHES || echo pwsh ); do
  if [ "$kind" = sh ]; then echo "== sh via $BASH_BIN ($($BASH_BIN -c 'echo $BASH_VERSION'))"; else echo "== ps1 via $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"; fi
  T=$(TMPDIR=/tmp mktemp -d); STUB="$T/stub.sh"; ARGV="$T/argv.log"
  printf '#!/usr/bin/env bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> %s\nprintf -- "--\\n" >> %s\n[ -f %s/fail ] && exit 3\nexit 0\n' "$ARGV" "$ARGV" "$T" > "$STUB"; chmod +x "$STUB"
  export TMPDIR="$T"
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
  check "$(grep -c '^rename$' "$ARGV")" "0" "$kind: no tab rename without a pane title"
  check "$(grep -c '^release-agent$' "$ARGV")" "0" "$kind: SessionEnd does not release the pane"
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
    mkdir -p "$T/bin"; for b in cat date wc tail mv mkdir grep head sed; do ln -s "$(command -v $b)" "$T/bin/$b"; done; ln -s "$BASH_BIN" "$T/bin/bash"
    : > "$ARGV"; rm -f "$SEQF"
    printf '{"hook_event_name":"PermissionRequest","session_id":"s2","tool_name":"bash","tool_input":{"command":"ls"}}' | env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$STUB" PATH="$T/bin" "$BASH_BIN" "$R/scripts/herdr-coco-state.sh"
    check "$?" "0" "sh: exit 0 without python3"
    check "$(grep -A1 -x -- '--state' "$ARGV" | tail -1)" "blocked" "sh: state parsed without python3"
    check "$(grep -c '^s2$' "$ARGV")" "1" "sh: session id parsed without python3"
    check "$(grep -A1 -x -- '--message' "$ARGV" | tail -1)" "bash" "sh: tool name parsed without python3"
    check "$(cat "$SEQF" | wc -c | tr -d ' ')" "13" "sh: 13-digit seq without python3"
    # Pane title becomes the tab label when the tab is still named "cortex".
    # A label someone already set is left alone.
    RT=$(TMPDIR=/tmp mktemp -d); RARGV="$RT/argv.log"; RSTUB="$RT/stub.sh"
    cat > "$RSTUB" << EOF
#!/usr/bin/env bash
printf '%s\\n' "\$@" >> "$RARGV"
printf -- '--\\n' >> "$RARGV"
if [ "\$1" = pane ] && [ "\$2" = get ]; then
  printf '%s\\n' '{"result":{"pane":{"terminal_title":"Fix the parser (cortex)","tab_id":"w9:t1"}}}'
elif [ "\$1" = tab ] && [ "\$2" = get ]; then
  if [ -f "$RT/named" ]; then
    printf '%s\\n' '{"result":{"tab":{"label":"Daily Routine"}}}'
  else
    printf '%s\\n' '{"result":{"tab":{"label":"cortex"}}}'
  fi
fi
exit 0
EOF
    chmod +x "$RSTUB"
    export TMPDIR="$RT"
    printf '%s' '{"hook_event_name":"Stop","session_id":"s9"}' | env HERDR_ENV=1 HERDR_PANE_ID=w9:p1 HERDR_BIN_PATH="$RSTUB" "$BASH_BIN" "$R/scripts/herdr-coco-state.sh"
    check "$?" "0" "sh: exit 0 when renaming the tab"
    check "$(grep -c '^rename$' "$RARGV")" "1" "sh: placeholder tab is renamed from the OSC title"
    check "$(grep -c '^Fix the parser$' "$RARGV")" "1" "sh: (cortex) suffix stripped"
    touch "$RT/named"; : > "$RARGV"
    printf '%s' '{"hook_event_name":"Stop","session_id":"s9"}' | env HERDR_ENV=1 HERDR_PANE_ID=w9:p1 HERDR_BIN_PATH="$RSTUB" "$BASH_BIN" "$R/scripts/herdr-coco-state.sh"
    check "$(grep -c '^rename$' "$RARGV")" "0" "sh: an existing tab name is left alone"
    rm -rf "$RT"
    export TMPDIR="$T"
  fi
  rm -rf "$T"; unset TMPDIR
 done
done
[ $fail = 0 ] && echo "ALL PASS" || { echo "SOME FAIL"; exit 1; }
