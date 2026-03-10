# Settings
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Pro'
$OSActivation = 'Retail'
$OSLanguage = 'de-de'
$GroupTag = 'AutopilotHybridFR'
$TimeZone = 'W. Europe Standard Time'
$TimeServerUrl = "https://time.now/developer/api/timezone/Europe/Berlin"
$OutputFile = "X:\AutopilotHash.csv"

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

Write-Host "Autopilot Device Registration Version 2.0"

# Set the time
Set-TimeZone -Id $TimeZone
$DateTime = $(Invoke-RestMethod -UseBasicParsing -Uri $TimeServerUrl).datetime
Set-Date -Date $DateTime

# Download required files
$oa3tool  = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/oa3tool.exe'
$pcpksp   = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/PCPKsp.dll'
$inputxml = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/input.xml'
$oa3cfg   = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/OA3.cfg'

Invoke-WebRequest $oa3tool  -OutFile $PSScriptRoot\oa3tool.exe
Invoke-WebRequest $pcpksp   -OutFile X:\Windows\System32\PCPKsp.dll
Invoke-WebRequest $inputxml -OutFile $PSScriptRoot\input.xml
Invoke-WebRequest $oa3cfg   -OutFile $PSScriptRoot\OA3.cfg

# Create OA3 Hash
If ((Test-Path X:\Windows\System32\wpeutil.exe) -and (Test-Path X:\Windows\System32\PCPKsp.dll)) {
    rundll32 X:\Windows\System32\PCPKsp.dll,DllInstall
}

Set-Location $PSScriptRoot

$serial = (Get-WmiObject -Class Win32_BIOS).SerialNumber

&$PSScriptRoot\oa3tool.exe /Report /ConfigFile=$PSScriptRoot\OA3.cfg /NoKeyCheck

If (Test-Path $PSScriptRoot\OA3.xml) {
    [xml]$xmlhash = Get-Content -Path "$PSScriptRoot\OA3.xml"
    $hash = $xmlhash.Key.HardwareHash

    $computers = @()
    $c = New-Object psobject -Property @{
        "Device Serial Number" = $serial
        "Windows Product ID"   = ""
        "Hardware Hash"        = $hash
        "Group Tag"            = $GroupTag
    }
    $computers += $c
    $computers | Select-Object "Device Serial Number", "Windows Product ID", "Hardware Hash", "Group Tag" |
        ConvertTo-Csv -NoTypeInformation |
        ForEach-Object { $_ -replace '"', '' } |
        Out-File $OutputFile
}

Start-Sleep 30

# PSGallery Support via OSDCloud sandbox
Invoke-Expression (Invoke-RestMethod sandbox.osdcloud.com)

# Install Microsoft Graph modules
Write-Host "Installing Microsoft Graph modules..."
Install-Module Microsoft.Graph.Authentication -SkipPublisherCheck -Force
Install-Module Microsoft.Graph.DeviceManagement.Enrollment -SkipPublisherCheck -Force

# Abbrechen wenn Vars fehlen
if ([string]::IsNullOrEmpty($TenantID) -or [string]::IsNullOrEmpty($AppID) -or [string]::IsNullOrEmpty($AppSecret)) {
    Write-Host "FEHLER: Umgebungsvariablen nicht gesetzt! Autopilot-Import wird übersprungen." -ForegroundColor Red
} else {
    # Connect via App Registration
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    $SecureSecret = ConvertTo-SecureString $AppSecret -AsPlainText -Force
    $ClientCredential = New-Object System.Management.Automation.PSCredential($AppID, $SecureSecret)
    Connect-MgGraph -TenantId $TenantID -ClientSecretCredential $ClientCredential -NoWelcome

    # Import Autopilot Hash
    Write-Host "Importing Autopilot hash for serial: $serial" -ForegroundColor Cyan
    $csvData = Import-Csv $OutputFile

    foreach ($device in $csvData) {
        $importedDevice = New-MgDeviceManagementImportedWindowsAutopilotDeviceIdentity `
            -SerialNumber $device.'Device Serial Number' `
            -HardwareIdentifier ([Convert]::FromBase64String($device.'Hardware Hash')) `
            -GroupTag $device.'Group Tag'
        Write-Host "Import Status: $($importedDevice.State.DeviceImportStatus)"
    }
}

Write-Host "Starting OSDCloud..."
Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage
