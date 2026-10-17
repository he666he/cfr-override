<#
.SYNOPSIS
    List Windows feature overrides (CFR) together with their real last-write time.

.DESCRIPTION
    Reads HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides and
    reports every override it can open, per group.

    The last-write timestamp comes from RegQueryInfoKey because the .NET registry
    API exposes no usable timestamp for keys (Get-Item returns an empty value).
    That timestamp is the only way to see *when* a feature state was last set,
    which is usually the first thing you want when the UI changed "by itself".

    This script is read-only and normally works without elevation.

.PARAMETER Group
    Restrict to these override groups. Default: every group found.

.PARAMETER FeatureId
    Restrict to these feature ids.

.PARAMETER Recent
    Only show overrides written within this many days.

.PARAMETER BaseKey
    Registry path without the hive, relative to HKLM.

.PARAMETER AsJson
    Emit JSON instead of objects.

.EXAMPLE
    .\Get-FeatureOverrides.ps1 -Recent 7

    What changed in the last week?

.EXAMPLE
    .\Get-FeatureOverrides.ps1 -Group 0 -FeatureId 12345678

    Look at one specific override.

.EXAMPLE
    .\Get-FeatureOverrides.ps1 -Group 0 | Where-Object EnabledState -eq 2 |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20

    The twenty most recently enabled machine-wide features.
#>

[CmdletBinding()]
param(
    [int[]]$Group,

    # feature ids are unsigned 32-bit and routinely exceed Int32.MaxValue
    [uint32[]]$FeatureId,

    [ValidateRange(1, 36500)]
    [int]$Recent,

    [ValidateNotNullOrEmpty()]
    [string]$BaseKey = 'SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides',

    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not ('CfrQueryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class CfrQueryNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct FILETIME { public uint dwLowDateTime; public uint dwHighDateTime; }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RegOpenKeyEx(IntPtr hKey, string subKey, uint options, int samDesired,
        out IntPtr phkResult);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegQueryInfoKey(IntPtr hKey, IntPtr className, IntPtr classLen,
        IntPtr reserved, out uint subKeys, out uint maxSubKeyLen, out uint maxClassLen,
        out uint values, out uint maxValueNameLen, out uint maxValueLen, out uint securityDescriptor,
        out FILETIME lastWriteTime);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int RegCloseKey(IntPtr hKey);

    // Returns the key's last-write time as a FILETIME tick count, or 0 on failure.
    public static long LastWriteTicks(IntPtr hKey) {
        uint a, b, c, d, e, f, g;
        FILETIME ft;
        int rc = RegQueryInfoKey(hKey, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
            out a, out b, out c, out d, out e, out f, out g, out ft);
        if (rc != 0) return 0;
        return ((long)ft.dwHighDateTime << 32) | (long)ft.dwLowDateTime;
    }
}
'@
}

$HKEY_LOCAL_MACHINE = [IntPtr]::new([int64]0x80000002)
$KEY_READ = 0x20019

function Get-KeyLastWriteTime {
    param([string]$NativePath)
    $handle = [IntPtr]::Zero
    $rc = [CfrQueryNative]::RegOpenKeyEx($HKEY_LOCAL_MACHINE, $NativePath, 0, $KEY_READ, [ref]$handle)
    if ($rc -ne 0) { return $null }
    try {
        $ticks = [CfrQueryNative]::LastWriteTicks($handle)
        if ($ticks -le 0) { return $null }
        return [datetime]::FromFileTime($ticks)
    }
    finally {
        [CfrQueryNative]::RegCloseKey($handle) | Out-Null
    }
}

function Get-NativeRoot {
    # RegOpenKeyEx takes a plain subkey path relative to HKLM.
    # Do NOT prefix it with MACHINE\: that form is only for the security APIs
    # (SetNamedSecurityInfo) and RegOpenKeyEx returns ERROR_FILE_NOT_FOUND for it.
    return $BaseKey
}

$registryRoot = 'Registry::HKEY_LOCAL_MACHINE\' + $BaseKey
if (-not (Test-Path -LiteralPath $registryRoot)) {
    throw "override root not found: HKLM\$BaseKey"
}

$root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($BaseKey)
if ($null -eq $root) { throw "cannot open HKLM\$BaseKey" }
$groups = @($root.GetSubKeyNames() | Sort-Object { [int]$_ })
$root.Close()

if ($Group) { $groups = @($groups | Where-Object { $Group -contains [int]$_ }) }

$nativeRoot = Get-NativeRoot
$cutoff = $null
if ($Recent) { $cutoff = (Get-Date).AddDays(-1 * $Recent) }

$results = New-Object System.Collections.Generic.List[object]

foreach ($g in $groups) {
    $groupPath = $BaseKey + '\' + $g
    $groupNative = $nativeRoot + '\' + $g
    $groupKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($groupPath)
    if ($null -eq $groupKey) { continue }

    $ids = @($groupKey.GetSubKeyNames())
    $groupKey.Close()

    foreach ($id in $ids) {
        if ($FeatureId -and -not ($FeatureId -contains [uint32]$id)) { continue }

        $featurePath = $groupPath + '\' + $id
        $featureKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($featurePath)
        if ($null -eq $featureKey) { continue }

        $enabledState = $featureKey.GetValue('EnabledState')
        $enabledOptions = $featureKey.GetValue('EnabledStateOptions')
        $variant = $featureKey.GetValue('Variant')
        $payload = $featureKey.GetValue('VariantPayload')
        $payloadKind = $featureKey.GetValue('VariantPayloadKind')
        $featureKey.Close()

        $lastWrite = Get-KeyLastWriteTime ($groupNative + '\' + $id)
        if ($cutoff -and ($null -eq $lastWrite -or $lastWrite -lt $cutoff)) { continue }

        $meaning = switch ($enabledState) {
            1 { 'Disabled' }
            2 { 'Enabled' }
            default { 'Unknown' }
        }

        $results.Add([pscustomobject]@{
            Group                = [int]$g
            FeatureId            = [uint32]$id
            EnabledState         = $enabledState
            Meaning              = $meaning
            EnabledStateOptions  = $enabledOptions
            Variant              = $variant
            VariantPayload       = $payload
            VariantPayloadKind   = $payloadKind
            LastWriteTime        = $lastWrite
        })
    }
}

$ordered = @($results | Sort-Object LastWriteTime -Descending)

if ($AsJson) {
    $ordered | ConvertTo-Json -Depth 3
}
else {
    $ordered
}
