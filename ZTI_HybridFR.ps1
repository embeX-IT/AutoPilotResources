# Settings
$OSName = 'Windows 11 24H2 x64'
$OSEdition = 'Pro'
$OSActivation = 'Retail'
$OSLanguage = 'de-de'
$GroupTag = 'AutopilotHybridFR'
$TimeZone = 'W. Europe Standard Time'
$TimeServerUrl = "https://time.now/developer/api/timezone/Europe/Berlin"
$OutputFile = "X:\AutopilotHash.csv"
$TenantID = [Environment]::GetEnvironmentVariable('OSDCloudAPTenantID','Machine')
$AppID = [Environment]::GetEnvironmentVariable('OSDCloudAPAppID','Machine')
$AppSecret = [Environment]::GetEnvironmentVariable('OSDCloudAPAppSecret','Machine')

#################
# DEBUG - Umgebungsvariablen prüfen
Write-Host "=== DEBUG ENV VARS ===" -ForegroundColor Cyan
Write-Host "TenantID: '$TenantID'"
Write-Host "AppID: '$AppID'"
Write-Host "AppSecret length: $($AppSecret.Length)"
Write-Host "=== END DEBUG ===" -ForegroundColor Cyan

# Fallback: direkt aus Process-Scope versuchen
if ([string]::IsNullOrEmpty($TenantID)) {
    Write-Host "Machine-Scope leer, versuche Process-Scope..." -ForegroundColor Yellow
    $TenantID  = [Environment]::GetEnvironmentVariable('OSDCloudAPTenantID',  'Process')
    $AppID     = [Environment]::GetEnvironmentVariable('OSDCloudAPAppID',     'Process')
    $AppSecret = [Environment]::GetEnvironmentVariable('OSDCloudAPAppSecret', 'Process')
    Write-Host "Process-Scope TenantID: '$TenantID'"
}

# Fallback: $env: versuchen
if ([string]::IsNullOrEmpty($TenantID)) {
    Write-Host "Process-Scope leer, versuche env:..." -ForegroundColor Yellow
    $TenantID  = $env:OSDCloudAPTenantID
    $AppID     = $env:OSDCloudAPAppID
    $AppSecret = $env:OSDCloudAPAppSecret
    Write-Host "env: TenantID: '$TenantID'"
}

##################
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
$oa3tool = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/oa3tool.exe'
$pcpksp  = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/PCPKsp.dll'
$inputxml = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/input.xml'
$oa3cfg  = 'https://raw.githubusercontent.com/embeX-IT/AutoPilotResources/embeX/OA3.cfg'

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

# Upload the hash
Start-Sleep 30

# PSGallery Support via OSDCloud sandbox
Invoke-Expression (Invoke-RestMethod sandbox.osdcloud.com)

# Install Microsoft Graph modules
Write-Host "Installing Microsoft Graph modules..."
Install-Module Microsoft.Graph.Authentication -SkipPublisherCheck -Force
Install-Module Microsoft.Graph.DeviceManagement.Enrollment -SkipPublisherCheck -Force

# Connect via App Registration (Client Credentials)
Write-Host "Connecting to Microsoft Graph..."
$SecureSecret = ConvertTo-SecureString $AppSecret -AsPlainText -Force
$ClientCredential = New-Object System.Management.Automation.PSCredential($AppID, $SecureSecret)
Connect-MgGraph -TenantId $TenantID -ClientSecretCredential $ClientCredential -NoWelcome

# Import Autopilot Hash
Write-Host "Importing Autopilot hash for serial: $serial"
$csvData = Import-Csv $OutputFile

foreach ($device in $csvData) {
    $params = @{
        "@odata.type"      = "#microsoft.graph.importedWindowsAutopilotDeviceIdentity"
        serialNumber       = $device.'Device Serial Number'
        hardwareIdentifier = $device.'Hardware Hash'
        groupTag           = $device.'Group Tag'
    }
    New-MgDeviceManagementImportedWindowsAutopilotDeviceIdentity -BodyParameter $params
}

Write-Host "Autopilot import complete. Starting OSDCloud..."

Start-OSDCloud -OSName $OSName -OSEdition $OSEdition -OSActivation $OSActivation -OSLanguage $OSLanguage
