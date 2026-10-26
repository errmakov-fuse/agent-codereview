# Keeps the PR review agent running. Meant to be run every few minutes by Windows
# Task Scheduler (see install.ps1), outside Claude, so it survives what the agent
# cannot: a reboot, a crashed session, a closed terminal.
#
# Each run:
#   heartbeat fresh                  -> nothing to do
#   heartbeat stale, no agent        -> start one in the background and say so
#   heartbeat stale, agent listed    -> give the agent's own watchdog time; once the
#                                       heartbeat is older than -TakeOverAfterMinutes
#                                       the session is taken to have lost its watcher
#                                       (a session restored after a reboot has no
#                                       watcher and no watchdog) and a new one is started
#
# It starts at most -MaxStartsPerDay sessions a day, so a session that keeps dying
# cannot turn into a loop that spends tokens. After that it only alerts, once.
#
#   -DryRun   print what it would do; start nothing, show nothing

[CmdletBinding()]
param(
    [int]$TakeOverAfterMinutes = 15,
    [int]$MaxStartsPerDay = 6,
    [switch]$DryRun,
    # For tests: another state directory, session name or first prompt.
    [string]$StateDir,
    [string]$SessionName,
    [string]$Prompt
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

function Read-Config([string]$path) {
    $config = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*([A-Z_]+)=(.*)$') {
            $config[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }
    return $config
}

$configPath = if ($env:AGENT_CODEREVIEW_CONFIG) { $env:AGENT_CODEREVIEW_CONFIG } else { Join-Path $Root 'config.env' }
$config = Read-Config $configPath
if (-not $StateDir) {
    $StateDir = if ($env:AGENT_CODEREVIEW_STATE) { $env:AGENT_CODEREVIEW_STATE } else { Join-Path $Root 'state' }
}
if (-not $SessionName) { $SessionName = $config['AGENT_SESSION_NAME'] }
if (-not $Prompt) {
    $agentFile = (Join-Path $Root 'AGENT.md') -replace '\\', '/'
    $Prompt = "Read $agentFile and follow it."
}
$maxAgeSeconds = [int]$config['HEARTBEAT_MAX_AGE_SECONDS']
$checkout = $config['LOCAL_CHECKOUT']

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$logFile = Join-Path $StateDir 'supervise.log'
$alertFlag = Join-Path $StateDir 'supervise.alerted'

function Write-Log([string]$message) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $message
    Write-Output $line
    # Without a byte-order mark: Get-StartsToday matches on the start of each line.
    if (-not $DryRun) {
        [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

# One line of plain ASCII from a command's output, for the log.
function Format-Output([string]$text) {
    return (($text -replace '[^\x20-\x7E]+', ' ') -replace '\s+', ' ').Trim()
}

function Show-Toast([string]$title, [string]$text) {
    if ($DryRun) { Write-Output "DRY_RUN would notify: $title - $text"; return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $nodes = $template.GetElementsByTagName('text')
        $nodes.Item(0).AppendChild($template.CreateTextNode($title)) | Out-Null
        $nodes.Item(1).AppendChild($template.CreateTextNode($text)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        # Windows PowerShell's own app id, so the toast needs no registration.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    }
    catch {
        Write-Log "could not show a notification: $($_.Exception.Message)"
    }
}

function Get-HeartbeatAgeSeconds {
    $file = Join-Path $StateDir 'heartbeat'
    if (-not (Test-Path -LiteralPath $file)) { return [int]::MaxValue }
    $beat = 0L
    if (-not [long]::TryParse((Get-Content -LiteralPath $file -TotalCount 1).Trim(), [ref]$beat)) { return [int]::MaxValue }
    if ($beat -eq 0) {
        # watch_prs.sh writes 0 when it exits: count from the exit, so a watcher
        # that just handed over a PR gets the same grace as one that went quiet.
        $beat = ([DateTimeOffset](Get-Item -LiteralPath $file).LastWriteTimeUtc).ToUnixTimeSeconds()
    }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $beat
    if ($age -gt [int]::MaxValue) { return [int]::MaxValue }
    return [int]$age
}

function Get-Claude {
    $command = Get-Command claude -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw 'claude was not found on PATH or in ~/.local/bin'
}

# A session that is neither finished nor failed, whose name is the agent's name.
# A fork of it is named "<name> <fork mark> ...", so the prefix counts too.
function Test-AgentSessionAlive([string]$claude) {
    $json = & $claude agents --json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { throw 'claude agents --json failed' }
    foreach ($session in ($json | ConvertFrom-Json)) {
        $isAgent = ($session.name -eq $SessionName) -or ($session.name -like "$SessionName *")
        if ($isAgent -and $session.state -notin @('done', 'failed')) { return $true }
    }
    return $false
}

function Get-StartsToday {
    if (-not (Test-Path -LiteralPath $logFile)) { return 0 }
    $today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    return @(Get-Content -LiteralPath $logFile | Where-Object { $_ -like "$today*" -and $_ -like '*started session*' }).Count
}

$age = Get-HeartbeatAgeSeconds
if ($age -le $maxAgeSeconds) {
    if (-not $DryRun -and (Test-Path -LiteralPath $alertFlag)) {
        Remove-Item -LiteralPath $alertFlag -Force
        Write-Log "watcher is alive again (heartbeat ${age}s ago)"
    }
    Write-Output "OK heartbeat ${age}s ago"
    exit 0
}

$ageText = if ($age -eq [int]::MaxValue) { 'no heartbeat yet' } else { "heartbeat $([math]::Round($age / 60)) min ago" }
$claude = Get-Claude

$sessionListed = Test-AgentSessionAlive $claude
if ($sessionListed -and $age -le $TakeOverAfterMinutes * 60) {
    Write-Output "WAITING session '$SessionName' is running, $ageText"
    exit 0
}
$reason = if ($sessionListed) { "a session is listed but its watcher is silent, $ageText" } else { "no session is running, $ageText" }

if ((Get-StartsToday) -ge $MaxStartsPerDay) {
    if (-not (Test-Path -LiteralPath $alertFlag)) {
        Write-Log "$reason; $MaxStartsPerDay starts already today, not starting another"
        Show-Toast 'PR reviewer is down' "It was started $MaxStartsPerDay times today and is down again. Start it by hand."
        if (-not $DryRun) { Set-Content -LiteralPath $alertFlag -Value $age }
    }
    exit 1
}

if ($DryRun) {
    Write-Output "DRY_RUN would start session '$SessionName' in $checkout ($reason)"
    exit 0
}

Push-Location -LiteralPath $checkout
try {
    $output = & $claude --bg -n $SessionName $Prompt 2>&1 | Out-String
    $started = $LASTEXITCODE -eq 0
}
finally {
    Pop-Location
}

if ($started) {
    Write-Log "started session '$SessionName' ($reason): $(Format-Output $output)"
    Show-Toast 'PR reviewer restarted' "A new reviewer session was started: $reason."
    exit 0
}

Write-Log "could not start session '$SessionName': $(Format-Output $output)"
Show-Toast 'PR reviewer is down' 'Starting a new session failed. See state\supervise.log.'
exit 1
