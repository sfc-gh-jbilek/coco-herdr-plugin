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
[long]$Last = 0
try { [long]::TryParse((Get-Content -LiteralPath $SeqFile -Raw).Trim(), [ref]$Last) | Out-Null } catch {}
[long]$Now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
if ($Now -gt $Last) { $Seq = $Now } else { $Seq = $Last + 1 }
try { [IO.File]::WriteAllText($SeqFile, "$Seq") } catch {}

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

# Per-pane event log for troubleshooting ($coco-herdr-plugin:doctor reads it).
$LogFile = Join-Path $SeqDir "events.$PaneFile.log"
$Stamp = Get-Date -Format 'HH:mm:ss'
try { Add-Content -LiteralPath $LogFile -Value "$Stamp $Event tool=$ToolName [plugin]" } catch {}
try {
    $lines = @(Get-Content -LiteralPath $LogFile)
    if ($lines.Count -gt 400) { Set-Content -LiteralPath $LogFile -Value ($lines | Select-Object -Last 200) }
} catch {}

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

function Rename-TabFromTitle {
    # Cortex writes "<title> (cortex)". Copy it onto the tab when the label is
    # still the process name, a number, or the previous name this pane set.
    $raw = ''
    try { $raw = (& $HerdrBin pane get $Pane 2>$null | Out-String) } catch { return }
    if (-not $raw -or $raw.IndexOf('{') -lt 0) { return }
    $pane = $null
    try { $pane = ($raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json).result.pane } catch { return }
    if ($null -eq $pane) { return }
    $title = ''
    if ($pane.terminal_title_stripped) { $title = [string]$pane.terminal_title_stripped }
    elseif ($pane.terminal_title) { $title = [string]$pane.terminal_title }
    $title = $title.Trim()
    $suffix = ' (cortex)'
    if ($title.EndsWith($suffix)) { $title = $title.Substring(0, $title.Length - $suffix.Length).Trim() }
    $title = [regex]::Replace($title, '^[^0-9A-Za-z]+', '').Trim()
    if (-not $title -or $title -eq 'cortex' -or $title -eq 'coco' -or $title.StartsWith('-')) { return }
    if ($title.Length -gt 48) {
        $cut = $title.Substring(0, 48)
        $sp = $cut.LastIndexOf(' ')
        if ($sp -ge 24) { $title = $cut.Substring(0, $sp).TrimEnd() } else { $title = $cut.TrimEnd() }
    }
    $tabId = [string]$pane.tab_id
    if (-not $tabId) { return }
    $traw = ''
    try { $traw = (& $HerdrBin tab get $tabId 2>$null | Out-String) } catch { return }
    if (-not $traw -or $traw.IndexOf('{') -lt 0) { return }
    $tab = $null
    try { $tab = ($traw.Substring($traw.IndexOf('{')) | ConvertFrom-Json).result.tab } catch { return }
    $label = ''
    if ($null -ne $tab -and $tab.label) { $label = [string]$tab.label }
    $lastFile = Join-Path $SeqDir "tabname.$PaneFile"
    $last = ''
    try { $last = (Get-Content -LiteralPath $lastFile -Raw).Trim() } catch {}
    if ($label -eq $title) {
        try { [IO.File]::WriteAllText($lastFile, $title) } catch {}
        return
    }
    $placeholder = (-not $label) -or ($label -eq 'cortex') -or ($label -eq 'coco') -or ($label -match '^[0-9]+$')
    if (-not $placeholder -and $label -ne $last) { return }
    $global:LASTEXITCODE = -1
    try { & $HerdrBin tab rename $tabId $title *> $null } catch { return }
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { return }
    try { [IO.File]::WriteAllText($lastFile, $title) } catch {}
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
    'SessionStart' { Send-Report 'idle'; Rename-TabFromTitle }
    'UserPromptSubmit' { Send-Report 'working'; Rename-TabFromTitle }
    { $_ -in 'PreToolUse', 'PostToolUse' } { Send-Report 'working' }
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
    'Stop' { Send-Report 'idle'; Rename-TabFromTitle }
    'SessionEnd' {
        # Cortex fires SessionEnd when a turn ends, while this process is still
        # in the foreground and the prompt is still open. release-agent here
        # drops the sidebar row, and autorename then replaces the conversation
        # title with "cortex". Herdr clears the row once the process has exited
        # and the pane is back at a shell prompt.
        Send-Report 'idle'
        Rename-TabFromTitle
    }
    default { }
}

exit 0   # never block a CoCo turn
