<#
.SYNOPSIS
    Set or remove a Windows feature override (CFR) without any third-party binary.

.DESCRIPTION
    Windows feature flags live under
        HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\<group>\<featureId>
    That tree is owned by NT SERVICE\TrustedInstaller and Administrators only hold
    ReadKey, so a normal elevated admin cannot write to it.

    This script performs the same sequence tools like ViVeTool do, using only
    documented Win32 APIs:
        1. enable SeTakeOwnershipPrivilege and SeRestorePrivilege
        2. take ownership of the group key (owner field only)
        3. add one allow ACE for BUILTIN\Administrators to the DACL
        4. write the feature values
        5. put the original DACL back and return ownership to TrustedInstaller

    The original security descriptor is always saved first and always restored,
    including when a step fails. Nothing is written unless every earlier step
    succeeded and the owner change was verified by reading it back.

.PARAMETER FeatureId
    The numeric feature id to override, for example 12345678.

.PARAMETER Group
    Override group (priority bucket). Default 0. Existing groups on a typical
    Windows 11 install are 0, 1, 4, 9 and 15.

.PARAMETER State
    Enabled writes EnabledState=2, Disabled writes EnabledState=1.

.PARAMETER Remove
    Delete the override key instead of writing it, returning the feature to the
    Windows default rollout state.

.PARAMETER Repair
    Only fix permissions: remove a leftover Administrators ACE and return the
    key to TrustedInstaller. Use this if a previous run was interrupted.

.PARAMETER BaseKey
    Registry path without the hive, relative to HKLM.

.PARAMETER LogPath
    Directory for the run log. Defaults to .\logs next to this script.

.EXAMPLE
    .\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled -WhatIf

    Shows what would happen. -WhatIf changes nothing and does not need elevation.

.EXAMPLE
    .\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled

    Actually writes the override. Requires an elevated PowerShell window.
    Reboot afterwards for the shell to pick it up.

.EXAMPLE
    .\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove

    Deletes the override key and restores default rollout.

.EXAMPLE
    .\Set-FeatureOverride.ps1 -Repair

    Repairs a key left owned by Administrators after an interrupted run.

.NOTES
    Requires Windows and an elevated PowerShell window for any real change.
    Feature ids change between Windows builds. This tool sets values; it does not
    know which id belongs to which feature.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Set')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
    [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
    # unsigned: real feature ids exceed Int32.MaxValue
    [uint32]$FeatureId,

    [Parameter(ParameterSetName = 'Set')]
    [Parameter(ParameterSetName = 'Remove')]
    [ValidateRange(0, 64)]
    [int]$Group = 0,

    [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
    [ValidateSet('Enabled', 'Disabled')]
    [string]$State,

    [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
    [switch]$Remove,

    [Parameter(Mandatory = $true, ParameterSetName = 'Repair')]
    [switch]$Repair,

    [ValidateNotNullOrEmpty()]
    [string]$BaseKey = 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides',

    [ValidateRange(0, [int]::MaxValue)]
    [int]$Variant = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$VariantPayload = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$VariantPayloadKind = 0,

    # Resolved in the body below: $PSScriptRoot is empty while parameter
    # defaults are evaluated when the script starts via 'powershell -File'.
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# native interop
# ---------------------------------------------------------------------------
if (-not ('CfrNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class CfrNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Priv; }

    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME { public uint dwLowDateTime; public uint dwHighDateTime; }

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES st,
        uint len, IntPtr prev, IntPtr ret);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegOpenKeyEx(IntPtr hKey, string subKey, uint options, int samDesired,
        out IntPtr phkResult);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(IntPtr hKey);

    // SE_REGISTRY_KEY = 4
    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int SetSecurityInfo(IntPtr handle, uint objType, uint secInfo,
        IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl,
        uint rev, out IntPtr psd, out uint size);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern bool GetSecurityDescriptorDacl(IntPtr psd, out bool present,
        out IntPtr dacl, out bool defaulted);

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr h);

    // Returns 0 on success, otherwise the Win32 error code.
    public static int Enable(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return Marshal.GetLastWin32Error();
        LUID luid;
        if (!LookupPrivilegeValue(null, name, out luid)) {
            int e = Marshal.GetLastWin32Error();
            CloseHandle(tok);
            return e;
        }
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Priv.Luid = luid;
        tp.Priv.Attributes = 2;
        bool ok = AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int err = Marshal.GetLastWin32Error();
        CloseHandle(tok);
        if (!ok) return err == 0 ? -1 : err;
        return err; // 1300 == ERROR_NOT_ALL_ASSIGNED
    }

    public static int SetOwner(IntPtr hKey, IntPtr sid) {
        return SetSecurityInfo(hKey, 4, 1, sid, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    }

    public static int ApplyDacl(IntPtr hKey, string sddl) {
        IntPtr psd;
        uint size;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out psd, out size)) {
            return Marshal.GetLastWin32Error();
        }
        try {
            bool present;
            IntPtr dacl;
            bool defaulted;
            if (!GetSecurityDescriptorDacl(psd, out present, out dacl, out defaulted)) {
                return Marshal.GetLastWin32Error();
            }
            if (!present) return 87;
            return SetSecurityInfo(hKey, 4, 4, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
        }
        finally {
            LocalFree(psd);
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
$HKEY_LOCAL_MACHINE = [IntPtr]::new([int64]0x80000002)
$READ_CONTROL = 0x20000
$WRITE_DAC    = 0x40000
$WRITE_OWNER  = 0x80000
$KEY_READ     = 0x20019

$AdminAccount = [Security.Principal.NTAccount]::new('BUILTIN\Administrators')
$AdminSid     = $AdminAccount.Translate([Security.Principal.SecurityIdentifier])
$TiSid        = [Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')
$TiSidValue   = $TiSid.Translate([Security.Principal.SecurityIdentifier])
$AceMarker    = '(A;CI;KA;;;BA)'

$script:LogFile = $null
if (-not $LogPath) {
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptRoot) { $scriptRoot = (Get-Location).Path }
    $LogPath = Join-Path $scriptRoot 'logs'
}
# Deliberately .NET file APIs, not New-Item/Add-Content: those cmdlets honour
# -WhatIf and would suppress logging during a dry run.
if (-not (Test-Path -LiteralPath $LogPath)) {
    [IO.Directory]::CreateDirectory($LogPath) | Out-Null
}
$script:LogFile = Join-Path $LogPath ('set-feature-override-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

function Write-RunLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    try {
        [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    }
    catch {
        Write-Host ("log write failed: " + $_.Exception.Message) -ForegroundColor Yellow
    }
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Get-Win32Text {
    param([int]$Code)
    switch ($Code) {
        0    { 'success' }
        5    { 'access denied' }
        53   { 'path not found' }
        87   { 'invalid parameter' }
        1300 { 'privilege not held by this token' }
        1314 { 'privilege not enabled' }
        default { "win32 error $Code" }
    }
}

function Get-SidPointer {
    param([Security.Principal.SecurityIdentifier]$Sid)
    $bytes = New-Object byte[] $Sid.BinaryLength
    $Sid.GetBinaryForm($bytes, 0)
    $ptr = [Runtime.InteropServices.Marshal]::AllocHGlobal($Sid.BinaryLength)
    [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $Sid.BinaryLength)
    return $ptr
}

function Get-NativeKeyPath {
    param([string]$RelativePath)
    # RegOpenKeyEx wants a plain subkey path relative to HKLM.
    # A 'MACHINE\' prefix is only valid for SetNamedSecurityInfo-style APIs and
    # makes RegOpenKeyEx fail with ERROR_FILE_NOT_FOUND (2). CurrentControlSet is
    # resolved by the registry itself, so no control-set rewriting is needed.
    return $RelativePath
}

function Open-NativeKey {
    param([string]$NativePath, [int]$Access)
    $handle = [IntPtr]::Zero
    $rc = [CfrNative]::RegOpenKeyEx($HKEY_LOCAL_MACHINE, $NativePath, 0, $Access, [ref]$handle)
    return [pscustomobject]@{ Ok = ($rc -eq 0); Handle = $handle; Code = $rc }
}

function Import-SddlAce {
    param([string]$Sddl)
    if ($Sddl.Contains($AceMarker)) { return $Sddl }
    $daclIndex = $Sddl.IndexOf('D:')
    if ($daclIndex -lt 0) { throw "no DACL present in SDDL: $Sddl" }
    $cursor = $daclIndex + 2
    while ($cursor -lt $Sddl.Length -and $Sddl[$cursor] -ne '(') { $cursor++ }
    return $Sddl.Substring(0, $cursor) + $AceMarker + $Sddl.Substring($cursor)
}

function Remove-SddlAce {
    param([string]$Sddl)
    $idx = $Sddl.IndexOf($AceMarker)
    if ($idx -lt 0) { return $Sddl }
    return $Sddl.Remove($idx, $AceMarker.Length)
}

function Get-RegistryKeyInfo {
    param([string]$RegistryPath)
    $acl = Get-Acl -Path ('Registry::HKEY_LOCAL_MACHINE\' + $RegistryPath)
    return [pscustomobject]@{
        Owner = $acl.Owner
        Sddl  = $acl.Sddl
    }
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
$groupKeyPath  = $BaseKey + '\' + $Group
$featureKeyPath = $groupKeyPath + '\' + ('{0}' -f $FeatureId)
$nativeGroupPath = Get-NativeKeyPath $groupKeyPath
$registryGroupKey = 'Registry::HKEY_LOCAL_MACHINE\' + $groupKeyPath

if ($PSCmdlet.ParameterSetName -ne 'Repair' -and $FeatureId -eq 0) {
    throw 'FeatureId must be greater than zero.'
}

Write-RunLog "start: parameter set = $($PSCmdlet.ParameterSetName), base key = $BaseKey"
Write-RunLog "group key = $groupKeyPath"
Write-RunLog "native path = $nativeGroupPath"

if (-not (Test-Path -LiteralPath $registryGroupKey)) {
    Write-RunLog "group key does not exist; nothing to do" 'ERROR'
    throw "Group key not found: HKLM\$groupKeyPath"
}

$before = Get-RegistryKeyInfo $groupKeyPath
Write-RunLog ("owner before = " + $before.Owner)
Write-RunLog ("dacl before  = " + $before.Sddl)

$ownerMismatch = ($before.Owner -eq $AdminAccount.Value)
if ($ownerMismatch) {
    Write-RunLog "owner is BUILTIN\Administrators - a previous run probably did not finish" 'WARN'
    if (-not $Repair) {
        Write-RunLog "run this script with -Repair to put the key back, then retry" 'WARN'
    }
}

if ($Repair) {
    if (-not (Test-Elevated)) { throw 'Repair needs an elevated PowerShell window.' }
    if (-not $PSCmdlet.ShouldProcess("HKLM\$groupKeyPath", 'Restore owner and remove leftover ACE')) { return }

    Write-RunLog '=== repair: privileges ==='
    foreach ($name in 'SeTakeOwnershipPrivilege', 'SeRestorePrivilege') {
        $rc = [CfrNative]::Enable($name)
        Write-RunLog ("   {0} -> {1}" -f $name, (Get-Win32Text $rc))
        if ($rc -ne 0) { throw "cannot enable $name" }
    }

    Write-RunLog '=== repair: restore owner ==='
    $opened = Open-NativeKey $nativeGroupPath ($READ_CONTROL -bor $WRITE_OWNER)
    if (-not $opened.Ok) { throw ("RegOpenKeyEx failed: " + (Get-Win32Text $opened.Code)) }
    $sidPtr = Get-SidPointer $TiSidValue
    try {
        $rc = [CfrNative]::SetOwner($opened.Handle, $sidPtr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($sidPtr)
        [CfrNative]::RegCloseKey($opened.Handle) | Out-Null
    }
    Write-RunLog ("   SetOwner -> " + (Get-Win32Text $rc))
    if ($rc -ne 0) { throw 'owner restore failed' }

    Write-RunLog '=== repair: drop leftover ACE ==='
    $cleaned = Remove-SddlAce $before.Sddl
    if ($cleaned -ne $before.Sddl) {
        $openedDacl = Open-NativeKey $nativeGroupPath ($READ_CONTROL -bor $WRITE_DAC)
        if (-not $openedDacl.Ok) { throw ("RegOpenKeyEx(WRITE_DAC) failed: " + (Get-Win32Text $openedDacl.Code)) }
        try {
            $rc = [CfrNative]::ApplyDacl($openedDacl.Handle, $cleaned)
        }
        finally {
            [CfrNative]::RegCloseKey($openedDacl.Handle) | Out-Null
        }
        Write-RunLog ("   ApplyDacl -> " + (Get-Win32Text $rc))
        if ($rc -ne 0) { throw 'dacl cleanup failed' }
    }
    else {
        Write-RunLog '   no leftover ACE found'
    }

    $after = Get-RegistryKeyInfo $groupKeyPath
    Write-RunLog ("owner after = " + $after.Owner) 'OK'
    Write-RunLog 'repair finished' 'OK'
    return
}

# ---------------------------------------------------------------------------
# main change
# ---------------------------------------------------------------------------
$targetState = if ($State -eq 'Enabled') { 2 } else { 1 }
$actionText = if ($Remove) {
    "remove override key $featureKeyPath"
}
else {
    "write EnabledState=$targetState ($State) to $featureKeyPath"
}

if (-not $PSCmdlet.ShouldProcess("HKLM\$featureKeyPath", $actionText)) {
    Write-RunLog 'whatif: no changes made' 'WARN'
    return
}

if (-not (Test-Elevated)) { throw 'Changing overrides needs an elevated PowerShell window.' }

$aclState = $null
$writeOk = $false

try {
    Write-RunLog '=== step 1: privileges ==='
    foreach ($name in 'SeTakeOwnershipPrivilege', 'SeRestorePrivilege') {
        $rc = [CfrNative]::Enable($name)
        Write-RunLog ("   {0} -> {1}" -f $name, (Get-Win32Text $rc))
        if ($rc -ne 0) { throw "cannot enable $name; nothing was changed" }
    }

    Write-RunLog '=== step 2: take ownership ==='
    $opened = Open-NativeKey $nativeGroupPath ($READ_CONTROL -bor $WRITE_OWNER)
    if (-not $opened.Ok) { throw ("RegOpenKeyEx(WRITE_OWNER) failed: " + (Get-Win32Text $opened.Code)) }
    $sidPtr = Get-SidPointer $AdminSid
    try {
        $rc = [CfrNative]::SetOwner($opened.Handle, $sidPtr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($sidPtr)
        [CfrNative]::RegCloseKey($opened.Handle) | Out-Null
    }
    if ($rc -ne 0) { throw ("SetOwner failed: " + (Get-Win32Text $rc)) }
    $aclState = $before
    $ownerNow = (Get-RegistryKeyInfo $groupKeyPath).Owner
    Write-RunLog ("   owner now = " + $ownerNow)
    if ($ownerNow -ne $AdminAccount.Value) { throw 'owner change did not take effect; aborting before any write' }

    Write-RunLog '=== step 3: grant DACL ==='
    $openedDacl = Open-NativeKey $nativeGroupPath ($READ_CONTROL -bor $WRITE_DAC)
    if (-not $openedDacl.Ok) { throw ("RegOpenKeyEx(WRITE_DAC) failed: " + (Get-Win32Text $openedDacl.Code)) }
    $grantedSddl = Import-SddlAce $before.Sddl
    try {
        $rc = [CfrNative]::ApplyDacl($openedDacl.Handle, $grantedSddl)
    }
    finally {
        [CfrNative]::RegCloseKey($openedDacl.Handle) | Out-Null
    }
    if ($rc -ne 0) { throw ("SetSecurityInfo(DACL) failed: " + (Get-Win32Text $rc)) }
    Write-RunLog '   dacl updated'

    Write-RunLog '=== step 4: write values ==='
    if ($Remove) {
        $existing = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($featureKeyPath)
        if ($existing) {
            $existing.Close()
            [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($featureKeyPath)
            Write-RunLog ("   removed " + $featureKeyPath) 'OK'
            $gone = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($featureKeyPath)
            if ($null -ne $gone) {
                $gone.Close()
                throw 'verification failed: key still present after delete'
            }
            Write-RunLog '   verify: key is gone'
        }
        else {
            Write-RunLog '   override key not present, nothing to delete' 'WARN'
        }
    }
    else {
        $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($featureKeyPath)
        $key.SetValue('EnabledState', $targetState, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('EnabledStateOptions', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('Variant', $Variant, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('VariantPayload', $VariantPayload, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('VariantPayloadKind', $VariantPayloadKind, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Close()
        Write-RunLog ("   wrote EnabledState={0} Variant={1}" -f $targetState, $Variant) 'OK'

        $verify = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($featureKeyPath)
        if ($null -eq $verify) { throw 'verification failed: key missing after write' }
        $written = $verify.GetValue('EnabledState')
        $verify.Close()
        Write-RunLog ("   verify: EnabledState=" + $written)
        if ($written -ne $targetState) { throw "verification failed: expected $targetState, found $written" }
    }
    $writeOk = $true
}
catch {
    Write-RunLog ("FAILED: " + $_.Exception.Message) 'ERROR'
}
finally {
    Write-RunLog '=== step 5: restore protection ==='
    if ($null -ne $aclState) {
        $openedRestore = Open-NativeKey $nativeGroupPath ($READ_CONTROL -bor $WRITE_DAC)
        if ($openedRestore.Ok) {
            try {
                $rc = [CfrNative]::ApplyDacl($openedRestore.Handle, $aclState.Sddl)
            }
            finally {
                [CfrNative]::RegCloseKey($openedRestore.Handle) | Out-Null
            }
            if ($rc -eq 0) { Write-RunLog '   dacl restored' 'OK' } else { Write-RunLog ("   dacl restore failed: " + (Get-Win32Text $rc)) 'ERROR' }
        }
        else {
            Write-RunLog ("   could not reopen for dacl restore: " + (Get-Win32Text $openedRestore.Code)) 'ERROR'
        }

        $openedOwner = Open-NativeKey $nativeGroupPath ($READ_CONTROL -bor $WRITE_OWNER)
        if ($openedOwner.Ok) {
            $sidPtr = Get-SidPointer $TiSidValue
            try {
                $rc = [CfrNative]::SetOwner($openedOwner.Handle, $sidPtr)
            }
            finally {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($sidPtr)
                [CfrNative]::RegCloseKey($openedOwner.Handle) | Out-Null
            }
            if ($rc -eq 0) { Write-RunLog '   owner restored to TrustedInstaller' 'OK' } else { Write-RunLog ("   owner restore failed: " + (Get-Win32Text $rc)) 'ERROR' }
        }
        else {
            Write-RunLog ("   could not reopen for owner restore: " + (Get-Win32Text $openedOwner.Code)) 'ERROR'
        }
    }

    $after = Get-RegistryKeyInfo $groupKeyPath
    Write-RunLog ("owner after = " + $after.Owner)
    if ($null -ne $aclState) {
        if ($after.Owner -eq $AdminAccount.Value) {
            Write-RunLog 'owner still belongs to BUILTIN\Administrators - run this script with -Repair' 'ERROR'
        }
        else {
            Write-RunLog ('owner returned to ' + $after.Owner) 'OK'
        }
    }
    if ($after.Sddl -ne $before.Sddl) {
        Write-RunLog 'dacl differs from the original - check the key manually' 'WARN'
    }
    else {
        Write-RunLog 'dacl matches the original' 'OK'
    }
}

if ($writeOk) {
    Write-RunLog ''
    Write-RunLog 'finished. Reboot for the shell to re-read feature state.' 'OK'
    exit 0
}
else {
    Write-RunLog ''
    Write-RunLog 'no values were changed; the key was restored.' 'ERROR'
    exit 1
}
