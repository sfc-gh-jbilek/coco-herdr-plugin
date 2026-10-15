# Report Cortex Code lifecycle state to Herdr (Windows port of herdr-coco-state.sh).
# Does nothing outside a Herdr pane. Never fails the CoCo turn.
# Shipped by the "herdr" CoCo plugin. Invoked via ${CLAUDE_PLUGIN_ROOT}.
$ErrorActionPreference = 'SilentlyContinue'

# Guard: act only inside a Herdr-managed pane.
if ($env:HERDR_ENV -ne '1') { exit 0 }
if ([string]::IsNullOrEmpty($env:HERDR_PANE_ID)) { exit 0 }
if ([string]::IsNullOrEmpty($env:HERDR_BIN_PATH)) { exit 0 }
if (-not (Test-Path -LiteralPath $env:HERDR_BIN_PATH -PathType Leaf)) { exit 0 }

$Source = 'custom:coco'
$Agent = 'coco'
$Pane = $env:HERDR_PANE_ID
$HerdrBin = $env:HERDR_BIN_PATH

# Pane IDs such as "w1:p1" contain ":", which is illegal in Windows file names.
$PaneFile = $Pane -replace ':', '_'

# Monotonic sequence per pane. Herdr keeps the highest accepted --seq per pane
# for the life of the server, so a counter that restarts per session is ignored.
# Use a millisecond timestamp, bumped past the stored value if needed.
$SeqDir = Join-Path ([IO.Path]::GetTempPath()) 'herdr-coco'
# %TEMP% is already per-user on Windows, so no extra ACL is needed.
try { New-Item -ItemType Directory -Path $SeqDir -Force | Out-Null } catch {}
$SeqFile = Join-Path $SeqDir "seq.$PaneFile"
# OS-held lock (FileShare.None). The OS releases it if the holder dies, so it
# never goes stale.
$LockFile = "$SeqFile.lock"
# Per-pane event log for troubleshooting ($coco-herdr-plugin:doctor reads it).
$LogFile = Join-Path $SeqDir "events.$PaneFile.log"

function Invoke-Herdr {
    # Runs Herdr and records a failure in the log so $coco-herdr-plugin:doctor can see it.
    # The exit code is never propagated. Callers always pass "pane <subcommand>"
    # first, so $HerdrArgs[1] is the subcommand named in the log line.
    # $LASTEXITCODE is reset first: a binary that fails to launch does not set
    # it, and under SilentlyContinue that failure would otherwise look like 0.
    param([string[]]$HerdrArgs)
    $global:LASTEXITCODE = -1
    $rc = -1
    try { & $HerdrBin @HerdrArgs *> $null; $rc = $LASTEXITCODE } catch { $rc = -1 }
    if ($rc -ne 0) {
        try { Add-Content -LiteralPath $LogFile -Value "$Stamp   herdr $($HerdrArgs[1]) failed rc=$rc" } catch {}
    }
}

function Invoke-HerdrBounded {
    # Invoke-Herdr for the detached watcher: kills Herdr after 10 s so a stuck
    # call cannot keep the watcher alive.
    param([string[]]$HerdrArgs)
    $rc = -1
    try {
        $si = New-Object Diagnostics.ProcessStartInfo
        $si.FileName = $HerdrBin
        $si.Arguments = ($HerdrArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
        $si.UseShellExecute = $false
        $si.CreateNoWindow = $true
        $si.RedirectStandardInput = $true
        $si.RedirectStandardOutput = $true
        $si.RedirectStandardError = $true
        $hp = [Diagnostics.Process]::Start($si)
        try { $hp.StandardInput.Close() } catch {}
        if ($hp.WaitForExit(10000)) { $rc = $hp.ExitCode }
        else { try { $hp.Kill() } catch {}; $rc = 'timeout' }
    } catch { $rc = -1 }
    if ("$rc" -ne '0') {
        try { Add-Content -LiteralPath $LogFile -Value "$Stamp   herdr $($HerdrArgs[1]) failed rc=$rc" } catch {}
    }
}

# Watcher mode, started detached by SessionEnd: "__watch <cortex pid> <seq>".
# Releases the row once the Cortex process exits. Exits without releasing once
# the seq file holds a value above the reserved seq (a later hook event ran) or
# is gone. An unreadable or non-numeric value is retried on the next tick.
# Lifetime cap: 24 h.
if ($args.Count -eq 3 -and $args[0] -eq '__watch') {
    [long]$WPid = 0; [long]$WSeq = 0
    if (-not [long]::TryParse("$($args[1])", [ref]$WPid) -or -not [long]::TryParse("$($args[2])", [ref]$WSeq)) { exit 0 }
    for ($n = 0; $n -lt 86400; $n++) {
        if (-not (Test-Path -LiteralPath $SeqFile -PathType Leaf)) { exit 0 }
        [long]$Cur = 0
        $Txt = $null
        try { $Txt = [IO.File]::ReadAllText($SeqFile).Trim() } catch {}
        if ($Txt -and [long]::TryParse($Txt, [ref]$Cur) -and $Cur -gt $WSeq) { exit 0 }
        if (-not (Get-Process -Id $WPid -ErrorAction SilentlyContinue)) {
            $Stamp = Get-Date -Format 'HH:mm:ss'
            Invoke-HerdrBounded @('pane', 'release-agent', $Pane,
                                  '--source', $Source, '--agent', $Agent, '--seq', "$WSeq")
            exit 0
        }
        Start-Sleep -Seconds 1
    }
    exit 0
}

# Hook payload arrives as JSON on stdin.
$Payload = ''
try { $Payload = [Console]::In.ReadToEnd() } catch {}
$Data = $null
try { if ($Payload) { $Data = $Payload | ConvertFrom-Json } } catch { $Data = $null }

function Get-Field {
    # $Name = field name. Returns '' when missing. Nested values are JSON-encoded.
    param([string]$Name)
    if ($null -eq $Data) { return '' }
    $v = $Data.PSObject.Properties[$Name]
    if ($null -eq $v -or $null -eq $v.Value) { return '' }
    $val = $v.Value
    if ($val -is [System.Management.Automation.PSCustomObject] -or $val -is [array]) {
        return ($val | ConvertTo-Json -Compress -Depth 10)
    }
    return [string]$val
}

$Event = Get-Field 'hook_event_name'
if (-not $Event -and $args.Count -gt 0) { $Event = $args[0] }
$SessionId = Get-Field 'session_id'
$ToolName = Get-Field 'tool_name'
# Values that become argv elements must not look like options.
if ($SessionId -notmatch '^[A-Za-z0-9_.:][A-Za-z0-9_.:-]*$') { $SessionId = '' }
if ($ToolName -notmatch '^[A-Za-z0-9_.:][A-Za-z0-9_.:-]*$') { $ToolName = '' }

# Seq allocation is serialized per pane. Wait at most ~2 s for the lock, then
# continue without it rather than block the turn.
$Lock = $null
for ($i = 0; $i -lt 40 -and $null -eq $Lock; $i++) {
    try { $Lock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { Start-Sleep -Milliseconds 50 }
}
[long]$Last = 0
try { [long]::TryParse(([IO.File]::ReadAllText($SeqFile)).Trim(), [ref]$Last) | Out-Null } catch {}
[long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ($Now -gt $Last) { $Seq = $Now } else { $Seq = $Last + 1 }
# SessionEnd stores its reserved release seq ($Seq + 1) in the same lock hold,
# so no concurrent event can allocate a value at or below it.
$Store = $Seq
if ($Event -eq 'SessionEnd') { $Store = $Seq + 1 }
# Temp file + replace, so a reader never sees a partial value.
$SeqTmp = "$SeqFile.tmp.$PID"
try {
    [IO.File]::WriteAllText($SeqTmp, "$Store")
    if ([IO.File]::Exists($SeqFile)) { [IO.File]::Replace($SeqTmp, $SeqFile, $null) }
    else { [IO.File]::Move($SeqTmp, $SeqFile) }
} catch {
    try { [IO.File]::WriteAllText($SeqFile, "$Store") } catch {}
    try { [IO.File]::Delete($SeqTmp) } catch {}
}
if ($null -ne $Lock) { try { $Lock.Close() } catch {} }

$Stamp = Get-Date -Format 'HH:mm:ss'
try { Add-Content -LiteralPath $LogFile -Value "$Stamp $Event tool=$ToolName [plugin]" } catch {}
try {
    $lines = @(Get-Content -LiteralPath $LogFile)
    if ($lines.Count -gt 400) { Set-Content -LiteralPath $LogFile -Value ($lines | Select-Object -Last 200) }
} catch {}

function Send-Report {
    # $State = Herdr state, $Message = optional text (may contain tool output).
    param([string]$State, [string]$Message = '')
    $a = @('pane', 'report-agent', $Pane,
           '--source', $Source, '--agent', $Agent,
           '--state', $State, '--seq', "$Seq")
    if ($SessionId) { $a += @('--agent-session-id', $SessionId) }
    # $Message is always one argv element. PowerShell never re-parses it.
    if ($Message) { $a += @('--message', $Message) }
    Invoke-Herdr $a
}

function Test-NeedsUserAttention {
    # Notification also carries team-worker lifecycle updates. Only mark the pane
    # blocked when the message asks the user to take an action or answer a question.
    param([string]$Message)
    if ($Message -match '<task-notification>|Discovery update from a sibling subagent|Team Mode Active|Plan mode is active|<system-reminder>') {
        return $false
    }
    return $Message -match '\?|\b[Pp]lease\b|\b[Cc]hoose\b|\b[Ss]elect\b|\b[Aa]pprove\b|\b[Cc]onfirm\b|\b[Nn]eed your\b|\b[Aa]waiting your\b'
}

switch ($Event) {
    'SessionStart' { Send-Report 'idle' }
    { $_ -in 'UserPromptSubmit', 'PreToolUse', 'PostToolUse' } { Send-Report 'working' }
    'PermissionRequest' {
        # Fires when CoCo asks permission to run a tool.
        $m = $ToolName
        if (-not $m) { $m = 'awaiting approval' }
        Send-Report 'blocked' $m
    }
    'Notification' {
        # PermissionRequest is authoritative for tool approval. Notification also
        # carries team updates, so report blocked only for user-action prompts.
        $m = Get-Field 'message'
        if ($m.Length -gt 200) { $m = $m.Substring(0, 200) }
        try { Add-Content -LiteralPath $LogFile -Value "$Stamp   Notification message: $m" } catch {}
        if (-not $m.StartsWith('Permission required:') -and (Test-NeedsUserAttention $m)) {
            Send-Report 'blocked' 'awaiting input'
        }
    }
    'Stop' { Send-Report 'idle' }
    'SessionEnd' {
        # Cortex fires SessionEnd on exit and on an in-process session switch
        # (/new). Releasing now would drop the row and its title on a switch.
        # Report idle with the seq + 1 reservation already stored, and release
        # from a detached watcher once the Cortex process (this script's parent)
        # exits. Herdr ignores a release whose seq is not above the last
        # accepted, so the next SessionStart cancels it. An unresolved parent,
        # or PID 1 and below, means there is no Cortex process to watch.
        Send-Report 'idle'
        $ReleaseSeq = $Seq + 1
        try {
            $ParentId = 0
            try { $ParentId = [Diagnostics.Process]::GetCurrentProcess().Parent.Id } catch {}
            if (-not $ParentId) {
                try { $ParentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } catch {}
            }
            if ([long]"0$ParentId" -gt 1) {
                # The hook parent is often a short-lived runner. Watch the cortex
                # process above it so the row stays until Cortex itself exits.
                # With no such ancestor (tests), watch the immediate parent.
                $WatchId = [long]"0$ParentId"
                $Cursor = $WatchId
                for ($i = 0; $i -lt 20 -and $Cursor -gt 1; $i++) {
                    $Name = $null
                    try { $Name = (Get-Process -Id $Cursor -ErrorAction Stop).ProcessName } catch { break }
                    if ($Name -eq 'cortex') { $WatchId = $Cursor; break }
                    $Next = 0
                    try { $Next = [long](Get-CimInstance Win32_Process -Filter "ProcessId=$Cursor").ParentProcessId } catch { break }
                    if ($Next -le 1 -or $Next -eq $Cursor) { break }
                    $Cursor = $Next
                }
                # Redirect all stdio so the watcher holds none of the hook's handles.
                $si = New-Object Diagnostics.ProcessStartInfo
                $si.FileName = (Get-Process -Id $PID).Path
                $si.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`" __watch $WatchId $ReleaseSeq"
                $si.UseShellExecute = $false
                $si.CreateNoWindow = $true
                $si.RedirectStandardInput = $true
                $si.RedirectStandardOutput = $true
                $si.RedirectStandardError = $true
                $p = [Diagnostics.Process]::Start($si)
                try { $p.StandardInput.Close() } catch {}
            } else {
                try { Add-Content -LiteralPath $LogFile -Value "$Stamp   SessionEnd: parent pid $ParentId unusable, no watcher" } catch {}
            }
        } catch {}
    }
    default { }
}

exit 0   # never block a CoCo turn
