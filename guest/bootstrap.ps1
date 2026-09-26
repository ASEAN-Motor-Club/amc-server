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

# --- 2. Windows Firewall allow rules ---
Step "Firewall rules"
$rules = @(
  @{n="MT Dedi UDP in";       proto="UDP"; p=@(7777,7778,27015,27016)},
  @{n="MT Dedi WebAPI in";    proto="TCP"; p=@(8080)},
  @{n="MT Dedi Mod API in";   proto="TCP"; p=@(5000,5001)}
)
foreach ($r in $rules) {
  $exists = Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue
  if (-not $exists) {
    New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol $r.proto -LocalPort $r.p -Action Allow | Out-Null
    Write-Host "added $($r.n) ($($r.proto) $($r.p -join ','))"
  } else { Write-Host "exists $($r.n)" }
}
# exe allow rule for the dedi (any port)
$exe = "C:\mtserver\MotorTown\Binaries\Win64\MotorTownServer-Win64-Shipping.exe"
if (-not (Get-NetFirewallRule -DisplayName "MT Dedi exe in" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName "MT Dedi exe in" -Direction Inbound -Program $exe -Action Allow | Out-Null
  Write-Host "added exe rule"
} else { Write-Host "exists exe rule" }

# --- 3. Steam client + steamclient service (gives the dedi `Steam: Y`) ---
Step "Steam"
$steamSvc = Get-Service -Name "SteamClientService" -ErrorAction SilentlyContinue
if (-not $steamSvc) {
  $steamDir = "C:\Program Files (x86)\Steam"
  if (-not (Test-Path "$steamDir\steam.exe")) {
    curl.exe -sL -o C:\mtserver\SteamSetup.exe https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe
    Start-Process -FilePath C:\mtserver\SteamSetup.exe -ArgumentList "/S" -Wait
  }
  if (Test-Path "$steamDir\steam.exe") {
    # one run registers the machine-wide steamclient service
    Start-Process -FilePath "$steamDir\steam.exe" -ArgumentList "-repair" -Wait
    $steamSvc = Get-Service -Name "SteamClientService" -ErrorAction SilentlyContinue
  }
}
if ($steamSvc) { Write-Host "steamclient service present" }
else { Write-Host "WARN: steamclient service still missing" }

# --- 4. steamcmd ---
Step "steamcmd"
if (-not (Test-Path "C:\steamcmd\steamcmd.exe")) {
  New-Item -ItemType Directory -Force -Path C:\steamcmd | Out-Null
  curl.exe -sL -o C:\steamcmd\steamcmd.zip https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip
  Expand-Archive -Force C:\steamcmd\steamcmd.zip C:\steamcmd\
  Write-Host "steamcmd installed"
} else { Write-Host "steamcmd already installed" }
# update_mt.bat (club creds, generated host-side) is pushed by provision_guest.py
# via WinRM base64, NOT over the plain-HTTP route.
$bat = "C:\steamcmd\update_mt.bat"
if (Test-Path $bat) {
  if (-not (Test-Path "C:\mtserver\MotorTown\Binaries\Win64\MotorTownServer-Win64-Shipping.exe")) {
    Write-Host "dedi exe MISSING - running update_mt.bat (long: ~2 GB download)"
    $p = Start-Process -FilePath "C:\steamcmd\steamcmd.exe" -ArgumentList "+runscript","C:\steamcmd\update_mt.bat" -Wait -PassThru
    Write-Host "steamcmd exit code: $($p.ExitCode)"
  } else { Write-Host "dedi exe present" }
} else {
  Write-Host "WARN: update_mt.bat absent (no steam creds on host?) - dedi install is manual"
}

# --- 5. Vector log shipper ---
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
} else {
  sc.exe config VectorLogs start= auto | Out-Null
  Write-Host "service exists"
}
if ((Get-Service -Name "VectorLogs").Status -ne "Running") {
  Start-Service -Name "VectorLogs"
  Write-Host "VectorLogs started"
} else { Write-Host "VectorLogs running" }

# --- 6. Server config (byte-exact, from base64) ---
Step "Server config"
$b64File = "C:\mtserver\bootstrap\GameUserSettings.ini.b64"
$dst = "C:\mtserver\MotorTown\Saved\Config\WindowsServer\GameUserSettings.ini"
$wantHash = (Get-FileHash $b64File -Algorithm SHA256).Hash
$haveHash = $null
if (Test-Path $dst) { $haveHash = (Get-FileHash $dst -Algorithm SHA256).Hash }
if ($haveHash -ne $wantHash) {
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  [IO.File]::WriteAllBytes($dst, [Convert]::FromBase64String([IO.File]::ReadAllText($b64File)))
  Write-Host "config written from base64"
} else { Write-Host "config already matches" }

# --- 7. start-dedi.cmd ---
Step "start-dedi.cmd"
Copy-Item "C:\mtserver\bootstrap\start-dedi.cmd" "C:\mtserver\start-dedi.cmd" -Force
Write-Host "start-dedi.cmd deployed"

# --- 8. Pagefile (OOM protection: 16 GB) ---
Step "Pagefile"
$wantMB = 16384
$pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
if (-not $pf) {
  $cs = Get-CimInstance Win32_ComputerSystem
  if ($cs.AutomaticManagedPagefile) {
    Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$false}
  }
  New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name="C:\pagefile.sys"; InitialSize=$wantMB; MaximumSize=$wantMB} | Out-Null
  Write-Host "pagefile set to $wantMB MB (reboot to apply)"
} elseif ($pf.MaximumSize -ne $wantMB) {
  Set-CimInstance -InputObject $pf -Property @{InitialSize=$wantMB; MaximumSize=$wantMB}
  Write-Host "pagefile corrected to $wantMB MB (was $($pf.MaximumSize))"
} else { Write-Host "pagefile configured ($wantMB MB)" }

# --- 9. DediStart + watchdog scheduled tasks ---
Step "Scheduled tasks"
schtasks /create /f /tn DediStart /xml "C:\mtserver\bootstrap\DediStart-task.xml" | Out-Null
Write-Host "DediStart task registered"
schtasks /create /f /tn MTDediWatchdog /xml "C:\mtserver\bootstrap\MTDediWatchdog-task.xml" | Out-Null
Copy-Item "C:\mtserver\bootstrap\watchdog.ps1" "C:\mtserver\watchdog.ps1" -Force
Write-Host "MTDediWatchdog task registered (inert unless C:\mtserver\DEDI_ENABLED exists)"

# --- 10. Mods / UE4SS ---
Step "Mods / UE4SS"
$ue4ssDir = "C:\mtserver\MotorTown\Binaries\Win64\ue4ss"
$marker = Join-Path $ue4ssDir ".installed-mod-version"
$wantMod = $null
$mvFile = "C:\mtserver\bootstrap\mod-version.txt"
if (Test-Path $mvFile) { $wantMod = (Get-Content $mvFile -Raw).Trim() }
$haveMod = $null
if (Test-Path $marker) { $haveMod = (Get-Content $marker -Raw).Trim() }
# optional: a mod zip staged by provision_guest.py under C:\mtserver\bootstrap\mod\
$zip = Get-ChildItem "C:\mtserver\bootstrap\mod\MotorTownMods_*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($zip -and $wantMod -and $haveMod -ne $wantMod) {
  Write-Host "installing mod $($zip.Name)"
  $tmp = "C:\mtserver\bootstrap\mod\extract"
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Expand-Archive -Force $zip.FullName $tmp
  Copy-Item "$tmp\ue4ss" "C:\mtserver\MotorTown\Binaries\Win64\" -Recurse -Force
  Copy-Item "$tmp\version.dll" "C:\mtserver\MotorTown\Binaries\Win64\" -Force
  $sig = "C:\mtserver\bootstrap\mod\sig\UE4SS_Signatures"
  if (Test-Path $sig) {
    Copy-Item $sig "$ue4ssDir\UE4SS_Signatures" -Recurse -Force
  }
  # the pak from the zip goes into the game's Paks dir
  Get-ChildItem $tmp -Recurse -Filter "*SERVER_P.pak" | ForEach-Object {
    Copy-Item $_.FullName "C:\mtserver\MotorTown\Content\Paks\" -Force
    Write-Host "pak installed: $($_.Name)"
  }
  [IO.File]::WriteAllText($marker, $wantMod)
  Write-Host "mod installed, marker = $wantMod"
} elseif ($wantMod -and $haveMod -ne $wantMod) {
  Write-Host "WARN: mod marker $haveMod != desired $wantMod; stage a MotorTownMods zip via provision_guest.py MOD_ZIP"
} elseif ($haveMod) {
  Write-Host "mod current: $haveMod"
} else {
  Write-Host "WARN: no mod marker and no staged zip - UE4SS/mods not installed"
}

Write-Host "BOOTSTRAP COMPLETE"
