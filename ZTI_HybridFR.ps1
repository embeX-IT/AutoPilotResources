# Settings
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Pro'
$OSActivation = 'Retail'
$OSLanguage = 'de-de'
$GroupTag = 'AutopilotHybridFR'
$TimeZone = 'W. Europe Standard Time'
$TimeServerUrl = "https://time.now/developer/api/timezone/Europe/Berlin"

# TLS 1.2 erzwingen
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Variablen lesen - Process-Scope zuerst
$TenantID  = [Environment]::GetEnvironmentVariable('OSDCloudAPTenantID',  'Process')
$AppID     = [Environment]::GetEnvironmentVariable('OSDCloudAPAppID',     'Process')
$AppSecret = [Environment]::GetEnvironmentVariable('OSDCloudAPAppSecret', 'Process')

# Fallback: Machine-Scope
if ([string]::IsNullOrEmpty($TenantID)) {
    Write-Host "Process-Scope leer, versuche Machine-Scope..." -ForegroundColor Yellow
    $TenantID  = [Environment]::GetEnvironmentVariable('OSDCloudAPTenantID',  'Machine')
    $AppID     = [Environment]::GetEnvironmentVariable('OSDCloudAPAppID',     'Machine')
    $AppSecret = [Environment]::GetEnvironmentVariable('OSDCloudAPAppSecret', 'Machine')
}

# Fallback: $env:
if ([string]::IsNullOrEmpty($TenantID)) {
    Write-Host "Machine-Scope leer, versuche env:..." -ForegroundColor Yellow
    $TenantID  = $env:OSDCloudAPTenantID
    $AppID     = $env:OSDCloudAPAppID
    $AppSecret = $env:OSDCloudAPAppSecret
}

# DEBUG
Write-Host "=== DEBUG ENV VARS ===" -ForegroundColor Cyan
Write-Host "TenantID: '$TenantID'"
Write-Host "AppID: '$AppID'"
Write-Host "AppSecret length: $($AppSecret.Length)"
Write-Host "=== END DEBUG ===" -ForegroundColor Cyan

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

Write-Host "Autopilot Device Registration Version 4.0" -ForegroundColor Cyan

# Zeitzone setzen
Set-TimeZone -Id $TimeZone

# Timeserver mit Retry
$maxRetries = 5
$retryDelay = 10
$timeSet = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        Write-Host "Zeitserver abrufen, Versuch $i von $maxRetries..." -ForegroundColor Cyan
        $DateTime = $(Invoke-RestMethod -UseBasicParsing -Uri $TimeServerUrl -TimeoutSec 15).datetime
        Set-Date -Date $DateTime
        Write-Host "Zeit erfolgreich gesetzt: $DateTime" -ForegroundColor Green
        $timeSet = $true
        break
    } catch {
        Write-Host "Versuch $i fehlgeschlagen: $_" -ForegroundColor Yellow
        if ($i -lt $maxRetries) { Start-Sleep -Seconds $retryDelay }
    }
}
if (-not $timeSet) {
    Write-Host "Zeitserver nicht erreichbar, fahre ohne Zeitkorrektur fort." -ForegroundColor Yellow
}

# Autopilot Hash hochladen via Get-WindowsAutoPilotInfo
if (-not [string]::IsNullOrEmpty($TenantID) -and -not [string]::IsNullOrEmpty($AppID) -and -not [string]::IsNullOrEmpty($AppSecret)) {
    Write-Host "Starte Autopilot-Import..." -ForegroundColor Cyan
    try {
        # PSGallery Support
        Invoke-Expression (Invoke-RestMethod sandbox.osdcloud.com)

        Install-Script -Name Get-WindowsAutoPilotInfo -Force -Scope AllUsers

        Get-WindowsAutoPilotInfo `
            -Online `
            -GroupTag $GroupTag `
            -TenantId $TenantID `
            -AppId $AppID `
            -AppSecret $AppSecret

        Write-Host "Autopilot-Import abgeschlossen." -ForegroundColor Green
    } catch {
        Write-Host "Autopilot-Import fehlgeschlagen: $_" -ForegroundColor Red
    }
} else {
    Write-Host "FEHLER: Umgebungsvariablen fehlen - Autopilot-Import wird übersprungen." -ForegroundColor Red
}

Write-Host "Starte OSDCloud..." -ForegroundColor Cyan
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage
