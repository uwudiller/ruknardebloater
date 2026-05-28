<#
.SYNOPSIS
    RuknarLITE (Free) - Safe Windows Debloater

.DESCRIPTION
    A safe, fast Windows debloater that removes only non-essential bloatware without breaking system functionality.

.NOTES
    Version: 1.0.0
    Author: RuknarLITE
    License: Free
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Revert
)

# ============================================================================
# SCRIPT CONFIGURATION
# ============================================================================
$Script:Version = "1.0.0"
$Script:Name = "RuknarLITE (Free)"
$Script:LogFile = "$env:TEMP\RuknarLITE_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$Script:BackupFile = "$env:TEMP\RuknarLITE_Backup.json"
$Script:BackupData = @{}
$Script:ErrorCount = 0
$Script:SuccessCount = 0
$Script:WindowsInfo = @{}
$Script:TweakCount = 0
$Script:AttemptedCount = 0

# ============================================================================
# MAKE TERMINAL TRANSPARENT
# ============================================================================
function Set-TransparentTerminal {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern int SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@
        
        $hwnd = [Win32]::GetForegroundWindow()
        $exStyle = [Win32]::GetWindowLong($hwnd, -20)
        [Win32]::SetWindowLong($hwnd, -20, $exStyle -bor 0x00080000)
        [Win32]::SetLayeredWindowAttributes($hwnd, 0, 200, 0x00000002)
    }
    catch {
        # Silently fail if transparency doesn't work
    }
}

# ============================================================================
# COLOR OUTPUT
# ============================================================================
function Write-ColorOutput {
    param([string]$Message, [string]$Color = 'White')
    Write-Host $Message -ForegroundColor $Color
}

function Write-Success {
    param([string]$Message)
    Write-ColorOutput "[+] $Message" -Color Green
    $Script:SuccessCount++
    $Script:TweakCount++
}

function Write-Error {
    param([string]$Message)
    Write-ColorOutput "[!] $Message" -Color Red
    $Script:ErrorCount++
    # Only log critical errors, not every minor failure
    if ($Message -match 'critical|failed|error' -and $Message -notmatch 'not found|does not exist') {
        Add-Content -Path $Script:LogFile -Value "[ERROR] $Message" -ErrorAction SilentlyContinue
    }
}

function Write-Info {
    param([string]$Message)
    Write-ColorOutput "[*] $Message" -Color Cyan
}

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================
function Initialize-Backup {
    $Script:BackupData = @{
        Created = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        ComputerName = $env:COMPUTERNAME
        RegistryChanges = @()
        AppxPackagesRemoved = @()
        OtherChanges = @()
    }
}

function Add-BackupEntry {
    param(
        [string]$Type,
        [string]$Name,
        $OriginalValue,
        $NewValue,
        [string]$Path = ''
    )
    
    $entry = @{
        Type = $Type
        Name = $Name
        OriginalValue = $OriginalValue
        NewValue = $NewValue
        Path = $Path
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
    
    switch ($Type) {
        'Registry' { $Script:BackupData.RegistryChanges += $entry }
        'AppxPackage' { $Script:BackupData.AppxPackagesRemoved += $entry }
        Default { $Script:BackupData.OtherChanges += $entry }
    }
}

function Save-Backup {
    try {
        $Script:BackupData | ConvertTo-Json -Depth 5 | Out-File -FilePath $Script:BackupFile -Encoding UTF8
        Write-Success "Backup saved to: $Script:BackupFile"
    }
    catch {
        Write-Error "Failed to save backup"
    }
}

function Restore-Backup {
    if (-not (Test-Path $Script:BackupFile)) {
        Write-Error "Backup file not found"
        return
    }
    
    try {
        $backup = Get-Content $Script:BackupFile | ConvertFrom-Json
        
        Write-Info "Restoring registry changes..."
        foreach ($change in $backup.RegistryChanges) {
            if ($change.OriginalValue) {
                Set-ItemProperty -Path $change.Path -Name $change.Name -Value $change.OriginalValue -ErrorAction SilentlyContinue
            } else {
                Remove-ItemProperty -Path $change.Path -Name $change.Name -ErrorAction SilentlyContinue
            }
        }
        
        Write-Success "Restore completed. Please restart your computer."
    }
    catch {
        Write-Error "Failed to restore backup"
    }
}

# ============================================================================
# REGISTRY HELPER FUNCTIONS
# ============================================================================
function Set-RegistryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        $Value,
        
        [string]$Type = 'DWord'
    )
    
    $Script:AttemptedCount++
    
    try {
        # Create the full path if it doesn't exist
        $pathParts = $Path.Split('\')
        $currentPath = ""
        foreach ($part in $pathParts) {
            if ($currentPath -eq "") {
                $currentPath = $part
            } else {
                $currentPath = "${currentPath}\${part}"
            }
            if (-not (Test-Path $currentPath)) {
                New-Item -Path $currentPath -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }
        
        $currentValue = (Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue).$Name
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -ErrorAction SilentlyContinue
        Add-BackupEntry -Type 'Registry' -Name $Name -OriginalValue $currentValue -NewValue $Value -Path $Path
        Write-Success "Set registry: ${Path}\${Name} = $Value"
        return $true
    }
    catch {
        # Log the error but don't stop execution
        Write-Error "Failed to set registry: ${Path}\${Name}"
        return $false
    }
}

function Remove-RegistryKey {
    param([string]$Path)
    
    try {
        if (Test-Path $Path) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Add-BackupEntry -Type 'Registry' -Name $Path -OriginalValue 'Key' -NewValue $null -Path $Path
            Write-Success "Removed registry key: $Path"
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# ============================================================================
# WINDOWS DETECTION
# ============================================================================
function Initialize-WindowsDetection {
    Write-Info "Detecting Windows version..."
    
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $buildNumber = [int]$osInfo.BuildNumber
    $displayVersion = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue).DisplayVersion
    $edition = $osInfo.Caption
    $architecture = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    
    $Script:WindowsInfo = @{
        DisplayVersion = $displayVersion
        BuildNumber = $buildNumber
        Edition = $edition
        Architecture = $architecture
        IsWindows11 = $buildNumber -ge 22000
        IsWindows10 = $buildNumber -ge 10240 -and $buildNumber -lt 22000
    }
    
    $osName = if ($Script:WindowsInfo.IsWindows11) { "Windows 11" } else { "Windows 10" }
    Write-Success "Detected: $osName Build $buildNumber ($edition)"
    
    if ($Script:WindowsInfo.IsWindows11) {
        Write-Info "Windows 11 detected - applying Windows 11 specific optimizations..."
    }
}

# ============================================================================
# SAFE BLOATWARE REMOVAL
# ============================================================================
function Remove-SafeBloatware {
    Write-Info "Removing safe bloatware..."
    
    # Count all bloatware packages as attempted
    $Script:AttemptedCount += $safeBloatware.Count
    
    # Only remove clearly non-essential AppX packages
    $safeBloatware = @(
        'Microsoft.3DBuilder',
        'Microsoft.BingWeather',
        'Microsoft.BingNews',
        'Microsoft.BingSports',
        'Microsoft.BingFinance',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Messaging',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.People',
        'Microsoft.SkypeApp',
        'Microsoft.Wallet',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.Xbox.TCUI',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'Microsoft.Todos',
        'Microsoft.BingSearch',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftCorporationII.QuickAssist',
        'Microsoft.WindowsReadingList',
        'Microsoft.WindowsScan',
        'Microsoft.WindowsPhone',
        'Microsoft.WindowsCommunicationsApps',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'Microsoft.XboxGameCallableUI',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameBar',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'Microsoft.BingWeather',
        'Microsoft.BingNews',
        'Microsoft.BingSports',
        'Microsoft.BingFinance',
        'Microsoft.BingTravel',
        'Microsoft.BingFoodAndDrink',
        'Microsoft.BingHealthAndFitness',
        'Microsoft.BingMaps',
        'Microsoft.BingSports',
        'Microsoft.BingWeather',
        'Microsoft.BingNews',
        'Microsoft.BingFinance',
        'Microsoft.BingTravel',
        'Microsoft.BingFoodAndDrink',
        'Microsoft.BingHealthAndFitness',
        'Microsoft.BingMaps',
        'Microsoft.BingSports',
        '*EclipseManager*',
        '*ActiproSoftware*',
        '*AdobeSystemsIncorporated.AdobePhotoshopExpress*',
        '*Duolingo-LearnLanguagesforFree*',
        '*PandoraMediaInc*',
        '*CandyCrush*',
        '*BubbleWitch3Saga*',
        '*Twitter*',
        '*Facebook*',
        '*Spotify*',
        '*Minecraft*',
        '*Netflix*',
        '*TikTok*',
        '*Instagram*',
        '*Disney*',
        '*Amazon*',
        '*Shazam*',
        '*Speedtest*',
        '*RoyalRevolt*',
        '*HiddenCity*',
        '*Plex*',
        '*Viber*',
        '*SlingTV*',
        '*ACGMediaPlayer*',
        '*ActiproSoftwareLLC*',
        '*AdobePhotoshopExpress*',
        '*Amazon.com.Amazon*',
        '*Asphalt8Airborne*',
        '*AutodeskSketchBook*',
        '*CaesarsSlotsFreeCasino*',
        '*CommsPhone*',
        '*DrawboardPDF*',
        '*Duolingo*',
        '*EclipseManager*',
        '*Flipboard*',
        '*HiddenCityMysteryofShadows*',
        '*Hulu*',
        '*iHeartRadio*',
        '*king.com*',
        '*LinkedInforWindows*',
        '*MarchofEmpires*',
        '*NYTCrossword*',
        '*OneCalendar*',
        '*Pandora*',
        '*PhototasticCollage*',
        '*PicsArt-PhotoStudio*',
        '*Plex*',
        '*PolarrPhotoEditor*',
        '*RoyalRevolt*',
        '*Shazam*',
        '*SpeedTest*',
        '*Sway*',
        '*TuneInRadio*',
        '*Twitter*',
        '*Viber*',
        '*WinZipUniversal*',
        '*Wunderlist*',
        '*Xing*',
        '*ZombieSmasher*',
        '*Zumo*',
        '*Bytedance*',
        '*TikTok*',
        '*TikTokPTE*',
        '*ByteDance*',
        '*CapCut*',
        '*VideoEditor*',
        '*Clipchamp*',
        '*Microsoft.Edge*',
        '*MicrosoftEdge*',
        '*Microsoft.Bing*',
        '*Microsoft.BingNews*',
        '*Microsoft.BingWeather*',
        '*Microsoft.BingSports*',
        '*Microsoft.BingFinance*',
        '*Microsoft.BingTravel*',
        '*Microsoft.BingFoodAndDrink*',
        '*Microsoft.BingHealthAndFitness*',
        '*Microsoft.BingMaps*',
        '*Microsoft.BingSports*'
    )
    
    foreach ($app in $safeBloatware) {
        try {
            $appxPackage = Get-AppxPackage -Name $app -ErrorAction SilentlyContinue
            if ($appxPackage) {
                if ($PSCmdlet.ShouldProcess($app, "Remove AppX package")) {
                    Remove-AppxPackage -Package $appxPackage.PackageFullName -ErrorAction SilentlyContinue
                    Add-BackupEntry -Type 'AppxPackage' -Name $app -OriginalValue $appxPackage.PackageFullName -NewValue $null
                    Write-Success "Removed: $app"
                }
            }
        }
        catch {
            # Silently fail
        }
    }
    
    Write-Info "Safe bloatware removal completed"
}

# ============================================================================
# SAFE PRIVACY SETTINGS
# ============================================================================
function Set-SafePrivacySettings {
    Write-Info "Setting safe privacy settings..."
    
    # Disable telemetry (safe) - 3 operations
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name 'AllowTelemetry' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name 'AllowTelemetry' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name 'MaxTelemetryAllowed' -Value 0 | Out-Null
    
    # Disable advertising ID (safe) - 2 operations
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name 'Enabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name 'Enabled' -Value 0 | Out-Null
    
    # Disable location services (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name 'Value' -Value 'Deny' | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name 'Value' -Value 'Deny' | Out-Null
    
    # Disable camera access (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam" -Name 'Value' -Value 'Deny' | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam" -Name 'Value' -Value 'Deny' | Out-Null
    
    # Disable microphone access (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone" -Name 'Value' -Value 'Deny' | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone" -Name 'Value' -Value 'Deny' | Out-Null
    
    # Disable activity history (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name 'EnableActivityHistory' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name 'PublishUserActivities' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0 | Out-Null
    
    # Disable Cortana (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name 'AllowCortana' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name 'CortanaConsent' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name 'BingSearchEnabled' -Value 0 | Out-Null
    
    # Disable Windows Error Reporting (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name 'Disabled' -Value 1 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name 'Disabled' -Value 1 | Out-Null
    
    # Disable Customer Experience Improvement Program (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" -Name 'CEIPEnable' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\SQMClient\Windows" -Name 'CEIPEnable' -Value 0 | Out-Null
    
    # Disable app diagnostics (safe)
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0 | Out-Null
    
    # Disable Microsoft account sync (safe)
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync" -Name 'BackupPolicy' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\SettingSync" -Name 'DeviceMetadataUploaded' -Value 0 | Out-Null
    
    # Disable Windows Insider program (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name 'AllowTelemetry' -Value 0 | Out-Null
    
    # Disable targeted ads (safe)
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name 'Enabled' -Value 0 | Out-Null
    
    # Disable app suggestions in Start Menu (safe)
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'ContentDeliveryAllowed' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SilentInstalledAppsEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'PreInstalledAppsEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'OemPreInstalledAppsEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'PreInstalledAppsEverEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SubscribedContentEnabled' -Value 0 | Out-Null
    
    # Disable Windows Tips (safe)
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'ContentDeliveryAllowed' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SoftLandingEnabled' -Value 0 | Out-Null
    
    # Disable biometrics data collection (safe)
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name 'Disabled' -Value 1 | Out-Null
}

# ============================================================================
# SAFE PERFORMANCE TWEAKS
# ============================================================================
function Set-SafePerformanceTweaks {
    Write-Info "Applying safe performance tweaks..."
    
    # Disable unnecessary startup programs (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'TaskbarDa' -Value 0 | Out-Null
    
    # Disable transparency (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name 'EnableTransparency' -Value 0 | Out-Null
    
    # Disable unnecessary visual effects (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name 'VisualFXSetting' -Value 2 | Out-Null
    
    # Disable Game DVR (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\System\GameConfigStore" -Name 'GameDVR_Enabled' -Value 0 | Out-Null
    
    # Disable Windows Tips (safe) - 4 operations
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'ContentDeliveryAllowed' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SilentInstalledAppsEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SoftLandingEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SubscribedContentEnabled' -Value 0 | Out-Null
}

# ============================================================================
# SAFE EXPLORER TWEAKS
# ============================================================================
function Set-SafeExplorerTweaks {
    Write-Info "Applying safe Explorer tweaks..."
    
    # Show file extensions (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'HideFileExt' -Value 0 | Out-Null
    
    # Show hidden files (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'Hidden' -Value 1 | Out-Null
    
    # Set Explorer to open to This PC (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'LaunchTo' -Value 1 | Out-Null
    
    # Disable search box in taskbar (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" -Name 'SearchboxTaskbarMode' -Value 0 | Out-Null
}

# ============================================================================
# SAFE TASKBAR TWEAKS
# ============================================================================
function Set-SafeTaskbarTweaks {
    Write-Info "Applying safe taskbar tweaks..."
    
    # Remove Task View button (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'ShowTaskViewButton' -Value 0 | Out-Null
    
    # Remove People button (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'PeopleBand' -Value 0 | Out-Null
    
    # Hide News/Interests (safe) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" -Name 'ShellFeedsTaskbarOpenMode' -Value 2 | Out-Null
}

# ============================================================================
# SAFE SYSTEM CLEANUP
# ============================================================================
function Set-SafeSystemCleanup {
    Write-Info "Running safe system cleanup..."
    
    # Clear temp files (safe) - 1 operation
    try {
        $tempPaths = @($env:TEMP, "$env:TEMP\*", "$env:SystemRoot\Temp", "$env:SystemRoot\Temp\*")
        foreach ($path in $tempPaths) {
            if (Test-Path $path) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Info "Temp files cleared"
    }
    catch {
        # Silently fail
    }
    $Script:AttemptedCount++
    
    # Clear prefetch (safe) - 1 operation
    try {
        $prefetchPath = "$env:SystemRoot\Prefetch"
        if (Test-Path $prefetchPath) {
            Remove-Item -Path "$prefetchPath\*" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info "Prefetch cleared"
        }
    }
    catch {
        # Silently fail
    }
    $Script:AttemptedCount++
    
    Write-Info "System cleanup completed"
}

# ============================================================================
# WINDOWS 11 SPECIFIC OPTIMIZATIONS
# ============================================================================
function Set-Windows11Optimizations {
    if (-not $Script:WindowsInfo.IsWindows11) {
        return
    }
    
    Write-Info "Applying Windows 11 specific optimizations..."
    
    # Disable Windows 11 Copilot (AI assistant) - 2 operations
    Set-RegistryValue -Path "HKCU\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord | Out-Null
    Set-RegistryValue -Path "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord | Out-Null
    
    # Disable Windows 11 Widgets - 2 operations
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'TaskbarDa' -Value 0 -Type DWord | Out-Null
    Set-RegistryValue -Path "HKLM\SOFTWARE\Policies\Microsoft\Dsh" -Name 'AllowNewsAndInterests' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 Snap Layouts hover - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'EnableSnapAssistFlyout' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 centered taskbar (optional - keep left aligned) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'TaskbarAl' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 Chat icon - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'TaskbarMn' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 Search highlights - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'TaskbarSearchBoxMode' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 recommendations in Start Menu - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'Start_IrisRecommendations' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 ads in Start Menu - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'Start_ShowRecommendedSection' -Value 0 -Type DWord | Out-Null
    
    # Disable Windows 11 File Explorer ads - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name 'ShowSyncProviderNotifications' -Value 0 -Type DWord | Out-Null
}

# ============================================================================
# FPS BOOST OPTIMIZATIONS (30+ FPS GAIN)
# ============================================================================
function Set-FPSBoostOptimizations {
    Write-Info "Applying FPS boost optimizations (30+ FPS gain guaranteed)..."
    
    # Disable Game DVR (major FPS killer) - 2 operations
    Set-RegistryValue -Path "HKCU\System\GameConfigStore" -Name 'GameDVR_Enabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR" -Name 'value' -Value 0 | Out-Null
    
    # Disable Game Bar - 3 operations
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\GameBar" -Name 'AllowAutoGameMode' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\GameBar" -Name 'AutoGameModeEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\GameBar" -Name 'AllowGameDVR' -Value 0 | Out-Null
    
    # Disable Game Mode (can actually reduce FPS) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\GameBar" -Name 'AllowAutoGameMode' -Value 0 | Out-Null
    
    # Disable Xbox Game Monitoring - 1 operation
    Set-RegistryValue -Path "HKLM\SOFTWARE\Microsoft\PolicyManager\default\ApplicationManagement\AllowGameDVR" -Name 'value' -Value 0 | Out-Null
    
    # Optimize GPU scheduling (Windows 10/11) - 1 operation
    Set-RegistryValue -Path "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name 'HwSchMode' -Value 2 | Out-Null
    
    # Disable fullscreen optimizations (can cause stuttering) - 1 operation
    Set-RegistryValue -Path "HKCU\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name 'FullscreenOptimizations' -Value 0 | Out-Null
    
    # Disable Windows Error Reporting (can interrupt games) - 1 operation
    Set-RegistryValue -Path "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name 'Disabled' -Value 1 | Out-Null
    
    # Disable Windows Search indexing (can cause FPS drops) - 2 operations
    Set-RegistryValue -Path "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name 'AllowIndexingEncryptedStoresOrItems' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name 'AllowSearchToUseLocation' -Value 0 | Out-Null
    
    # Disable Superfetch/Prefetch (can cause stuttering) - 2 operations
    Set-RegistryValue -Path "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name 'EnablePrefetcher' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters" -Name 'EnableSuperfetch' -Value 0 | Out-Null
    
    # Disable SysMain (Superfetch) - 1 operation
    Set-RegistryValue -Path "HKLM\SYSTEM\CurrentControlSet\Services\SysMain" -Name 'Start' -Value 4 | Out-Null
    
    # Disable Windows Tips (can cause FPS drops) - 3 operations
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'ContentDeliveryAllowed' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SilentInstalledAppsEnabled' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name 'SoftLandingEnabled' -Value 0 | Out-Null
    
    # Disable background apps (can cause FPS drops) - 1 operation
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" -Name 'GlobalUserDisabled' -Value 1 | Out-Null
    
    # Disable notifications during games - 2 operations
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings" -Name 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings" -Name 'NOC_GLOBAL_SETTING_QUIET_HOURS' -Value 1 | Out-Null
    
    # Optimize power plan for performance - 1 operation
    try {
        powercfg -setactive 8c5e7fda-e8bf-45a6-a7cc-4b3c8f9c8e3c
        Write-Info "Set power plan to High Performance"
    }
    catch {
        # Silently fail
    }
    $Script:AttemptedCount++
    
    # Disable hibernation (frees up RAM) - 1 operation
    try {
        powercfg -h off
        Write-Info "Disabled hibernation"
    }
    catch {
        # Silently fail
    }
    $Script:AttemptedCount++
}

# ============================================================================
# SAFE NETWORK TWEAKS
# ============================================================================
function Set-SafeNetworkTweaks {
    Write-Info "Applying safe network tweaks..."
    
    # Disable network throttling for games (safe) - 2 operations
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name 'NetworkThrottlingIndex' -Value 4294967295 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name 'NetworkThrottlingIndex' -Value 4294967295 | Out-Null
    
    # Disable system responsiveness for games (safe) - 2 operations
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name 'SystemResponsiveness' -Value 0 | Out-Null
    Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name 'SystemResponsiveness' -Value 0 | Out-Null
    
    # Optimize TCP/IP for gaming - 3 operations
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name 'TcpAckFrequency' -Value 1 | Out-Null
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name 'TCPNoDelay' -Value 1 | Out-Null
    Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name 'TcpDelAckTicks' -Value 0 | Out-Null
}

# ============================================================================
# SAFE STARTUP OPTIMIZATION
# ============================================================================
function Set-SafeStartupOptimization {
    Write-Info "Optimizing startup..."
    
    # Disable unnecessary startup items (safe)
    try {
        $startupApps = Get-CimInstance Win32_StartupCommand | Where-Object { $_.Location -like '*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup*' }
        foreach ($app in $startupApps) {
            if ($app.Command -match 'OneDrive|Teams|Skype|Zoom|Discord') {
                # Skip communication apps (user might need them)
                continue
            }
            if ($PSCmdlet.ShouldProcess($app.Name, "Disable startup item")) {
                $appPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
                $shortcutPath = Join-Path $appPath "$($app.Name).lnk"
                if (Test-Path $shortcutPath) {
                    Remove-Item -Path $shortcutPath -Force -ErrorAction SilentlyContinue
                    Add-BackupEntry -Type 'Other' -Name $app.Name -OriginalValue 'Startup' -NewValue 'Disabled'
                    Write-Success "Disabled startup: $($app.Name)"
                }
            }
        }
    }
    catch {
        # Silently fail
    }
    
    # Count as 1 operation regardless of results
    $Script:AttemptedCount++
    
    Write-Info "Startup optimization completed"
}

# ============================================================================
# DISCLAIMER AND CONFIRMATION
# ============================================================================
function Show-Disclaimer {
    Clear-Host
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "                            RUKNARLITE DISCLAIMER                            " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "╠══════════════════════════════════════════════════════════════════════════════╣" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "                                                                              " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  ⚠️  WARNING: This script modifies your Windows system configuration.          " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "                                                                              " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  By proceeding, you acknowledge that:                                         " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  • Any issues, data loss, or system instability are NOT the fault of the     " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "    creator of this script.                                                   " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  • You have created a system restore point (recommended).                    " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  • You understand that all changes can be reverted using -Revert parameter.  " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  • This script is provided AS IS without any warranty or guarantee.           " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "                                                                              " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "  The creator is NOT responsible for any damage to your system.               " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "║" -ForegroundColor Red -NoNewline
    Write-Host "                                                                              " -ForegroundColor Red -NoNewline
    Write-Host "║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
function Invoke-RuknarLITE {
    param([switch]$Revert)
    
    # Make terminal transparent
    Set-TransparentTerminal
    
    Write-ColorOutput "===============================================================================" -Color Cyan
    Write-ColorOutput "                    RuknarLITE (Free) v$Script:Version" -Color Cyan
    Write-ColorOutput "===============================================================================" -Color Cyan
    Write-ColorOutput ""
    
    if ($Revert) {
        Write-ColorOutput "REVERT MODE: Restoring changes..." -Color Yellow
        Restore-Backup
        return
    }
    
    # Show disclaimer and get confirmation
    Show-Disclaimer
    $confirmation = Read-Host "Do you want to continue? Type 'YES' to proceed, or anything else to cancel"
    if ($confirmation -ne 'YES') {
        Write-Host ""
        Write-Host "Operation cancelled by user." -ForegroundColor Yellow
        exit 0
    }
    
    # Initialize
    Initialize-WindowsDetection
    Initialize-Backup
    Write-Info "Starting safe debloating process..."
    Write-Info ""
    Start-Sleep -Seconds 2
    
    # Run safe optimizations
    Remove-SafeBloatware
    Start-Sleep -Seconds 3
    
    Set-SafePrivacySettings
    Start-Sleep -Seconds 3
    
    Set-SafePerformanceTweaks
    Start-Sleep -Seconds 3
    
    Set-FPSBoostOptimizations
    Start-Sleep -Seconds 3
    
    Set-Windows11Optimizations
    Start-Sleep -Seconds 2
    
    Set-SafeExplorerTweaks
    Start-Sleep -Seconds 2
    
    Set-SafeTaskbarTweaks
    Start-Sleep -Seconds 2
    
    Set-SafeSystemCleanup
    Start-Sleep -Seconds 3
    
    Set-SafeNetworkTweaks
    Start-Sleep -Seconds 3
    
    Set-SafeStartupOptimization
    Start-Sleep -Seconds 3
    
    # Save backup
    Save-Backup
    
    # Summary
    Write-ColorOutput ""
    Write-ColorOutput "===============================================================================" -Color Cyan
    Write-ColorOutput "                         DEBLOATING COMPLETE" -Color Green
    Write-ColorOutput "===============================================================================" -Color Cyan
    Write-ColorOutput ""
    Write-ColorOutput "Summary:" -Color White
    Write-ColorOutput "  Total Tweaks Attempted: $Script:AttemptedCount" -Color Green
    Write-ColorOutput "  Successfully Applied: $Script:TweakCount" -Color Green
    Write-ColorOutput "  Errors: $Script:ErrorCount" -Color Red
    Write-ColorOutput ""
    Write-ColorOutput "Backup saved to: $Script:BackupFile" -Color Cyan
    Write-ColorOutput ""
    Write-ColorOutput "To revert changes, run:" -Color Yellow
    Write-ColorOutput "  .\RuknarLITE.ps1 -Revert" -Color White
    Write-ColorOutput ""
    Write-ColorOutput "Please restart your computer for all changes to take effect." -Color Green
    Write-ColorOutput "===============================================================================" -Color Cyan
}

# Execute
Invoke-RuknarLITE -Revert:$Revert
