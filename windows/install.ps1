# Registers (or, with -Remove, deletes) the scheduled task that runs poll.ps1 for
# the current user every POLL_SECONDS. No administrator rights are needed. It also
# removes the task of the older design ("agent-codereview supervisor"), which
# started a long-lived Claude session instead.
#
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Remove

[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$TaskName = 'agent-codereview poll'
$OldTaskName = 'agent-codereview supervisor'
$Root = Split-Path -Parent $PSScriptRoot

function Remove-TaskIfPresent([string]$name) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Output "Removed '$name'."
    }
}

Remove-TaskIfPresent $OldTaskName
if ($Remove) {
    Remove-TaskIfPresent $TaskName
    exit 0
}

$config = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $Root 'config.env')) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') { $config[$Matches[1]] = $Matches[2].Trim().Trim('"') }
}
$everyMinutes = [math]::Max(1, [math]::Round([int]$config['POLL_SECONDS'] / 60))
$runLimitMinutes = [int]$config['RUN_TIMEOUT_MINUTES'] + 30

$script = Join-Path $PSScriptRoot 'poll.ps1'
# conhost --headless runs the script without a console window flashing up on
# every run. The task only runs while the user is logged on, which is also when
# gh and Claude Code have their logins.
$command = 'conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script

schtasks.exe /Create /TN $TaskName /TR $command /SC MINUTE /MO $everyMinutes /F
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# schtasks leaves the task unable to start on battery power, which on a laptop
# means it rarely runs. Also: catch up after a missed run, and let passes overlap,
# because a pass waits for the reviews it started, which may take an hour.
# poll.sh and run_review.sh keep overlapping passes from reviewing a PR twice.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances Parallel -ExecutionTimeLimit (New-TimeSpan -Minutes $runLimitMinutes)
Set-ScheduledTask -TaskName $TaskName -Settings $settings | Out-Null

Write-Output "Installed '$TaskName': every $everyMinutes minutes while you are logged on."
Write-Output "Events: $(Join-Path $Root 'state\events.log'); reviews: $(Join-Path $Root 'state\reviews.log')"
