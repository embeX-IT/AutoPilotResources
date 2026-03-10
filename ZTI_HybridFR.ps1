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

# Variablen lesen - Process-Scope zuerst (wird von Startnet.cmd vererbt)
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

Write-Host "Autopilot Device Registration Version 3.0" -ForegroundColor Cyan

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
        if ($i -lt $maxRetries) {
            Write-Host "Warte $retryDelay Sekunden..." -ForegroundColor Yellow
            Start-Sleep -Seconds $retryDelay
        }
    }
}
if (-not $timeSet) {
    Write-Host "Zeitserver nach $maxRetries Versuchen nicht erreichbar, fahre ohne Zeitkorrektur fort." -ForegroundColor Yellow
}

# SetupComplete-Script schreiben (Autopilot-Import nach Installation)
if (-not [string]::IsNullOrEmpty($TenantID) -and -not [string]::IsNullOrEmpty($AppID) -and -not [string]::IsNullOrEmpty($AppSecret)) {
    Write-Host "Schreibe SetupComplete-Script für Autopilot-Import..." -ForegroundColor Cyan

    $setupCompletePS1 = @"
Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

`$AppId     = '$AppID'
`$AppSecret = '$AppSecret'
`$TenantId  = '$TenantID'
`$GroupTag  = '$GroupTag'

try {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Install-Module Microsoft.Graph.Authentication -Force -SkipPublisherCheck
    Install-Module Microsoft.Graph.DeviceManagement.Enrollment -Force -SkipPublisherCheck

    `$SecureSecret = ConvertTo-SecureString `$AppSecret -AsPlainText -Force
    `$Cred = New-Object System.Management.Automation.PSCredential(`$AppId, `$SecureSecret)
    Connect-MgGraph -TenantId `$TenantId -ClientSecretCredential `$Cred -NoWelcome

    `$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber
    `$hash   = (Get-WmiObject -Namespace root/cimv2/mdm/dmmap -Class MDM_DevDetail_Ext01 -Filter "InstanceID='Ext' AND ParentID='./DevDetail'").DeviceHardwareData

    New-MgDeviceManagementImportedWindowsAutopilotDeviceIdentity ``
        -SerialNumber `$serial ``
        -HardwareIdentifier ([Convert]::FromBase64String(`$hash)) ``
        -GroupTag `$GroupTag

    Write-Host "Autopilot-Import erfolgreich fuer Serial: `$serial" -ForegroundColor Green
} catch {
    Write-Host "Autopilot-Import fehlgeschlagen: `$_" -ForegroundColor Red
}

# Script nach Ausführung löschen
Remove-Item -Path 'C:\Windows\Setup\Scripts\SetupComplete.ps1' -Force -ErrorAction SilentlyContinue
"@

    $setupCompleteCMD = @"
PowerShell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\SetupComplete.ps1 >> C:\OSDCloud\Logs\SetupComplete.log 2>&1
"@

    $scriptsPath = 'C:\Windows\Setup\Scripts'
    if (-not (Test-Path $scriptsPath)) {
        New-Item -Path $scriptsPath -ItemType Directory -Force | Out-Null
    }
    $setupCompletePS1 | Out-File "$scriptsPath\SetupComplete.ps1" -Encoding UTF8
    $setupCompleteCMD | Out-File "$scriptsPath\SetupComplete.cmd" -Encoding ASCII
    Write-Host "SetupComplete-Scripts geschrieben nach $scriptsPath" -ForegroundColor Green
} else {
    Write-Host "FEHLER: Umgebungsvariablen fehlen - SetupComplete wird nicht geschrieben!" -ForegroundColor Red
}

Write-Host "Starte OSDCloud..." -ForegroundColor Cyan
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage
