# Keeps the SSM port-forward to inkhub-db alive: localhost:15432 -> RDS:5432.
# Usage: powershell -ExecutionPolicy Bypass -File C:\Users\DenisErmakov\www\agent-codereview\tools\ssm-tunnel\ssm-tunnel-watch.ps1
# Stop with Ctrl+C.

$Profile_   = 'InkhubDeveloperAccess-660505295667'
$Region     = 'us-east-1'
$Target     = 'i-029c240d2b484bc3b'
$RemoteHost = 'inkhub-db.chuc67gvfvrq.us-east-1.rds.amazonaws.com'
$LocalPort  = 15432

$MinDelay = 5     # seconds before a restart
$MaxDelay = 120   # backoff cap when the tunnel keeps dying fast (e.g. expired SSO)
$Delay    = $MinDelay

while ($true) {
    $busy = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
    if ($busy) {
        Write-Host "$(Get-Date -f 'HH:mm:ss') port $LocalPort already in use, waiting..."
        Start-Sleep -Seconds 30
        continue
    }

    Write-Host "$(Get-Date -f 'HH:mm:ss') starting tunnel"
    $started = Get-Date
    aws ssm start-session --profile $Profile_ --region $Region --target $Target `
        --document-name AWS-StartPortForwardingSessionToRemoteHost `
        --parameters "host=$RemoteHost,portNumber=5432,localPortNumber=$LocalPort"
    $code = $LASTEXITCODE
    $upFor = [int]((Get-Date) - $started).TotalSeconds

    # A quick exit means something is wrong (auth, network), so wait longer each time.
    if ($upFor -lt 60) { $Delay = [Math]::Min($Delay * 2, $MaxDelay) } else { $Delay = $MinDelay }
    if ($code -ne 0 -and $upFor -lt 60) {
        Write-Host "  hint: if the SSO session expired, run: aws sso login --profile $Profile_"
    }
    Write-Host "$(Get-Date -f 'HH:mm:ss') tunnel exited (code $code, up ${upFor}s), restarting in ${Delay}s"
    Start-Sleep -Seconds $Delay
}
