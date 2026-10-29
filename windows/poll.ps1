# Runs one pass of scripts/watch_pr_updates.sh, then one of scripts/poll.sh,
# with Git Bash and turns their events into Windows notifications. Windows Task
# Scheduler runs this every POLL_SECONDS (see install.ps1); several passes may
# overlap while reviews run. The watcher goes first, so a pass waiting on an
# hour-long review never delays it.
#
# The reviewer's events:
#
#   STARTED <key>                     "Reviewing PR #n"
#   POSTED <key> <verdict> <url>      "PR #n approved" / "changes requested" / "commented"
#   NOT_POSTED / FAILED / GAVE_UP     "PR #n not reviewed" with the reason
#   REQUESTED <reviewer> #<n>         no notification, only the log
#
# The PR update watcher's events:
#
#   NOTIFIED <repo>#<n> <inbox|resume> <id> <summary>   "PR #n: update"
#   NOT_DELIVERED <repo>#<n> <id> <why>                 "PR #n: session <id> not reached"
#   WATCH_GAVE_UP <repo>#<n> <id>                       "PR #n: carry the message by hand"
#   CAPPED_UPDATES <repo>#<n> <count>                   "PR #n: update not forwarded"
#   WATCH_FAILED <why>                                  "PR watcher cannot list sessions"
#   DRY_RUN <what>                                      no notification, only the log
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

# "Org/repo#10" -> "#10"
function Format-PrKey([string]$key) {
    return '#' + ($key -replace '^.*#', '')
}

$bash = $config['GIT_BASH']
if (-not $bash -or -not (Test-Path -LiteralPath $bash)) {
    Write-Event "POLL_FAILED Git Bash not found at '$bash' (GIT_BASH in config.env)"
    Show-Toast 'PR reviewer is broken' "Git Bash was not found at '$bash'. Set GIT_BASH in config.env."
    exit 1
}
$script = (Join-Path $Root 'scripts\poll.sh') -replace '\\', '/'
$watchScript = (Join-Path $Root 'scripts\watch_pr_updates.sh') -replace '\\', '/'

# Native stderr would become error records in Windows PowerShell; poll.sh and the
# watcher log their own errors to state\poll.log, so it is dropped here.
$ErrorActionPreference = 'Continue'

# The watcher runs first. Its failure (exit 1) is reported by WATCH_FAILED and
# must not stop the reviewer's pass below.
& $bash $watchScript 2>$null | ForEach-Object {
    $line = "$_".Trim()
    if (-not $line) { return }
    Write-Event $line
    $words = $line -split ' ', 5
    $pr = Format-PrKey $words[1]
    switch ($words[0]) {
        'NOTIFIED' {
            $did = if ($words[2] -eq 'resume') { 'Resumed' } else { 'Sent to' }
            Show-Toast "PR ${pr}: update" "$($words[4]). $did session $($words[3])."
        }
        'NOT_DELIVERED' { Show-Toast "PR ${pr}: session $($words[2]) not reached" "$(($words | Select-Object -Skip 3) -join ' '). Tried again next pass." }
        'WATCH_GAVE_UP' { Show-Toast "PR ${pr}: carry the message by hand" "Session $($words[2]) could not be reached twice." }
        'CAPPED_UPDATES' { Show-Toast "PR ${pr}: update not forwarded" "$($words[2]) messages today already (PR_UPDATE_MAX_PER_PR_PER_DAY)." }
        'WATCH_FAILED' { Show-Toast 'PR watcher cannot list sessions' 'See state\poll.log.' }
    }
}

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
        'CAPPED' { Show-Toast "PR $($words[1]): no more automatic re-reviews" "Changes were requested $($words[2]) times. The author was asked to re-request your review or talk it through." }
        'POLL_FAILED' { Show-Toast 'PR reviewer cannot list PRs' 'See state\poll.log; usually gh auth or the network.' }
    }
}
exit 0
