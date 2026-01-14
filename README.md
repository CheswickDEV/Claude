# .NET Framework 4.8 Deployment Toolkit

PowerShell-Skript zur automatisierten Verteilung von .NET Framework 4.8 auf Windows-Servern via WinRM/PSRemoting.

## Übersicht

Dieses Repository enthält ein optimiertes Deployment-Skript, das den .NET Framework 4.8 Offline-Installer auf mehrere Server kopiert und installiert. Es wurde speziell für Umgebungen mit Jumpservern entwickelt und umgeht das Double-Hop-Problem durch lokale Dateiablage.

## Voraussetzungen

### Auf dem Jumpserver (Ausführungsort)
- Windows PowerShell 5.1 oder höher
- .NET Framework 4.8 Offline-Installer ([Download von Microsoft](https://dotnet.microsoft.com/download/dotnet-framework/net48))
- Netzwerkzugriff auf die Zielserver (Port 5985/5986)

### Auf den Zielservern
- Windows Server 2012 R2, 2016, 2019 oder 2022
- WinRM aktiviert (`Enable-PSRemoting -Force`)
- Administratorrechte für das verwendete Konto
- Ausreichend Speicherplatz (~70 MB temporär)

## Installation

1. Repository klonen oder Skript herunterladen:
   ```powershell
   git clone https://github.com/CheswickDEV/Claude.git
   cd Claude
   ```

2. .NET 4.8 Offline-Installer herunterladen und ablegen:
   ```powershell
   # Beispiel: C:\Install\ndp48-x86-x64-allos-enu.exe
   ```

3. Skript konfigurieren (siehe Konfiguration unten)

## Konfiguration

Öffnen Sie `Install-DotNet48-Optimized.ps1` und passen Sie den Konfigurationsbereich an:

```powershell
# Liste der Zielserver
$ServerListe = @(
    "SRV01",
    "SRV02",
    "APP-SERVER-01"
)

# Pfad zum Offline-Installer
$LokalerInstallerPfad = "C:\Install\ndp48-x86-x64-allos-enu.exe"

# Temporärer Pfad auf Zielservern
$RemoteTempOrdner = "C:\Windows\Temp\DotNetDeploy"

# Timeout in Sekunden (Standard: 30 Min)
$InstallationTimeout = 1800
```

## Verwendung

```powershell
# Skript ausführen
.\Install-DotNet48-Optimized.ps1

# Bei Aufforderung Admin-Credentials eingeben
```

### Beispielausgabe

```
========================================
 .NET Framework 4.8 Deployment
========================================
Zielserver: 4
Installer:  ndp48-x86-x64-allos-enu.exe

[SRV01] Verarbeite...
  -> Verbinde...
  -> Erstelle Zielordner...
  -> Kopiere Installer (48.52 MB)...
  -> Installiere .NET Framework 4.8...
  -> Bereinige...
  => RebootRequired: Installation OK, Neustart erforderlich

[SRV02] Verarbeite...
  => Skipped: Bereits installiert (Release: 528049)

========================================
 Abschlussbericht
========================================

Server               Status             Reboot   Nachricht
------               ------             ------   ---------
SRV01                RebootRequired     Ja       Installation OK, Neustart erforderlich
SRV02                Skipped            Nein     Bereits installiert (Release: 528049)

Zusammenfassung:
  RebootRequired: 1
  Skipped: 1

HINWEIS: Folgende Server benötigen einen Neustart:
  - SRV01

Deployment abgeschlossen.
```

## Status-Codes

| Status | Bedeutung |
|--------|-----------|
| `Success` | Installation erfolgreich, kein Neustart nötig |
| `Skipped` | .NET 4.8 bereits installiert |
| `RebootRequired` | Installation erfolgreich, Neustart erforderlich |
| `RebootInitiated` | Installation erfolgreich, Neustart wurde eingeleitet |
| `Failed` | Installation fehlgeschlagen |
| `NotSupported` | Betriebssystem wird nicht unterstützt |
| `ConnectionFailed` | Verbindung zum Server fehlgeschlagen |
| `Cancelled` | Installation wurde abgebrochen |

## .NET 4.8 Release-Keys

Das Skript erkennt installierte .NET-Versionen anhand des Registry-Release-Keys:

| Release-Key | Windows-Version |
|-------------|-----------------|
| 528040 | Windows 10 May 2019 Update (1903+) |
| 528049 | Alle anderen Windows-Versionen |
| 528372 | Windows 10 May 2020 Update (2004+) |
| 528449 | Windows 11 / Server 2022 |

## Fehlerbehebung

### WinRM nicht aktiviert
```powershell
# Auf Zielserver ausführen:
Enable-PSRemoting -Force
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force
```

### Firewall blockiert Verbindung
```powershell
# Port 5985 (HTTP) oder 5986 (HTTPS) öffnen
New-NetFirewallRule -Name "WinRM-HTTP" -DisplayName "WinRM HTTP" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow
```

### Credential-Fehler
- Stellen Sie sicher, dass das Konto lokale Adminrechte auf den Zielservern hat
- Bei Domänenkonten: `DOMAIN\Username` Format verwenden

## Sicherheitshinweise

- Credentials werden nur zur Laufzeit abgefragt und nicht gespeichert
- Temporäre Dateien werden nach Installation automatisch gelöscht
- Installer-Logs verbleiben unter `%TEMP%\dotnet48-install_*.log` auf Zielservern

## Lizenz

Dieses Projekt steht unter der MIT-Lizenz.
