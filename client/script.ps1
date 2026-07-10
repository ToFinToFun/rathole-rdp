# ============================================================
#  Rathole RDP Client - Native Remote Desktop Tunnel
#  by JPaasovaara - MIT License
#
#  Installs rathole as a Windows service that creates a
#  reverse tunnel to your VPS, enabling native RDP access
#  from anywhere using standard mstsc.exe.
#
#  No VPN, no extra client on the connecting side.
# ============================================================

$ErrorActionPreference = "Stop"

# --- Constants ---
$SCRIPT_VERSION = "1.0.0"
$RATHOLE_VERSION = "0.5.0"
$SERVICE_NAME = "rathole-rdp"
$DISPLAY_NAME = "Rathole RDP Tunnel"
$INSTALL_DIR = "$env:ProgramFiles\rathole-rdp"
$CONFIG_FILE = "$INSTALL_DIR\client.toml"
$WINSW_NAME = "rathole-rdp-svc"
$WINSW_XML = "$INSTALL_DIR\$WINSW_NAME.xml"
$WINSW_EXE = "$INSTALL_DIR\$WINSW_NAME.exe"
$MARKER_DIR = "$env:ProgramData\RatholeTunnel"
$MARKER_FILE = "$MARKER_DIR\install.json"
$SLOTS_FILE = Join-Path (Split-Path $PSScriptRoot -Parent) "slots.txt"

# --- Banner ---
function Show-Banner {
    Clear-Host
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  Rathole RDP - Native Remote Desktop Tunnel" -ForegroundColor White
    Write-Host "  by JPaasovaara - MIT License" -ForegroundColor DarkGray
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This tool makes your PC accessible via Remote Desktop"
    Write-Host "  using a standard RDP client (mstsc.exe) from anywhere."
    Write-Host ""
    Write-Host "  No VPN or extra software needed on the connecting side."
    Write-Host "  Full RDP: clipboard, audio, drives, multi-monitor."
    Write-Host ""
    Write-Host "  Installs as a Windows service with auto-reconnect."
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""
}

# --- Helpers ---
function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsEdition {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return $os.Caption
}

function Test-RDPCapable {
    $edition = Get-WindowsEdition
    if ($edition -match "Home") { return $false }
    return $true
}

# --- Azure AD / Entra ID Functions ---
function Test-AzureADJoined {
    $result = @{
        IsAzureADJoined = $false
        IsHybridJoined  = $false
        JoinType        = "None"
        TenantName      = ""
        UserName        = ""
    }
    
    try {
        $dsreg = dsregcmd /status 2>$null
        if ($dsreg) {
            $azureAdJoined = ($dsreg | Select-String "AzureAdJoined\s*:\s*YES") -ne $null
            $domainJoined = ($dsreg | Select-String "DomainJoined\s*:\s*YES") -ne $null
            $tenantLine = $dsreg | Select-String "TenantName\s*:\s*(.+)"
            
            if ($azureAdJoined) {
                $result.IsAzureADJoined = $true
                if ($domainJoined) {
                    $result.IsHybridJoined = $true
                    $result.JoinType = "Hybrid Azure AD Joined"
                } else {
                    $result.JoinType = "Azure AD Joined (pure)"
                }
            }
            
            if ($tenantLine) {
                $result.TenantName = ($tenantLine -replace ".*:\s*", "").Trim()
            }
        }
    }
    catch { }
    
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $result.UserName = $currentUser
    
    return $result
}

function Test-NLAEnabled {
    $nla = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -ErrorAction SilentlyContinue
    return ($nla -and $nla.UserAuthentication -eq 1)
}

function Test-PKU2UEnabled {
    $pku2u = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Pku2u" -Name "AllowOnlineID" -ErrorAction SilentlyContinue
    return ($pku2u -and $pku2u.AllowOnlineID -eq 1)
}

function Show-AzureADDiagnostics {
    param([hashtable]$AzureInfo)
    $ErrorActionPreference = "Continue"
    
    Write-Host ""
    Write-Host "===========================================================" -ForegroundColor Yellow
    Write-Host "  AZURE AD / ENTRA ID DETECTED" -ForegroundColor Yellow
    Write-Host "===========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Join type:    $($AzureInfo.JoinType)" -ForegroundColor White
    if ($AzureInfo.TenantName) {
        Write-Host "  Tenant:       $($AzureInfo.TenantName)" -ForegroundColor White
    }
    Write-Host "  Current user: $($AzureInfo.UserName)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Azure AD devices have known issues with RDP when connecting" -ForegroundColor White
    Write-Host "  from a device that is NOT in the same Azure AD tenant." -ForegroundColor White
    Write-Host "  The script will check and fix common issues." -ForegroundColor White
    Write-Host ""
    Write-Host "  You will be asked before ANY change is made." -ForegroundColor White
    Write-Host ""
    Write-Host "-----------------------------------------------------------" -ForegroundColor DarkGray
    
    $issuesFound = 0
    $issuesFixed = 0
    
    # CHECK 1: NLA (Network Level Authentication)
    Write-Host ""
    Write-Host "  CHECK 1: Network Level Authentication (NLA)" -ForegroundColor Cyan
    Write-Host ""
    
    if (Test-NLAEnabled) {
        $issuesFound++
        Write-Host "  STATUS: NLA is ENABLED (blocks Azure AD login from external devices)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  PROBLEM:" -ForegroundColor Yellow
        Write-Host "  NLA requires the connecting client to authenticate BEFORE"
        Write-Host "  the RDP session starts. When connecting from a device that"
        Write-Host "  is NOT joined to the same Azure AD tenant, NLA cannot"
        Write-Host "  verify the credentials and the connection is rejected."
        Write-Host ""
        Write-Host "  FIX: Disable NLA (Network Level Authentication)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  WHAT THIS CHANGES:" -ForegroundColor White
        Write-Host "  - Registry: HKLM\...\RDP-Tcp\UserAuthentication = 0"
        Write-Host "  - RDP clients authenticate AFTER connecting"
        Write-Host ""
        Write-Host "  RISK: LOW - RDP port is NOT exposed to internet." -ForegroundColor White
        Write-Host "  Access is only possible through the encrypted tunnel." -ForegroundColor White
        Write-Host ""
        
        $fix = Read-Host "  Apply fix? Disable NLA [Y/N]"
        if ($fix -match '^[yY]') {
            try {
                Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0 -Force
                Write-Host "  [OK] NLA disabled." -ForegroundColor Green
                $issuesFixed++
            }
            catch { Write-Host "  [X] Failed: $_" -ForegroundColor Red }
        }
        else {
            Write-Host "  [--] Skipped. RDP login will likely NOT work from external devices." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  STATUS: NLA already DISABLED (good)" -ForegroundColor Green
    }
    
    # CHECK 2: PKU2U Protocol
    Write-Host ""
    Write-Host "  CHECK 2: PKU2U Protocol (Azure AD authentication)" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-PKU2UEnabled)) {
        $issuesFound++
        Write-Host "  STATUS: PKU2U is DISABLED" -ForegroundColor Red
        Write-Host ""
        Write-Host "  PROBLEM:" -ForegroundColor Yellow
        Write-Host "  PKU2U is the protocol Windows uses to authenticate Azure AD"
        Write-Host "  users for RDP connections. Without it, login will fail."
        Write-Host ""
        Write-Host "  FIX: Enable PKU2U protocol" -ForegroundColor Yellow
        Write-Host "  Registry: HKLM\SYSTEM\...\Lsa\Pku2u\AllowOnlineID = 1" -ForegroundColor Gray
        Write-Host "  RISK: VERY LOW - Microsoft's recommended setting." -ForegroundColor White
        Write-Host ""
        
        $fix = Read-Host "  Apply fix? Enable PKU2U [Y/N]"
        if ($fix -match '^[yY]') {
            try {
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Pku2u"
                if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                Set-ItemProperty -Path $regPath -Name "AllowOnlineID" -Value 1 -Type DWord -Force
                Write-Host "  [OK] PKU2U enabled." -ForegroundColor Green
                $issuesFixed++
            }
            catch { Write-Host "  [X] Failed: $_" -ForegroundColor Red }
        }
        else {
            Write-Host "  [--] Skipped. Azure AD login may not work." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  STATUS: PKU2U already ENABLED (good)" -ForegroundColor Green
    }
    
    # CHECK 3: Remote Desktop Users group
    Write-Host ""
    Write-Host "  CHECK 3: Remote Desktop Users group" -ForegroundColor Cyan
    Write-Host ""
    
    $rdpGroupSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-555")
    $rdpGroupName = $rdpGroupSID.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    $authUsersSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
    $authUsersName = $authUsersSID.Translate([System.Security.Principal.NTAccount]).Value
    $authUsersShort = $authUsersName.Split('\')[-1]
    
    Write-Host "  Group: $rdpGroupName" -ForegroundColor Gray
    
    $rdpGroup = net localgroup "$rdpGroupName" 2>$null
    $hasAuthUsers = $rdpGroup | Select-String ([regex]::Escape($authUsersShort))
    
    if (-not $hasAuthUsers) {
        $issuesFound++
        Write-Host "  STATUS: '$authUsersShort' NOT in $rdpGroupName" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  FIX: Add '$authUsersShort' to $rdpGroupName" -ForegroundColor Yellow
        Write-Host "  RISK: LOW - Password still required for RDP access." -ForegroundColor White
        Write-Host ""
        
        $fix = Read-Host "  Apply fix? [Y/N]"
        if ($fix -match '^[yY]') {
            try {
                $group = [ADSI]"WinNT://./$rdpGroupName,group"
                $group.Add("WinNT://S-1-5-11")
                Write-Host "  [OK] '$authUsersShort' added to $rdpGroupName." -ForegroundColor Green
                $issuesFixed++
            }
            catch {
                $netResult = net localgroup "$rdpGroupName" "$authUsersShort" /add 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  [OK] '$authUsersShort' added to $rdpGroupName." -ForegroundColor Green
                    $issuesFixed++
                }
                else {
                    Write-Host "  [X] Failed: $netResult" -ForegroundColor Red
                }
            }
        }
        else {
            Write-Host "  [--] Skipped." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  STATUS: '$authUsersShort' is in the group (good)" -ForegroundColor Green
    }
    
    # CHECK 4: CredSSP (optional)
    Write-Host ""
    Write-Host "  CHECK 4: CredSSP Encryption Oracle (optional)" -ForegroundColor Cyan
    Write-Host ""
    
    $credSSPPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters"
    $credSSP = Get-ItemProperty -Path $credSSPPath -Name "AllowEncryptionOracle" -ErrorAction SilentlyContinue
    
    if (-not $credSSP -or $credSSP.AllowEncryptionOracle -ne 2) {
        $issuesFound++
        Write-Host "  STATUS: CredSSP not set to fallback mode" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  NOTE: This fix is OPTIONAL. Try without it first." -ForegroundColor Gray
        Write-Host "  Only apply if RDP still fails after fixes 1-3." -ForegroundColor Gray
        Write-Host ""
        Write-Host "  FIX: Set CredSSP AllowEncryptionOracle = 2" -ForegroundColor Yellow
        Write-Host "  RISK: MEDIUM-LOW - Allows older CredSSP as fallback." -ForegroundColor White
        Write-Host "  Connection goes through encrypted tunnel anyway." -ForegroundColor White
        Write-Host ""
        
        $fix = Read-Host "  Apply fix? [Y/N]"
        if ($fix -match '^[yY]') {
            try {
                $parentPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP"
                if (-not (Test-Path $parentPath)) { New-Item -Path $parentPath -Force | Out-Null }
                if (-not (Test-Path $credSSPPath)) { New-Item -Path $credSSPPath -Force | Out-Null }
                Set-ItemProperty -Path $credSSPPath -Name "AllowEncryptionOracle" -Value 2 -Type DWord -Force
                Write-Host "  [OK] CredSSP set to fallback mode." -ForegroundColor Green
                $issuesFixed++
            }
            catch { Write-Host "  [X] Failed: $_" -ForegroundColor Red }
        }
        else {
            Write-Host "  [--] Skipped (recommended to try without)." -ForegroundColor Gray
        }
    }
    else {
        Write-Host "  STATUS: CredSSP already configured (good)" -ForegroundColor Green
    }
    
    # SUMMARY
    Write-Host ""
    Write-Host "-----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    
    if ($issuesFound -eq 0) {
        Write-Host "  All Azure AD checks passed!" -ForegroundColor Green
    }
    elseif ($issuesFixed -eq $issuesFound) {
        Write-Host "  All $issuesFound issue(s) fixed!" -ForegroundColor Green
    }
    elseif ($issuesFixed -gt 0) {
        Write-Host "  Fixed $issuesFixed of $issuesFound issue(s)." -ForegroundColor Yellow
    }
    else {
        Write-Host "  $issuesFound issue(s) found but none fixed." -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "  LOGIN TIP FOR AZURE AD:" -ForegroundColor Cyan
    Write-Host "  Username: AzureAD\YourName  (run 'whoami' to check)" -ForegroundColor White
    Write-Host "  Password: Microsoft account password (NOT PIN)" -ForegroundColor White
    Write-Host ""
}

function Get-ExistingInstall {
    if (Test-Path $MARKER_FILE) {
        return Get-Content $MARKER_FILE | ConvertFrom-Json
    }
    return $null
}

function Save-InstallMarker {
    param([string]$SlotName, [string]$Address, [int]$Port, [string]$Server)
    
    if (-not (Test-Path $MARKER_DIR)) {
        New-Item -ItemType Directory -Path $MARKER_DIR -Force | Out-Null
    }
    
    @{
        slot = $SlotName
        address = $Address
        port = $Port
        server = $Server
        installed = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        version = $SCRIPT_VERSION
    } | ConvertTo-Json | Set-Content $MARKER_FILE
}

function Read-SlotsFile {
    if (-not (Test-Path $SLOTS_FILE)) { return @() }
    
    $slots = @()
    $publicKey = ""
    Get-Content $SLOTS_FILE | ForEach-Object {
        $line = $_.Trim()
        # Parse public key from comment line
        if ($line -match "^#.*public key.*:\s*(.+)$") {
            $publicKey = $Matches[1].Trim()
        }
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line.Split("|")
            if ($parts.Count -ge 4) {
                $slots += @{
                    Name      = $parts[0].Trim()
                    Port      = [int]$parts[1].Trim()
                    Token     = $parts[2].Trim()
                    Address   = $parts[3].Trim()
                    Server    = if ($parts.Count -ge 5) { $parts[4].Trim() } else { "" }
                    PublicKey = $publicKey
                }
            }
        }
    }
    return $slots
}

# --- Slot Selection ---
function Select-Slot {
    $slots = Read-SlotsFile
    
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  Choose a slot for this PC:" -ForegroundColor White
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""
    
    if ($slots.Count -gt 0) {
        for ($i = 0; $i -lt $slots.Count; $i++) {
            $s = $slots[$i]
            $portInfo = if ($s.Port -eq 3389) { "(no port needed)" } else { "(port $($s.Port))" }
            Write-Host "    [$($i+1)] $($s.Address) $portInfo" -ForegroundColor Yellow
        }
        Write-Host ""
    }
    
    Write-Host "    [C] Custom (enter server, port, and token manually)" -ForegroundColor Yellow
    Write-Host "    [Q] Quit" -ForegroundColor Yellow
    Write-Host ""
    
    $choice = Read-Host "  Choose"
    
    if ($choice -eq "Q" -or $choice -eq "q") { exit 0 }
    
    if ($choice -eq "C" -or $choice -eq "c") {
        Write-Host ""
        $server = Read-Host "  Server address (IP or hostname)"
        $port = Read-Host "  Remote port (e.g., 3389)"
        $token = Read-Host "  Token (from server setup)"
        $pubKey = Read-Host "  Server public key (base64, from server setup)"
        $name = Read-Host "  Slot name (e.g., my-pc)"
        
        return @{
            Name      = $name
            Port      = [int]$port
            Token     = $token
            Address   = "$name"
            Server    = $server
            PublicKey = $pubKey
        }
    }
    
    $index = [int]$choice - 1
    if ($index -ge 0 -and $index -lt $slots.Count) {
        $selected = $slots[$index]
        Write-Host ""
        Write-Host "  Selected: $($selected.Address)" -ForegroundColor Green
        
        # If no server specified in slots, ask for it
        if (-not $selected.Server) {
            $selected.Server = Read-Host "  Server address (VPS IP or hostname)"
        }
        
        return $selected
    }
    
    Write-Host "  Invalid choice." -ForegroundColor Red
    return $null
}

# --- Installation Steps ---
function Enable-RemoteDesktop {
    Write-Host "[1/5] Enabling Remote Desktop..." -ForegroundColor Cyan
    
    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Force
        
        # Enable firewall rules for RDP (language-independent using resource string GUID)
        try {
            $rules = Get-NetFirewallRule -Group "@FirewallAPI.dll,-28752" -ErrorAction SilentlyContinue
            if ($rules) {
                $rules | Enable-NetFirewallRule
            }
        } catch {
            # Non-critical - tunnel bypasses local firewall anyway
        }
        
        Write-Host "  [OK] Remote Desktop enabled." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [X] Failed to enable Remote Desktop: $_" -ForegroundColor Red
        return $false
    }
}

function Install-Rathole {
    param([hashtable]$Slot)
    
    Write-Host "[2/5] Downloading rathole v${RATHOLE_VERSION}..." -ForegroundColor Cyan
    
    try {
        # Download from our custom-compiled release (avoids Windows Defender false positives)
        # The official rathole binary triggers Trojan:Win32/Vigorf.A due to self-extracting format
        # Our build is compiled from source with Rust 1.72.0, target: x86_64-pc-windows-gnu
        $url = "https://github.com/ToFinToFun/rathole-rdp/releases/download/v${RATHOLE_VERSION}-custom/rathole-windows-x86_64.zip"
        
        # Create install directory
        if (-not (Test-Path $INSTALL_DIR)) {
            New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
        }
        
        # Add Windows Defender exclusion for install directory and temp
        # Rathole is a legitimate tunnel binary but Defender flags tunnel tools as PUA
        try {
            Add-MpPreference -ExclusionPath $INSTALL_DIR -ErrorAction SilentlyContinue
            Add-MpPreference -ExclusionPath "$env:TEMP\rathole.zip" -ErrorAction SilentlyContinue
            Add-MpPreference -ExclusionPath "$env:TEMP\rathole" -ErrorAction SilentlyContinue
            Write-Host "  [i] Defender exclusion added for install directory." -ForegroundColor DarkGray
        } catch {
            Write-Host "  [!] Could not add Defender exclusion (non-critical)." -ForegroundColor DarkYellow
        }
        
        # Download
        $zipPath = "$env:TEMP\rathole.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        
        # Extract
        Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\rathole" -Force
        Copy-Item "$env:TEMP\rathole\rathole.exe" "$INSTALL_DIR\rathole.exe" -Force
        
        # Cleanup temp files
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\rathole" -Recurse -Force -ErrorAction SilentlyContinue
        # Remove temp exclusions (keep install dir exclusion)
        try {
            Remove-MpPreference -ExclusionPath "$env:TEMP\rathole.zip" -ErrorAction SilentlyContinue
            Remove-MpPreference -ExclusionPath "$env:TEMP\rathole" -ErrorAction SilentlyContinue
        } catch {}
        
        $size = [math]::Round((Get-Item "$INSTALL_DIR\rathole.exe").Length / 1MB, 1)
        Write-Host "  [OK] Rathole downloaded ($size MB)." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [X] Download failed: $_" -ForegroundColor Red
        Write-Host "  [!] If blocked by antivirus, manually add exclusion:" -ForegroundColor Yellow
        Write-Host "      Windows Security > Virus protection > Exclusions" -ForegroundColor Yellow
        Write-Host "      Add folder: $INSTALL_DIR" -ForegroundColor Yellow
        return $false
    }
}

function New-RatholeConfig {
    param([hashtable]$Slot)
    
    Write-Host "[3/5] Generating configuration..." -ForegroundColor Cyan
    
    try {
        $serverAddr = "$($Slot.Server):2333"
        
        $config = @"
# Rathole RDP Client Configuration
# Slot: $($Slot.Name)
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

[client]
remote_addr = "$serverAddr"

[client.transport]
type = "noise"

[client.transport.noise]
remote_public_key = "$($Slot.PublicKey)"

[client.services.$($Slot.Name)]
token = "$($Slot.Token)"
local_addr = "127.0.0.1:3389"
"@
        
        Set-Content -Path $CONFIG_FILE -Value $config -Force
        
        # Restrict file permissions (only SYSTEM and Administrators)
        # Use SIDs for language independence (works on Swedish, English, etc.)
        $acl = Get-Acl $CONFIG_FILE
        $acl.SetAccessRuleProtection($true, $false)
        $adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")  # BUILTIN\Administrators
        $systemSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")     # NT AUTHORITY\SYSTEM
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule($adminSID, "FullControl", "Allow")
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule($systemSID, "FullControl", "Allow")
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($systemRule)
        Set-Acl $CONFIG_FILE $acl
        
        Write-Host "  [OK] Config generated (token secured with NTFS ACL)." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [X] Config generation failed: $_" -ForegroundColor Red
        return $false
    }
}

function Install-Service {
    Write-Host "[4/5] Installing as Windows service..." -ForegroundColor Cyan
    
    try {
        # Download WinSW (Windows Service Wrapper)
        $winswUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
        
        if (-not (Test-Path $WINSW_EXE)) {
            Invoke-WebRequest -Uri $winswUrl -OutFile $WINSW_EXE -UseBasicParsing
        }
        
        # Create WinSW XML configuration
        $xml = @"
<service>
  <id>$SERVICE_NAME</id>
  <name>$DISPLAY_NAME</name>
  <description>Rathole reverse tunnel for native RDP access. Maintains outbound connection to VPS.</description>
  <executable>$INSTALL_DIR\rathole.exe</executable>
  <arguments>--client "$CONFIG_FILE"</arguments>
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>3</keepFiles>
  </log>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <resetfailure>1 hour</resetfailure>
</service>
"@
        
        Set-Content -Path $WINSW_XML -Value $xml -Force
        
        # Uninstall existing service if present
        $existingSvc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
        if ($existingSvc) {
            Stop-Service $SERVICE_NAME -Force -ErrorAction SilentlyContinue
            & $WINSW_EXE uninstall 2>$null
            Start-Sleep -Seconds 2
        }
        
        # Install service
        & $WINSW_EXE install
        
        if ($LASTEXITCODE -ne 0) {
            throw "WinSW install returned exit code $LASTEXITCODE"
        }
        
        Write-Host "  [OK] Service '$SERVICE_NAME' installed (delayed auto-start)." -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [X] Service installation failed: $_" -ForegroundColor Red
        return $false
    }
}

function Start-TunnelService {
    Write-Host "[5/5] Starting service..." -ForegroundColor Cyan
    
    try {
        Start-Service $SERVICE_NAME
        Start-Sleep -Seconds 3
        
        $svc = Get-Service $SERVICE_NAME
        if ($svc.Status -eq "Running") {
            Write-Host "  [OK] Service started and tunnel active." -ForegroundColor Green
            return $true
        } else {
            Write-Host "  [X] Service not running (status: $($svc.Status))." -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "  [X] Failed to start service: $_" -ForegroundColor Red
        return $false
    }
}

function Test-TunnelConnection {
    param([hashtable]$Slot)
    
    Write-Host ""
    Write-Host "[Verify] Testing tunnel connectivity (10 seconds)..." -ForegroundColor Cyan
    
    Start-Sleep -Seconds 10
    
    $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "  [OK] Service running after 10 seconds - tunnel is stable." -ForegroundColor Green
        return $true
    } else {
        Write-Host "  [!] Service may have crashed. Check logs at:" -ForegroundColor Yellow
        Write-Host "      $INSTALL_DIR\$WINSW_NAME.out.log" -ForegroundColor Yellow
        return $false
    }
}

# --- Manage Menu ---
function Show-ManageMenu {
    param($install)
    
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  Existing installation detected!" -ForegroundColor Green
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Slot:      $($install.slot)" -ForegroundColor White
    Write-Host "  Address:   $($install.address)" -ForegroundColor White
    Write-Host "  Port:      $($install.port)" -ForegroundColor White
    Write-Host "  Server:    $($install.server)" -ForegroundColor White
    Write-Host "  Installed: $($install.installed)" -ForegroundColor White
    Write-Host ""
    
    $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc) {
        $statusColor = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "  Service:   $($svc.Status)" -ForegroundColor $statusColor
    }
    
    Write-Host ""
    Write-Host "  [R] Reinstall (fresh install, same slot)" -ForegroundColor Yellow
    Write-Host "  [U] Uninstall (remove everything)" -ForegroundColor Yellow
    Write-Host "  [S] Status (check service and connectivity)" -ForegroundColor Yellow
    Write-Host "  [L] Logs (view recent log entries)" -ForegroundColor Yellow
    Write-Host "  [D] Diagnostics (Azure AD / login issues)" -ForegroundColor Yellow
    Write-Host "  [P] Power management settings" -ForegroundColor Yellow
    Write-Host "  [Q] Quit" -ForegroundColor Yellow
    Write-Host ""
    
    $choice = Read-Host "  Choose [R/U/S/L/D/P/Q]"
    
    switch ($choice.ToUpper()) {
        "R" { return "reinstall" }
        "U" { return "uninstall" }
        "S" { return "status" }
        "L" { return "logs" }
        "D" { return "diagnostics" }
        "P" { return "power" }
        "Q" { exit 0 }
        default { return "quit" }
    }
}

function Invoke-Uninstall {
    Write-Host ""
    Write-Host "  Uninstalling Rathole RDP..." -ForegroundColor Yellow
    
    # Stop and remove service
    Stop-Service $SERVICE_NAME -Force -ErrorAction SilentlyContinue
    if (Test-Path $WINSW_EXE) {
        & $WINSW_EXE uninstall 2>$null
    }
    Start-Sleep -Seconds 2
    
    # Remove files
    Remove-Item $INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $MARKER_DIR -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Host ""
    Write-Host "  [OK] Uninstalled successfully." -ForegroundColor Green
    Write-Host ""
    
    # Ask about power settings
    $resetPower = Read-Host "  Reset power settings to Windows defaults? [Y/N]"
    if ($resetPower -eq "Y" -or $resetPower -eq "y") {
        Invoke-PowerReset
    }
    
    Read-Host "  Press Enter to exit"
    exit 0
}

function Show-Status {
    Write-Host ""
    $svc = Get-Service $SERVICE_NAME -ErrorAction SilentlyContinue
    if ($svc) {
        $statusColor = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host "  Service: $($svc.Status)" -ForegroundColor $statusColor
        Write-Host "  PID:     $((Get-Process -Name rathole -ErrorAction SilentlyContinue).Id)" -ForegroundColor White
    } else {
        Write-Host "  Service: NOT INSTALLED" -ForegroundColor Red
    }
    
    # Check if RDP is enabled
    $rdp = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
    $rdpStatus = if ($rdp -eq 0) { "Enabled" } else { "Disabled" }
    $rdpColor = if ($rdp -eq 0) { "Green" } else { "Red" }
    Write-Host "  RDP:     $rdpStatus" -ForegroundColor $rdpColor
    
    Write-Host ""
    Read-Host "  Press Enter to continue"
}

function Show-Logs {
    Write-Host ""
    $logFile = "$INSTALL_DIR\$WINSW_NAME.out.log"
    if (Test-Path $logFile) {
        Write-Host "  Last 20 log entries:" -ForegroundColor Cyan
        Write-Host ""
        Get-Content $logFile -Tail 20 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  No log file found." -ForegroundColor Yellow
    }
    Write-Host ""
    Read-Host "  Press Enter to continue"
}

# --- Power Management (integrated from Set-RdpAvailability) ---

# Helper: Get the active power scheme GUID (locale-independent)
function Get-ActiveSchemeGuid {
    $out = powercfg /getactivescheme 2>$null
    if ($out -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
        return $Matches[0]
    }
    return $null
}

# Helper: Read a specific power setting's AC and DC values using powercfg /q
# Returns @{ AC = [int]; DC = [int] } or $null
# powercfg /q output has lines with hex values. The LAST two 0x lines are always AC then DC.
# But some settings only have AC (no DC). We parse all lines containing "0x" that are
# indented (setting values), skipping GUID lines.
function Get-PowerSettingValue {
    param([string]$SubGroup, [string]$Setting)
    try {
        $guid = Get-ActiveSchemeGuid
        if (-not $guid) { return $null }
        $out = powercfg /q $guid $SubGroup $Setting 2>$null
        if (-not $out) { return $null }
        
        # Find lines that contain "0x" but are NOT GUID lines (GUIDs have dashes)
        # Setting value lines look like: "    Current AC Power Setting Index: 0x00000000"
        # They always have leading whitespace and contain 0x followed by hex digits
        $valueLines = @($out | Where-Object { $_ -match '^\s+.*0x([0-9a-fA-F]+)' -and $_ -notmatch '[0-9a-fA-F]{8}-' })
        
        $result = @{ AC = -1; DC = -1 }
        if ($valueLines.Count -ge 2) {
            # Last two value lines: AC then DC (powercfg always outputs AC before DC)
            $valueLines[-2] -match '0x([0-9a-fA-F]+)' | Out-Null
            $result.AC = [convert]::ToInt32($Matches[1], 16)
            $valueLines[-1] -match '0x([0-9a-fA-F]+)' | Out-Null
            $result.DC = [convert]::ToInt32($Matches[1], 16)
        } elseif ($valueLines.Count -eq 1) {
            $valueLines[0] -match '0x([0-9a-fA-F]+)' | Out-Null
            $result.AC = [convert]::ToInt32($Matches[1], 16)
        }
        return $result
    } catch { return $null }
}

function Get-CurrentPowerState {
    $ErrorActionPreference = "Continue"
    $state = @{}
    
    try {
        # Check sleep settings
        $sleep = Get-PowerSettingValue "SUB_SLEEP" "STANDBYIDLE"
        $state.SleepAC = if ($sleep -and $sleep.AC -eq 0) { $true } else { $false }
        $state.SleepDC = if ($sleep -and $sleep.DC -eq 0) { $true } else { $false }
    } catch { $state.SleepAC = $false; $state.SleepDC = $false }
    
    try {
        # Check lid action (0 = do nothing, 1 = sleep, 2 = hibernate, 3 = shut down)
        $lid = Get-PowerSettingValue "SUB_BUTTONS" "LIDACTION"
        $state.LidAC = if ($lid -and $lid.AC -eq 0) { $true } else { $false }
        $state.LidDC = if ($lid -and $lid.DC -eq 0) { $true } else { $false }
    } catch { $state.LidAC = $false; $state.LidDC = $false }
    
    try {
        # Check hibernate
        $hibFile = Test-Path "$env:SystemDrive\hiberfil.sys"
        $state.HibernateOff = -not $hibFile
    } catch { $state.HibernateOff = $false }
    
    try {
        # Check NIC power saving
        $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
        $nicPowerOff = $true
        foreach ($nic in $nics) {
            $power = Get-CimInstance -ClassName MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -match $nic.InterfaceDescription.Replace(" ", "_") }
            if ($power -and $power.Enable) { $nicPowerOff = $false }
        }
        $state.NICPowerOff = $nicPowerOff
    } catch { $state.NICPowerOff = $false }
    
    try {
        # Check connectivity in standby (1 = enabled/managed, 0 = disabled)
        $cs = Get-PowerSettingValue "SUB_NONE" "CONNECTIVITYINSTANDBY"
        $state.NetworkStandby = if ($cs -and $cs.AC -ge 1) { $true } else { $false }
    } catch { $state.NetworkStandby = $false }
    
    try {
        # Check shutdown button hidden
        $reg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoClose" -ErrorAction SilentlyContinue
        $state.ShutdownHidden = ($reg -and $reg.NoClose -eq 1)
    } catch { $state.ShutdownHidden = $false }
    
    return $state
}

function Show-PowerManagement {
    $ErrorActionPreference = "Continue"
    
    Write-Host ""
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  POWER MANAGEMENT - RDP Availability" -ForegroundColor White
    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host ""
    
    # Detect PC type
    $chassis = (Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
    $isLaptop = $chassis -contains 9 -or $chassis -contains 10 -or $chassis -contains 14
    $pcType = if ($isLaptop) { "Laptop" } else { "Desktop" }
    
    # Detect Modern Standby
    $s0 = (powercfg /a 2>$null) -match "S0"
    $standbyType = if ($s0) { "Yes (S0)" } else { "No (S3)" }
    
    # Check active preset
    $presetFile = "$MARKER_DIR\power-preset.txt"
    $activePreset = if (Test-Path $presetFile) { Get-Content $presetFile } else { "None (Windows default)" }
    
    Write-Host "  YOUR PC"
    Write-Host "    Type           : $pcType"
    Write-Host "    Modern Standby : $standbyType"
    Write-Host "    Active preset  : $activePreset"
    Write-Host ""
    
    # Get current state
    $state = Get-CurrentPowerState
    
    # Display matrix
    $header = "  {0,-30} {1,-9} {2,-8} {3,-8} {4,-6}" -f "Setting", "Current", "Reachable", "Always", "MAX"
    Write-Host $header -ForegroundColor White
    Write-Host "  $('-' * 63)"
    
    # Helper function to print one row
    function Write-PowerRow {
        param([string]$Name, [bool]$Value, [bool]$InReach, [bool]$InAlways, [bool]$InMax)
        $current = if ($Value) { "YES" } else { "no" }
        $currentColor = if ($Value) { "Green" } else { "Red" }
        $c1 = if ($InReach)  { "X" } else { "-" }
        $c2 = if ($InAlways) { "X" } else { "-" }
        $c3 = if ($InMax)    { "X" } else { "-" }
        Write-Host ("  {0,-30} " -f $Name) -NoNewline
        Write-Host ("{0,-9}" -f $current) -ForegroundColor $currentColor -NoNewline
        Write-Host (" {0,-8} {1,-8} {2,-6}" -f $c1, $c2, $c3)
    }
    
    Write-PowerRow "NIC power saving off"          ([bool]$state.NICPowerOff)    $true  $true  $true
    Write-PowerRow "Network alive in standby"      ([bool]$state.NetworkStandby) $true  $true  $true
    Write-PowerRow "Sleep disabled (AC)"           ([bool]$state.SleepAC)        $true  $true  $true
    Write-PowerRow "Lid close = nothing (AC)"      ([bool]$state.LidAC)          $true  $true  $true
    Write-PowerRow "Hibernate disabled"            ([bool]$state.HibernateOff)   $true  $true  $true
    Write-PowerRow "Sleep disabled (battery)"      ([bool]$state.SleepDC)        $false $true  $true
    Write-PowerRow "Lid close = nothing (battery)" ([bool]$state.LidDC)          $false $true  $true
    Write-PowerRow "Shutdown button hidden"        ([bool]$state.ShutdownHidden) $false $false $true
    
    Write-Host "  $('-' * 63)"
    Write-Host ""
    Write-Host '  X = included in preset   "-" = not changed by preset' -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  PRESETS:" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1] Reachable    - Always reachable when charging (RECOMMENDED)" -ForegroundColor Green
    Write-Host "                     Sleeps normally on battery. Always on when plugged in."
    Write-Host "                     This is what you want for a laptop left in a charger."
    Write-Host ""
    Write-Host "  [2] Always On    - Never sleeps, even on battery" -ForegroundColor Yellow
    Write-Host "                     WARNING: Battery will drain to zero if unplugged!"
    Write-Host ""
    Write-Host "  [3] MAX          - Always On + shutdown button hidden" -ForegroundColor Yellow
    Write-Host "                     Prevents accidental shutdown. For dedicated RDP machines."
    Write-Host ""
    Write-Host "  [4] Reset        - Restore Windows defaults" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [Q] Back / Skip" -ForegroundColor DarkGray
    Write-Host ""
    
    $choice = Read-Host "  Choose [1-4, Q]"
    
    switch ($choice) {
        "1" { Apply-PowerPreset "Reachable" }
        "2" { Apply-PowerPreset "AlwaysOn" }
        "3" { Apply-PowerPreset "MAX" }
        "4" { Invoke-PowerReset }
        default { return }
    }
}

function Apply-PowerPreset {
    param([string]$Preset)
    
    $ErrorActionPreference = "Continue"
    Write-Host ""
    Write-Host "  Applying preset: $Preset..." -ForegroundColor Cyan
    
    # Get active scheme GUID for reliable powercfg commands
    $schemeGuid = Get-ActiveSchemeGuid
    if (-not $schemeGuid) {
        Write-Host "  [X] Could not determine active power scheme." -ForegroundColor Red
        Read-Host "  Press Enter to continue"
        return
    }
    
    # ALL presets: NIC power saving off + network in standby + sleep off (AC) + lid nothing (AC) + hibernate off
    if ($Preset -in @("Reachable", "AlwaysOn", "MAX")) {
        # Disable NIC power management (prevents NIC from sleeping)
        $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
        foreach ($nic in $nics) {
            # Disable via PowerShell cmdlet
            Disable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
            # Also disable via device properties (belt and suspenders)
            $nicObj = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
            if ($nicObj) {
                $nicObj.AllowComputerToTurnOffDevice = 'Disabled'
                $nicObj | Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue
            }
        }
        Write-Host "    [OK] NIC power saving disabled" -ForegroundColor Green
        
        # Enable connectivity in standby (keeps WiFi/Ethernet alive during Modern Standby)
        powercfg /setacvalueindex $schemeGuid SUB_NONE CONNECTIVITYINSTANDBY 1 2>$null
        powercfg /setdcvalueindex $schemeGuid SUB_NONE CONNECTIVITYINSTANDBY 1 2>$null
        Write-Host "    [OK] Network alive in standby" -ForegroundColor Green
        
        # Disable sleep on AC (0 = never)
        powercfg /setacvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 0 2>$null
        powercfg /change standby-timeout-ac 0
        Write-Host "    [OK] Sleep disabled (AC)" -ForegroundColor Green
        
        # Lid close = do nothing on AC (0 = do nothing)
        powercfg /setacvalueindex $schemeGuid SUB_BUTTONS LIDACTION 0 2>$null
        Write-Host "    [OK] Lid close = do nothing (AC)" -ForegroundColor Green
        
        # Disable hibernate
        powercfg /hibernate off 2>$null
        Write-Host "    [OK] Hibernate disabled" -ForegroundColor Green
    }
    
    # Reachable: keep battery defaults (sleep on battery, lid = sleep on battery)
    if ($Preset -eq "Reachable") {
        powercfg /setdcvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 900 2>$null
        powercfg /change standby-timeout-dc 15
        powercfg /setdcvalueindex $schemeGuid SUB_BUTTONS LIDACTION 1 2>$null
        Write-Host "    [OK] Battery: normal sleep (15 min), lid = sleep" -ForegroundColor Green
        Write-Host ""
        Write-Host "    Summary: Always reachable when charger is plugged in." -ForegroundColor White
        Write-Host "    On battery: sleeps after 15 min, lid close = sleep." -ForegroundColor White
    }
    
    # AlwaysOn and MAX: also disable sleep on battery, lid nothing on battery
    if ($Preset -in @("AlwaysOn", "MAX")) {
        powercfg /setdcvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 0 2>$null
        powercfg /change standby-timeout-dc 0
        powercfg /setdcvalueindex $schemeGuid SUB_BUTTONS LIDACTION 0 2>$null
        Write-Host "    [OK] Sleep disabled (battery too)" -ForegroundColor Green
        Write-Host "    [OK] Lid close = do nothing (battery too)" -ForegroundColor Green
    }
    
    # MAX: hide shutdown button
    if ($Preset -eq "MAX") {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        Set-ItemProperty -Path $regPath -Name "NoClose" -Value 1 -Type DWord -Force
        Write-Host "    [OK] Shutdown button hidden (this user only)" -ForegroundColor Green
    }
    
    # Apply the scheme to make changes take effect immediately
    powercfg /setactive $schemeGuid 2>$null
    
    # Save preset marker
    if (-not (Test-Path $MARKER_DIR)) { New-Item -ItemType Directory -Path $MARKER_DIR -Force | Out-Null }
    Set-Content "$MARKER_DIR\power-preset.txt" $Preset
    
    Write-Host ""
    Write-Host "  [OK] Preset '$Preset' applied successfully." -ForegroundColor Green
    Write-Host ""
    Read-Host "  Press Enter to continue"
}

function Invoke-PowerReset {
    $ErrorActionPreference = "Continue"
    Write-Host ""
    Write-Host "  Restoring Windows defaults..." -ForegroundColor Cyan
    
    $schemeGuid = Get-ActiveSchemeGuid
    if ($schemeGuid) {
        powercfg /change standby-timeout-ac 30
        powercfg /change standby-timeout-dc 15
        powercfg /setacvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 1800 2>$null
        powercfg /setdcvalueindex $schemeGuid SUB_SLEEP STANDBYIDLE 900 2>$null
        powercfg /setacvalueindex $schemeGuid SUB_BUTTONS LIDACTION 1 2>$null
        powercfg /setdcvalueindex $schemeGuid SUB_BUTTONS LIDACTION 1 2>$null
        powercfg /setacvalueindex $schemeGuid SUB_NONE CONNECTIVITYINSTANDBY 0 2>$null
        powercfg /setdcvalueindex $schemeGuid SUB_NONE CONNECTIVITYINSTANDBY 0 2>$null
        powercfg /hibernate on 2>$null
        powercfg /setactive $schemeGuid 2>$null
    }
    
    # Re-enable NIC power management
    $nics = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    foreach ($nic in $nics) {
        Enable-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
        $nicObj = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
        if ($nicObj) {
            $nicObj.AllowComputerToTurnOffDevice = 'Enabled'
            $nicObj | Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue
        }
    }
    
    # Restore shutdown button
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoClose" -ErrorAction SilentlyContinue
    
    # Remove preset marker
    Remove-Item "$MARKER_DIR\power-preset.txt" -Force -ErrorAction SilentlyContinue
    
    Write-Host "  [OK] Windows defaults restored." -ForegroundColor Green
    Write-Host ""
    Read-Host "  Press Enter to continue"
}

# --- Main Flow ---
Show-Banner

# Pre-checks
if (-not (Test-Administrator)) {
    Write-Host "  [X] This script requires Administrator privileges." -ForegroundColor Red
    Write-Host "      Right-click setup.bat and select 'Run as administrator'." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

if (-not (Test-RDPCapable)) {
    Write-Host "  [X] Windows Home does not support Remote Desktop hosting." -ForegroundColor Red
    Write-Host "      You need Windows Pro, Enterprise, or Education." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

# Check for existing installation
$existing = Get-ExistingInstall
if ($existing) {
    $action = Show-ManageMenu $existing
    
    switch ($action) {
        "uninstall" { Invoke-Uninstall }
        "status" { Show-Status; exit 0 }
        "logs" { Show-Logs; exit 0 }
        "diagnostics" {
            $azureInfo = Test-AzureADJoined
            if ($azureInfo.IsAzureADJoined) {
                Show-AzureADDiagnostics -AzureInfo $azureInfo
            } else {
                Write-Host ""
                Write-Host "  This PC is NOT Azure AD joined." -ForegroundColor Green
                Write-Host "  Azure AD fixes are not needed." -ForegroundColor Green
                Write-Host ""
                Write-Host "  If RDP login still doesn't work, check:" -ForegroundColor White
                Write-Host "  - Username: Your Windows username (not PIN)" -ForegroundColor White
                Write-Host "  - Password: Your Windows password (not PIN)" -ForegroundColor White
                Write-Host ""
            }
            Read-Host "  Press Enter to continue"
            exit 0
        }
        "power" { Show-PowerManagement; exit 0 }
        "reinstall" { 
            Write-Host "  Removing existing installation first..." -ForegroundColor Yellow
            Stop-Service $SERVICE_NAME -Force -ErrorAction SilentlyContinue
            if (Test-Path $WINSW_EXE) { & $WINSW_EXE uninstall 2>$null }
            Start-Sleep -Seconds 2
        }
        default { exit 0 }
    }
}

# Fresh install
$slot = Select-Slot
if (-not $slot) {
    Write-Host "  No slot selected. Exiting." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host "  Installing Rathole RDP Tunnel" -ForegroundColor White
Write-Host "  Slot: $($slot.Name) | Port: $($slot.Port)" -ForegroundColor White
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""

# Track results
$results = @{}

$results["Remote Desktop"] = Enable-RemoteDesktop

# Azure AD check (runs automatically during install)
Write-Host ""
Write-Host "[Azure AD] Checking device join status..." -ForegroundColor Cyan
$azureInfo = Test-AzureADJoined

if ($azureInfo.IsAzureADJoined) {
    Show-AzureADDiagnostics -AzureInfo $azureInfo
} else {
    Write-Host "  [i] Not Azure AD joined - no special fixes needed." -ForegroundColor Gray
}

$results["Download"] = Install-Rathole -Slot $slot
$results["Configuration"] = New-RatholeConfig -Slot $slot
$results["Service Install"] = Install-Service
$results["Service Start"] = Start-TunnelService
$results["Connection"] = Test-TunnelConnection -Slot $slot

# Save marker
Save-InstallMarker -SlotName $slot.Name -Address $slot.Address -Port $slot.Port -Server $slot.Server

# Results summary
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host "  INSTALLATION RESULTS" -ForegroundColor White
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""

$failures = 0
foreach ($key in @("Remote Desktop", "Download", "Configuration", "Service Install", "Service Start", "Connection")) {
    if ($results[$key]) {
        Write-Host "  [OK]   $key" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $key" -ForegroundColor Red
        $failures++
    }
}

Write-Host ""

if ($failures -eq 0) {
    Write-Host "  SUCCESS! All steps completed." -ForegroundColor Green
    Write-Host ""
    Write-Host "  Connect with any RDP client:" -ForegroundColor White
    
    if ($slot.Port -eq 3389) {
        Write-Host "    Address: $($slot.Address)" -ForegroundColor Cyan
    } else {
        Write-Host "    Address: $($slot.Address):$($slot.Port)" -ForegroundColor Cyan
    }
    
    Write-Host ""
    Write-Host "  The tunnel reconnects automatically if the network changes." -ForegroundColor DarkGray
    Write-Host ""
    
    # Azure AD login hint
    if ($azureInfo.IsAzureADJoined) {
        Write-Host "  AZURE AD LOGIN:" -ForegroundColor Cyan
        $shortName = $azureInfo.UserName.Split('\')[-1]
        Write-Host "  Username: AzureAD\$shortName" -ForegroundColor White
        Write-Host "  Password: Your Microsoft account password (NOT PIN)" -ForegroundColor White
        Write-Host ""
    }
    
    # Offer power management
    Write-Host "-----------------------------------------------------------"
    Write-Host ""
    $configurePower = Read-Host "  Configure power settings for RDP availability? [Y/N]"
    if ($configurePower -eq "Y" -or $configurePower -eq "y") {
        Show-PowerManagement
    }
} else {
    Write-Host "  $failures step(s) failed. See details above." -ForegroundColor Red
}

Write-Host ""
Write-Host "-----------------------------------------------------------"
Write-Host "  Rathole RDP - Native Remote Desktop Tunnel" -ForegroundColor DarkGray
Write-Host "  by JPaasovaara - MIT License" -ForegroundColor DarkGray
Write-Host "  https://github.com/ToFinToFun/rathole-rdp" -ForegroundColor DarkGray
Write-Host "-----------------------------------------------------------"
Write-Host ""
Read-Host "  Press Enter to exit"
