# Settings
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Pro'
$OSActivation = 'Retail'
$OSLanguage = 'de-de'
$GroupTag = 'AutopilotHybridFR'
$TimeZone = 'W. Europe Standard Time'
$TimeServerUrl = "https://time.now/developer/api/timezone/Europe/Berlin"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error')]
        [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format 'HH:mm:ss'
    switch ($Level) {
        'Info'    { Write-Host "[$timestamp] $Message" -ForegroundColor Cyan }
        'Success' { Write-Host "[$timestamp] $Message" -ForegroundColor Green }
        'Warning' { Write-Host "[$timestamp] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "[$timestamp] $Message" -ForegroundColor Red }
    }
}

function Write-Fail {
    param([string]$Message)
    Write-Log $Message Error
    $Host.UI.RawUI.BackgroundColor = 'DarkRed'
    Clear-Host
    Write-Log "FEHLER: $Message" Error
    Write-Log "Warte 5 Sekunden..." Warning
    Start-Sleep -Seconds 5
    $Host.UI.RawUI.BackgroundColor = 'DarkBlue'
    Clear-Host
}

# TLS 1.2 erzwingen
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Log "TLS 1.2 gesetzt" Success

# Variablen lesen - Process-Scope zuerst
Write-Log "Lese Umgebungsvariablen..." Info
$TenantID  = [Environment]::GetEnvironmentVariable('OSDCloudAPTenantID',  'Process')
$AppID     = [Environment]::GetEnvironmentVariable('OSDCloudAPAppID',     'Process')
$AppSecret = [Environment]::GetEnvironmentVariable('OSDCloudAPAppSecret', 'Process')

# Fallback: Machine-Scope
if ([string]::IsNullOrEmpty($TenantID)) {
    Write-Log "Process-Scope leer, versuche Machine-Scope..." Warning
    $TenantID  = [Environment]::GetEnvironmentVariable('OSDCloudAPTenantID',  'Machine')
    $AppID     = [Environment]::GetEnvironmentVariable('OSDCloudAPAppID',     'Machine')
    $AppSecret = [Environment]::GetEnvironmentVariable('OSDCloudAPAppSecret', 'Machine')
}

# Fallback: $env:
if ([string]::IsNullOrEmpty($TenantID)) {
    Write-Log "Machine-Scope leer, versuche env:..." Warning
    $TenantID  = $env:OSDCloudAPTenantID
    $AppID     = $env:OSDCloudAPAppID
    $AppSecret = $env:OSDCloudAPAppSecret
}

Write-Log "=== ENV VARS ===" Info
Write-Log "TenantID:      '$TenantID'" Info
Write-Log "AppID:         '$AppID'" Info
Write-Log "AppSecret Len: $($AppSecret.Length) Zeichen" Info

if ([string]::IsNullOrEmpty($TenantID) -or [string]::IsNullOrEmpty($AppID) -or [string]::IsNullOrEmpty($AppSecret)) {
    Write-Fail "Eine oder mehrere Umgebungsvariablen fehlen! Autopilot-Import wird uebersprungen."
} else {
    Write-Log "Alle Variablen gesetzt." Success
}

#Set Global OSDCloud Vars
$Global:MyOSDCloud = [ordered]@{
    BrandColor = "#0096FF"
    Restart = [bool]$true
    RecoveryPartition = [bool]$True
    OEMActivation = [bool]$True
    WindowsUpdate = [bool]$True
    WindowsUpdateDrivers = [bool]$True
    WindowsDefenderUpdate = [bool]$True
    SetTimeZone = [bool]$True
    ClearDiskConfirm = [bool]$False
    ShutdownSetupComplete = [bool]$false
    SyncMSUpCatDriverUSB = [bool]$True
    CheckSHA1 = [bool]$True
}

Write-Log "================================================" Info
Write-Log "  Autopilot Device Registration Version 4.0" Info
Write-Log "================================================" Info

# Zeitzone setzen
Write-Log "Setze Zeitzone: $TimeZone" Info
Set-TimeZone -Id $TimeZone

# Timeserver mit Retry
$maxRetries = 5
$retryDelay = 10
$timeSet = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        Write-Log "Zeitserver abrufen, Versuch $i/$maxRetries..." Info
        $DateTime = $(Invoke-RestMethod -UseBasicParsing -Uri $TimeServerUrl -TimeoutSec 15).datetime
        Set-Date -Date $DateTime
        Write-Log "Zeit gesetzt: $DateTime" Success
        $timeSet = $true
        break
    } catch {
        Write-Log "Versuch $i fehlgeschlagen: $_" Warning
        if ($i -lt $maxRetries) {
            Write-Log "Warte $retryDelay Sekunden..." Warning
            Start-Sleep -Seconds $retryDelay
        }
    }
}
if (-not $timeSet) {
    Write-Fail "Zeitserver nach $maxRetries Versuchen nicht erreichbar, fahre fort."
}

# Netzwerk-Check
Write-Log "Pruefe Netzwerkverbindung..." Info
try {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike '*Loopback*' } | Select-Object -First 1).IPAddress
    Write-Log "IP-Adresse: $ip" Success
} catch {
    Write-Fail "IP-Adresse konnte nicht ermittelt werden: $_"
}

try {
    $dns = Resolve-DnsName 'login.microsoftonline.com' -ErrorAction Stop
    Write-Log "DNS OK: login.microsoftonline.com -> $($dns[0].IPAddress)" Success
} catch {
    Write-Fail "DNS FEHLER: login.microsoftonline.com nicht aufloesbar! $_"
}

try {
    $ping = Test-NetConnection -ComputerName 'login.microsoftonline.com' -Port 443 -WarningAction SilentlyContinue
    if ($ping.TcpTestSucceeded) {
        Write-Log "TCP Port 443 zu login.microsoftonline.com: OK" Success
    } else {
        Write-Fail "TCP Port 443 zu login.microsoftonline.com nicht erreichbar!"
    }
} catch {
    Write-Fail "Verbindungstest fehlgeschlagen: $_"
}

# Autopilot Hash hochladen via Get-WindowsAutoPilotInfo
if (-not [string]::IsNullOrEmpty($TenantID) -and -not [string]::IsNullOrEmpty($AppID) -and -not [string]::IsNullOrEmpty($AppSecret)) {
    Write-Log "Starte Autopilot-Import..." Info

    try {
        Write-Log "Lade OSDCloud Sandbox..." Info
        Invoke-Expression (Invoke-RestMethod sandbox.osdcloud.com)
        Write-Log "Sandbox geladen" Success
    } catch {
        Write-Fail "Sandbox laden fehlgeschlagen: $_"
    }

    try {
        Write-Log "Installiere Get-WindowsAutoPilotInfo Script..." Info
        Install-Script -Name Get-WindowsAutoPilotInfo -Force -Scope AllUsers
        Write-Log "Script installiert" Success
    } catch {
        Write-Fail "Script-Installation fehlgeschlagen: $_"
    }

    try {
        Write-Log "Ermittle Serial Number..." Info
        $serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
        Write-Log "Serial: $serial" Success

        Write-Log "Starte Hash-Upload zu Intune..." Info
        Get-WindowsAutoPilotInfo `
            -Online `
            -GroupTag $GroupTag `
            -TenantId $TenantID `
            -AppId $AppID `
            -AppSecret $AppSecret

        Write-Log "Autopilot-Import erfolgreich!" Success
    } catch {
        Write-Fail "Autopilot-Import fehlgeschlagen: $_"
    }
} else {
    Write-Fail "Variablen fehlen - Autopilot-Import wird uebersprungen."
}

Write-Log "================================================" Info
Write-Log "Starte OSDCloud Installation..." Info
Write-Log "================================================" Info
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage
