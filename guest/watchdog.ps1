# MTDediWatchdog body (registered as a 5-minute scheduled task).
# Inert unless the arm flag exists: only starts the dedi when
# C:\mtserver\DEDI_ENABLED is present AND no MotorTownServer process runs.
# Launches via the DediStart scheduled task (S4U) so the dedi keeps `Steam: Y`
# - a SYSTEM-side direct launch would not.
$flag = "C:\mtserver\DEDI_ENABLED"
if (-not (Test-Path $flag)) { exit 0 }
$proc = Get-Process -Name "MotorTownServer*" -ErrorAction SilentlyContinue
if ($proc) { exit 0 }
schtasks /run /tn DediStart | Out-Null
Write-Output "watchdog: relaunched DediStart at $(Get-Date -Format s)"
