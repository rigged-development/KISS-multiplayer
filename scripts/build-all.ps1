param(
    [switch]$SkipLinux,
    [switch]$SkipWindows,
    [switch]$SetupOnly
)

$ErrorActionPreference = "Stop"
$linuxTarget = "x86_64-unknown-linux-gnu"

function Ensure-Command {
    param([string]$Name, [string]$InstallHint)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "'$Name' wurde nicht gefunden. $InstallHint"
    }
    return $cmd
}

function Ensure-DockerDesktopInstalled {
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($dockerCmd) {
        return
    }

    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wingetCmd) {
        throw "Docker fehlt und 'winget' ist nicht verfuegbar. Bitte Docker Desktop manuell installieren."
    }

    Write-Host "Docker Desktop nicht gefunden. Installiere per winget..."
    winget install -e --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements
}

function Wait-DockerDaemon {
    param([int]$TimeoutSeconds = 120)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        cmd /c "docker info >nul 2>nul"
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds 2
    }

    throw "Docker Daemon ist nicht erreichbar. Starte Docker Desktop und pruefe den Linux-Engine-Modus."
}

function Ensure-DockerReady {
    Ensure-DockerDesktopInstalled
    [void](Ensure-Command -Name "docker" -InstallHint "Bitte Docker Desktop installieren.")

    cmd /c "docker info >nul 2>nul"
    if ($LASTEXITCODE -eq 0) {
        return
    }

    $dockerDesktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerDesktopExe) {
        Write-Host "Docker Daemon nicht bereit. Starte Docker Desktop..."
        Start-Process -FilePath $dockerDesktopExe | Out-Null
    }

    Wait-DockerDaemon -TimeoutSeconds 150
}

function Ensure-Cross {
    $crossCmd = Get-Command cross -ErrorAction SilentlyContinue
    if ($crossCmd) {
        return
    }

    Write-Host "Installiere 'cross'..."
    cargo install cross --locked
}

function Ensure-LinuxTarget {
    rustup target add $linuxTarget | Out-Null
}

if (-not $SkipLinux) {
    Write-Host "[setup] Pruefe Linux-Build-Umgebung..."
    [void](Ensure-Command -Name "cargo" -InstallHint "Bitte Rust via rustup installieren.")
    [void](Ensure-Command -Name "rustup" -InstallHint "Bitte rustup installieren.")
    Ensure-LinuxTarget
    Ensure-DockerReady
    Ensure-Cross
}

if ($SetupOnly) {
    Write-Host "Setup abgeschlossen. Kein Build ausgefuehrt (-SetupOnly)."
    exit 0
}

if (-not $SkipWindows) {
    Write-Host "[1/2] Building Windows artifacts..."
    cargo build --release -p kissmp-bridge -p kissmp-server -p kissmp-master
}

if ($SkipLinux) {
    Write-Host "Linux build skipped by -SkipLinux."
    exit 0
}

Write-Host "[2/2] Building Linux artifacts..."
$env:CROSS_CUSTOM_TOOLCHAIN = "1"
cross build --release --target $linuxTarget -p kissmp-bridge -p kissmp-server -p kissmp-master

