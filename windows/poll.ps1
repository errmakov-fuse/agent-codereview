# Runs one pass of scripts/poll.sh with Git Bash and turns its events into
# Windows notifications. Windows Task Scheduler runs this every POLL_SECONDS
# (see install.ps1); several passes may overlap while reviews run.
#
#   STARTED <key>                     "Reviewing PR #n"
#   POSTED <key> <verdict> <url>      "PR #n approved" / "changes requested" / "commented"
#   NOT_POSTED / FAILED / GAVE_UP     "PR #n not reviewed" with the reason
#   REQUESTED <reviewer> #<n>         no notification, only the log
#
# Every event is also appended to state\events.log.
#
#   -NoToast   print the events only (for a run by hand)

[CmdletBinding()]
param([switch]$NoToast)

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
$stateDir = if ($env:AGENT_CODEREVIEW_STATE) { $env:AGENT_CODEREVIEW_STATE } else { Join-Path $Root 'state' }
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$eventLog = Join-Path $stateDir 'events.log'

function Write-Event([string]$line) {
    $stamped = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $line
    Write-Output $stamped
    [System.IO.File]::AppendAllText($eventLog, $stamped + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Show-Toast([string]$title, [string]$text) {
    if ($NoToast) { return }
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
        Write-Event "NOTIFY_FAILED $($_.Exception.Message)"
    }
}

# "1373@abc..." -> "#1373 (re-review)"
function Format-Key([string]$key) {
    $key = $key -replace '^test-', ''
    if ($key -match '^(\d+)@') { return "#$($Matches[1]) (re-review)" }
    return "#$key"
}

$bash = $config['GIT_BASH']
if (-not $bash -or -not (Test-Path -LiteralPath $bash)) {
    Write-Event "POLL_FAILED Git Bash not found at '$bash' (GIT_BASH in config.env)"
    Show-Toast 'PR reviewer is broken' "Git Bash was not found at '$bash'. Set GIT_BASH in config.env."
    exit 1
}
$script = (Join-Path $Root 'scripts\poll.sh') -replace '\\', '/'

# Native stderr would become error records in Windows PowerShell; poll.sh logs its
# own errors to state\poll.log, so it is dropped here.
$ErrorActionPreference = 'Continue'
& $bash $script 2>$null | ForEach-Object {
    $line = "$_".Trim()
    if (-not $line) { return }
    Write-Event $line
    $words = $line -split ' ', 5
    switch ($words[0]) {
        'STARTED' { Show-Toast "Reviewing PR $(Format-Key $words[1])" 'A review run has started.' }
        'POSTED' {
            $what = switch ($words[2]) {
                'approve' { 'approved' }
                'request-changes' { 'changes requested' }
                default { 'review posted as a comment' }
            }
            Show-Toast "PR $(Format-Key $words[1]): $what" $words[3]
        }
        'NOT_POSTED' { Show-Toast "PR $(Format-Key $words[1]) not reviewed" (($words | Select-Object -Skip 2) -join ' ') }
        'FAILED' { Show-Toast "PR $(Format-Key $words[1]): review run failed" 'It is tried again on a later poll. See state\poll.log.' }
        'GAVE_UP' { Show-Toast "PR $(Format-Key $words[1]): giving up" 'Its review runs failed repeatedly. Review it by hand, or run scripts/run_review.sh.' }
        'POLL_FAILED' { Show-Toast 'PR reviewer cannot list PRs' 'See state\poll.log; usually gh auth or the network.' }
    }
}
exit 0
