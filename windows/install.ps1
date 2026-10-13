# Registers (or, with -Remove, deletes) the scheduled task that runs supervise.ps1
# for the current user. No administrator rights are needed.
#
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Remove

[CmdletBinding()]
param(
    [int]$EveryMinutes = 10,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$TaskName = 'agent-codereview supervisor'

if ($Remove) {
    schtasks.exe /Delete /TN $TaskName /F
    exit $LASTEXITCODE
}

$script = Join-Path $PSScriptRoot 'supervise.ps1'
# conhost --headless runs the script without a console window flashing up on
# every run. The task only runs while the user is logged on, which is also the
# only time the agent can run.
$command = 'conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script

schtasks.exe /Create /TN $TaskName /TR $command /SC MINUTE /MO $EveryMinutes /F
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Output "Installed '$TaskName': every $EveryMinutes minutes while you are logged on."
Write-Output "Log: $(Join-Path (Split-Path -Parent $PSScriptRoot) 'state\supervise.log')"
