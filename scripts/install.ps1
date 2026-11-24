$ErrorActionPreference = "Stop"

$Repo = "Joooooooooshua/AudioMatrixHub"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\AudioMatrixHub"
$TempDir = $null

try {
    $SourceDir = if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "audiomatrix-desktop.exe"))) {
        $PSScriptRoot
    } else {
        $ZipName = "AudioMatrixHub-v2.0.0-Windows-x64.zip"
        $DownloadUrl = "https://github.com/$Repo/releases/latest/download/$ZipName"
        $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("AudioMatrixHub_" + [System.Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
        $ZipPath = Join-Path $TempDir $ZipName
        Write-Host "Downloading AudioMatrixHub for Windows..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing
        $UnpackDir = Join-Path $TempDir "unpacked"
        Expand-Archive -Path $ZipPath -DestinationPath $UnpackDir -Force
        $UnpackDir
    }

    $GuiSrc = Join-Path $SourceDir "audiomatrix-desktop.exe"
    $CliSrc = Join-Path $SourceDir "audiomatrix-pc.exe"
    if (-not (Test-Path $GuiSrc)) {
        throw "audiomatrix-desktop.exe not found in $SourceDir"
    }

    Get-Process -Name "audiomatrix-desktop" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item $GuiSrc (Join-Path $InstallDir "audiomatrix-desktop.exe") -Force
    Unblock-File -Path (Join-Path $InstallDir "audiomatrix-desktop.exe") -ErrorAction SilentlyContinue

    if (Test-Path $CliSrc) {
        Copy-Item $CliSrc (Join-Path $InstallDir "audiomatrix-pc.exe") -Force
        Unblock-File -Path (Join-Path $InstallDir "audiomatrix-pc.exe") -ErrorAction SilentlyContinue
    }

    # Add install folder to user PATH
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $UserPath) { $UserPath = "" }
    $Segments = $UserPath -split ';' | Where-Object { $_ -ne "" }
    if ($Segments -notcontains $InstallDir) {
        $NewPath = (($Segments + $InstallDir) -join ';')
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    }

    # Create Desktop & Start Menu shortcuts
    $WshShell = New-Object -ComObject WScript.Shell
    $ExePath = Join-Path $InstallDir "audiomatrix-desktop.exe"

    $DesktopDir = [Environment]::GetFolderPath("Desktop")
    if ($DesktopDir -and (Test-Path $DesktopDir)) {
        $DesktopLink = $WshShell.CreateShortcut((Join-Path $DesktopDir "AudioMatrixHub.lnk"))
        $DesktopLink.TargetPath = $ExePath
        $DesktopLink.WorkingDirectory = $InstallDir
        $DesktopLink.Save()
    }

    $StartMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
    New-Item -ItemType Directory -Force -Path $StartMenuDir | Out-Null
    $StartLink = $WshShell.CreateShortcut((Join-Path $StartMenuDir "AudioMatrixHub.lnk"))
    $StartLink.TargetPath = $ExePath
    $StartLink.WorkingDirectory = $InstallDir
    $StartLink.Save()

    Write-Host "Installed AudioMatrixHub to $InstallDir"
    Write-Host "Created Desktop & Start Menu shortcuts and added audiomatrix-pc.exe to PATH."

    if (-not $env:CI) {
        Start-Process -FilePath $ExePath
    }
} finally {
    if ($TempDir -and (Test-Path $TempDir)) {
        Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
    }
}
