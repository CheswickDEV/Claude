<#
.SYNOPSIS
    All-in-One Skript zur Verteilung von .NET Framework 4.8 auf Servern.

.DESCRIPTION
    Dieses Skript kopiert den Offline-Installer auf eine Liste von Servern,
    führt die Installation lokal aus und bereinigt danach die Dateien.
    Es umgeht das Double-Hop-Problem, indem Dateien lokal abgelegt werden.

.NOTES
    Anpassungen bitte im Bereich "KONFIGURATION" vornehmen.

.VERSION
    2.0 - Korrigierte und optimierte Version
#>

#Requires -Version 5.1

# --- KONFIGURATION ---

# 1. Liste der Zielserver (Namen oder IP-Adressen)
$ServerListe = @(
    "SRV01",
    "SRV02",
    "APP-SERVER-01",
    "DB-SERVER-05"
)

# 2. Pfad zum Offline-Installer auf DIESEM Jumpserver
$LokalerInstallerPfad = "C:\Install\ndp48-x86-x64-allos-enu.exe"

# 3. Temporärer Pfad auf den ZIEL-Servern (wird automatisch erstellt & gelöscht)
$RemoteTempOrdner = "C:\Windows\Temp\DotNetDeploy"

# 4. Timeout für Installation in Sekunden (Standard: 30 Minuten)
$InstallationTimeout = 1800

# ---------------------

# Strikte Fehlerbehandlung aktivieren
$ErrorActionPreference = "Stop"

# Prüfung: Existiert der Installer auf dem Jumpserver?
if (-not (Test-Path -LiteralPath $LokalerInstallerPfad)) {
    Write-Error "Der Installer wurde unter '$LokalerInstallerPfad' nicht gefunden. Bitte Pfad in der Konfiguration prüfen."
    exit 1
}

# Prüfung: Ist es eine .exe Datei?
if ([System.IO.Path]::GetExtension($LokalerInstallerPfad) -ne ".exe") {
    Write-Error "Der angegebene Pfad zeigt nicht auf eine .exe Datei."
    exit 1
}

# Credentials einmalig abfragen
$Creds = Get-Credential -Message "Bitte Admin-Konto für die Zielserver angeben"
if (-not $Creds) {
    Write-Error "Keine Credentials angegeben. Abbruch."
    exit 1
}

# --- DEFINITION DES WORKER-SKRIPTBLOCKS ---
# Dieser ScriptBlock wird direkt auf den Zielservern ausgeführt
$WorkerScriptBlock = {
    param(
        [string]$InstallerPath,
        [int]$TimeoutSeconds
    )

    $LogPath = Join-Path $env:TEMP "dotnet48-install_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

    function Get-NetFrameworkRelease {
        try {
            $regPath = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
            $releaseKey = Get-ItemProperty -Path $regPath -Name "Release" -ErrorAction SilentlyContinue
            return $releaseKey.Release
        }
        catch {
            return $null
        }
    }

    # .NET 4.8 Release Keys:
    # 528040 = Windows 10 May 2019 Update (1903) und später (mit .NET 4.8 vorinstalliert)
    # 528049 = Alle anderen Windows-Versionen mit .NET 4.8
    # 528372 = Windows 10 May 2020 Update (2004) und später
    # 528449 = Windows 11 und Windows Server 2022
    # Minimum für .NET 4.8 ist 528040
    $MinRelease = 528040

    $currentRelease = Get-NetFrameworkRelease
    if ($currentRelease -and $currentRelease -ge $MinRelease) {
        return [PSCustomObject]@{
            Status      = "Skipped"
            Message     = "Bereits installiert (Release: $currentRelease)"
            ExitCode    = 0
            LogPath     = $null
            NeedsReboot = $false
        }
    }

    # Prüfe ob Installer existiert
    if (-not (Test-Path -LiteralPath $InstallerPath)) {
        return [PSCustomObject]@{
            Status      = "Error"
            Message     = "Installer nicht gefunden: $InstallerPath"
            ExitCode    = -1
            LogPath     = $null
            NeedsReboot = $false
        }
    }

    # Installation starten
    # WICHTIG: $installArgs statt $args verwenden (automatische Variable!)
    $installArgs = @("/q", "/norestart", "/log", $LogPath)

    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
        $exitCode = $process.ExitCode
    }
    catch {
        return [PSCustomObject]@{
            Status      = "Error"
            Message     = "Fehler beim Starten des Installers: $($_.Exception.Message)"
            ExitCode    = -2
            LogPath     = $LogPath
            NeedsReboot = $false
        }
    }

    # Exit Codes auswerten
    # https://docs.microsoft.com/en-us/dotnet/framework/deployment/deployment-guide-for-developers
    $result = switch ($exitCode) {
        0 {
            [PSCustomObject]@{
                Status      = "Success"
                Message     = "Installation erfolgreich abgeschlossen"
                ExitCode    = 0
                LogPath     = $LogPath
                NeedsReboot = $false
            }
        }
        1602 {
            [PSCustomObject]@{
                Status      = "Cancelled"
                Message     = "Installation wurde abgebrochen"
                ExitCode    = 1602
                LogPath     = $LogPath
                NeedsReboot = $false
            }
        }
        1603 {
            [PSCustomObject]@{
                Status      = "Failed"
                Message     = "Schwerwiegender Fehler während der Installation"
                ExitCode    = 1603
                LogPath     = $LogPath
                NeedsReboot = $false
            }
        }
        1641 {
            [PSCustomObject]@{
                Status      = "RebootInitiated"
                Message     = "Installation OK, Neustart wurde eingeleitet"
                ExitCode    = 1641
                LogPath     = $LogPath
                NeedsReboot = $true
            }
        }
        3010 {
            [PSCustomObject]@{
                Status      = "RebootRequired"
                Message     = "Installation OK, Neustart erforderlich"
                ExitCode    = 3010
                LogPath     = $LogPath
                NeedsReboot = $true
            }
        }
        5100 {
            [PSCustomObject]@{
                Status      = "NotSupported"
                Message     = "Dieses Betriebssystem wird nicht unterstützt"
                ExitCode    = 5100
                LogPath     = $LogPath
                NeedsReboot = $false
            }
        }
        default {
            [PSCustomObject]@{
                Status      = "Unknown"
                Message     = "Unbekannter Exit-Code: $exitCode. Siehe Log für Details."
                ExitCode    = $exitCode
                LogPath     = $LogPath
                NeedsReboot = $false
            }
        }
    }

    return $result
}

# --- HAUPTABLAUF ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " .NET Framework 4.8 Deployment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Zielserver: $($ServerListe.Count)" -ForegroundColor White
Write-Host "Installer:  $(Split-Path $LokalerInstallerPfad -Leaf)" -ForegroundColor White
Write-Host ""

$InstallerSize = [Math]::Round((Get-Item $LokalerInstallerPfad).Length / 1MB, 2)
$InstallerName = Split-Path $LokalerInstallerPfad -Leaf

# Ergebnis-Sammlung
$AllResults = [System.Collections.ArrayList]::new()

# Server einzeln verarbeiten (robuster als parallele Session-Erstellung)
foreach ($Server in $ServerListe) {
    Write-Host "[$Server] " -NoNewline -ForegroundColor Yellow
    Write-Host "Verarbeite..." -ForegroundColor Gray

    $serverResult = [PSCustomObject]@{
        Server      = $Server
        Status      = "Unknown"
        Message     = ""
        ExitCode    = $null
        LogPath     = $null
        NeedsReboot = $false
    }

    try {
        # 1. Session erstellen
        Write-Host "  -> Verbinde..." -ForegroundColor DarkGray
        $session = New-PSSession -ComputerName $Server -Credential $Creds -ErrorAction Stop

        try {
            # 2. Zielordner erstellen
            Write-Host "  -> Erstelle Zielordner..." -ForegroundColor DarkGray
            Invoke-Command -Session $session -ArgumentList $RemoteTempOrdner -ScriptBlock {
                param($Path)
                if (-not (Test-Path -LiteralPath $Path)) {
                    New-Item -Path $Path -ItemType Directory -Force | Out-Null
                }
            }

            # 3. Installer kopieren (KORRIGIERT: Einzelne Session!)
            Write-Host "  -> Kopiere Installer ($InstallerSize MB)..." -ForegroundColor DarkGray
            Copy-Item -Path $LokalerInstallerPfad -Destination $RemoteTempOrdner -ToSession $session -Force

            # 4. Installation ausführen
            Write-Host "  -> Installiere .NET Framework 4.8..." -ForegroundColor DarkGray
            $remoteInstallerPath = Join-Path $RemoteTempOrdner $InstallerName

            $installResult = Invoke-Command -Session $session `
                -ScriptBlock $WorkerScriptBlock `
                -ArgumentList $remoteInstallerPath, $InstallationTimeout

            $serverResult.Status = $installResult.Status
            $serverResult.Message = $installResult.Message
            $serverResult.ExitCode = $installResult.ExitCode
            $serverResult.LogPath = $installResult.LogPath
            $serverResult.NeedsReboot = $installResult.NeedsReboot

            # 5. Bereinigung
            Write-Host "  -> Bereinige..." -ForegroundColor DarkGray
            Invoke-Command -Session $session -ArgumentList $RemoteTempOrdner -ScriptBlock {
                param($Path)
                Start-Sleep -Seconds 2
                Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            # Session immer schließen
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }

        # Status-Ausgabe
        $statusColor = switch ($serverResult.Status) {
            "Success"        { "Green" }
            "Skipped"        { "Cyan" }
            "RebootRequired" { "Yellow" }
            "RebootInitiated"{ "Yellow" }
            default          { "Red" }
        }
        Write-Host "  => $($serverResult.Status): $($serverResult.Message)" -ForegroundColor $statusColor
    }
    catch {
        $serverResult.Status = "ConnectionFailed"
        $serverResult.Message = $_.Exception.Message
        Write-Host "  => FEHLER: $($_.Exception.Message)" -ForegroundColor Red
    }

    [void]$AllResults.Add($serverResult)
    Write-Host ""
}

# --- ABSCHLUSSBERICHT ---

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Abschlussbericht" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Übersichtstabelle
$AllResults | Format-Table -Property @(
    @{Label="Server"; Expression={$_.Server}; Width=20}
    @{Label="Status"; Expression={$_.Status}; Width=18}
    @{Label="Reboot"; Expression={if($_.NeedsReboot){"Ja"}else{"Nein"}}; Width=8}
    @{Label="Nachricht"; Expression={$_.Message}; Width=50}
) -Wrap

# Zusammenfassung
$summary = $AllResults | Group-Object Status
Write-Host "Zusammenfassung:" -ForegroundColor White
foreach ($group in $summary) {
    $color = switch ($group.Name) {
        "Success"         { "Green" }
        "Skipped"         { "Cyan" }
        "RebootRequired"  { "Yellow" }
        "RebootInitiated" { "Yellow" }
        default           { "Red" }
    }
    Write-Host "  $($group.Name): $($group.Count)" -ForegroundColor $color
}

# Reboot-Hinweis
$rebootServers = $AllResults | Where-Object { $_.NeedsReboot -eq $true }
if ($rebootServers) {
    Write-Host ""
    Write-Host "HINWEIS: Folgende Server benötigen einen Neustart:" -ForegroundColor Yellow
    $rebootServers | ForEach-Object { Write-Host "  - $($_.Server)" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Deployment abgeschlossen." -ForegroundColor Green
Write-Host ""

# Rückgabe für Pipeline-Nutzung
return $AllResults
