# Bootstrap for the motortown-win KVM guest (Windows Server 2022).
# Idempotent: safe to re-run; converges the guest to the declared state.
# NOTE: stored as ASCII only; the byte-exact server config (containing the
# star characters) is deployed from GameUserSettings.ini.b64.
$ErrorActionPreference = "Stop"

function Step($name) { Write-Host "== $name" }

# --- 1. VC++ 2015-2022 redistributable (UE4SS.dll needs >= 14.4x exports) ---
Step "VC++ redistributable"
$key = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" -ErrorAction SilentlyContinue
$needVC = $true
if ($key -and $key.Version) {
  $v = [Version]$key.Version
  if ($v -ge [Version]"14.44.35211") { $needVC = $false }
}
if ($needVC) {
  curl.exe -sL -o C:\mtserver\vc_redist.x64.exe https://aka.ms/vs/17/release/vc_redist.x64.exe
  Start-Process -FilePath C:\mtserver\vc_redist.x64.exe -ArgumentList "/install","/quiet","/norestart" -Wait
  Write-Host "vc redist installed"
} else {
  Write-Host "vc redist already current: $($key.Version)"
}

# --- 2. Windows Firewall allow rules (query/game ports, WebAPI) ---
Step "Firewall rules"
$rules = @(
  @{n="MT Dedi UDP in";       p="7777,7778,27015,27016"},
  @{n="MT Dedi WebAPI in";    p="8080"}
)
foreach ($r in $rules) {
  $exists = Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue
  if (-not $exists) {
    New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol UDP -LocalPort ($r.p -split ",") -Action Allow | Out-Null
    Write-Host "added $($r.n)"
  } else { Write-Host "exists $($r.n)" }
}
# exe allow rule for the dedi (any port)
$exe = "C:\mtserver\MotorTown\Binaries\Win64\MotorTownServer-Win64-Shipping.exe"
if (-not (Get-NetFirewallRule -DisplayName "MT Dedi exe in" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "MT Dedi exe in" -Direction Inbound -Program $exe -Action Allow | Out-Null
  Write-Host "added exe rule"
} else { Write-Host "exists exe rule" }

# --- 3. Vector log shipper ---
Step "Vector"
$vecZip = "C:\vector\vector.zip"
if (-not (Test-Path "C:\vector\bin\vector.exe")) {
  New-Item -ItemType Directory -Force -Path C:\vector | Out-Null
  curl.exe -sL -o $vecZip https://packages.timber.io/vector/0.46.1/vector-x86_64-pc-windows-msvc.zip
  Expand-Archive -Force $vecZip C:\vector\
  Write-Host "vector installed"
} else { Write-Host "vector already installed" }
New-Item -ItemType Directory -Force -Path C:\vector\data | Out-Null
# vector.toml is pushed next to this script by provision_guest.py
Copy-Item "C:\mtserver\bootstrap\vector.toml" "C:\vector\vector.toml" -Force
# register as an auto-start service (idempotent)
$svc = Get-Service -Name "VectorLogs" -ErrorAction SilentlyContinue
if (-not $svc) {
  sc.exe create VectorLogs binPath= "C:\vector\bin\vector.exe -c C:\vector\vector.toml" start= auto DisplayName= "Vector log shipper"
  Write-Host "service created"
} else { Write-Host "service exists" }

# --- 4. Server config (byte-exact, from base64) ---
Step "Server config"
$b64File = "C:\mtserver\bootstrap\GameUserSettings.ini.b64"
$dst = "C:\mtserver\MotorTown\Saved\Config\WindowsServer\GameUserSettings.ini"
if ((Get-FileHash $dst -Algorithm SHA256).Hash -ne (Get-FileHash $b64File -Algorithm SHA256).Hash) {
  [IO.File]::WriteAllBytes($dst, [Convert]::FromBase64String([IO.File]::ReadAllText($b64File)))
  Write-Host "config written from base64"
} else { Write-Host "config already matches" }

# --- 5. start-dedi.cmd ---
Step "start-dedi.cmd"
Copy-Item "C:\mtserver\bootstrap\start-dedi.cmd" "C:\mtserver\start-dedi.cmd" -Force
Write-Host "start-dedi.cmd deployed"

# --- 6. Pagefile (OOM protection: 16 GB) ---
Step "Pagefile"
$pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
if (-not $pf) {
  $cs = Get-CimInstance Win32_ComputerSystem
  if ($cs.AutomaticManagedPagefile) {
    Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$false}
  }
  New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name="C:\pagefile.sys"; InitialSize=16384; MaximumSize=16384} | Out-Null
  Write-Host "pagefile set to 16 GB"
} else { Write-Host "pagefile configured" }

# --- 7. DediStart scheduled task (S4U, highest privileges) ---
Step "DediStart task"
schtasks /create /f /tn DediStart /xml "C:\mtserver\bootstrap\DediStart-task.xml" | Out-Null
Write-Host "DediStart task registered"

Write-Host "BOOTSTRAP COMPLETE"
