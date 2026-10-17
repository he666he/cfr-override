# cfr-override

Read and write Windows **CFR** (Controlled Feature Rollout) feature overrides from
plain PowerShell, with **no third-party binary** involved.

Windows stores feature flags here:

```
HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\<group>\<featureId>
```

That tree is owned by `NT SERVICE\TrustedInstaller` and `BUILTIN\Administrators` only
holds `ReadKey`, so an elevated administrator cannot write to it directly. This repo
does what tools like ViVeTool do internally, in auditable PowerShell:

1. enable `SeTakeOwnershipPrivilege` and `SeRestorePrivilege`
2. take ownership of the group key (owner field only)
3. add one allow ACE for `BUILTIN\Administrators` to the DACL
4. write the feature values
5. put the original DACL back and return ownership to TrustedInstaller

Step 5 always happens, including on failure. The original security descriptor is
captured before anything is touched and compared again at the end.

## What this is not

* It is **not** a database of feature ids. Ids change between Windows builds and
  some features stop being flag-controlled at all. You supply the id.
* It is **not** an "undo Windows feature X" button. Writing a flag that the shell
  no longer reads has no visible effect. See
  [docs/case-study-start-menu.md](docs/case-study-start-menu.md) for a worked
  example of exactly that happening.

## Why not just ViVeTool

ViVeTool is excellent and does more than this repo. Use it if you can.

This exists for environments where downloading and running an unsigned binary is
not allowed: locked-down corporate images, air-gapped machines, or anyone who wants
to read every line of what is about to touch a TrustedInstaller-owned key before it
runs. Two readable `.ps1` files, nothing compiled.

## Requirements

* Windows 10/11, Windows PowerShell 5.1 or PowerShell 7+
* Elevation for `Set-FeatureOverride.ps1` (any real change)
* No elevation needed for `Get-FeatureOverrides.ps1` or for `-WhatIf`

## Quick start

```powershell
# 1. See what feature state changed recently (read-only, no elevation)
.\Get-FeatureOverrides.ps1 -Recent 7 | Format-Table Group, FeatureId, Meaning, LastWriteTime

# 2. Dry run: shows what would happen, changes nothing
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled -WhatIf

# 3. Apply it (elevated window), then reboot
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled

# 4. Undo: delete the override, back to default rollout
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove

# 5. If a previous run was interrupted and the key is left owned by Administrators
.\Set-FeatureOverride.ps1 -Repair
```

Parameter sets:

| Set | Switches | Effect |
|---|---|---|
| `Set` (default) | `-FeatureId`, `-State Enabled\|Disabled`, optional `-Group`, `-Variant*` | write the override |
| `Remove` | `-FeatureId -Remove` | delete the override key |
| `Repair` | `-Repair` | restore owner and remove a leftover ACE only |

Every run writes a log to `.\logs\set-feature-override-<timestamp>.log`.

`Set-FeatureOverride.ps1` declares `ConfirmImpact = 'High'`, so a real change asks
for confirmation. In scripts or unattended runs add `-Confirm:$false`:

```powershell
.\Set-FeatureOverride.ps1 -FeatureId 12345678 -State Disabled -Confirm:$false
```

## For first-time users

Nothing to install. PowerShell ships with Windows.

1. **Download.** Press **Code - Download ZIP** on this page, then extract it to a
   permanent folder such as `C:\Tools\cfr-override`. Do not run it from inside the
   ZIP, and do not leave it in `Downloads`.
2. **Unblock the files.** Windows tags anything that came from the internet, and a
   blocked script fails to run with a confusing error. Either right-click the ZIP,
   choose Properties, tick **Unblock** *before* extracting, or after extracting run:
   ```powershell
   Get-ChildItem -Path C:\Tools\cfr-override -Recurse | Unblock-File
   ```
3. **Open PowerShell.** Press `Win`, type `powershell`, press Enter. For anything
   that *writes* (`-State`, `-Remove`, `-Repair`) right-click it first and choose
   **Run as administrator**.
4. **Allow scripts for this window only**, if you see "running scripts is disabled
   on this system":
   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass
   ```
   `-Scope Process` means it applies to that one window and is gone when you close
   it. Do not change the machine-wide policy just for this.
5. **Look before you touch anything.**
   ```powershell
   cd C:\Tools\cfr-override
   .\Get-FeatureOverrides.ps1 -Recent 7
   ```
6. **Dry run, then apply.**
   ```powershell
   .\Set-FeatureOverride.ps1 -FeatureId <id> -State Disabled -WhatIf
   .\Set-FeatureOverride.ps1 -FeatureId <id> -State Disabled
   ```
7. **Reboot**, then check the result. Undo at any time with `-Remove`.

This repository contains **no list of feature ids**. It sets a value for an id you
already have. If you do not know which id you need, this tool cannot guess it for
you - read [the case study](docs/case-study-start-menu.md) to see why.

## Safety model

* **Backup before change**: the group key's SDDL is read first and written back at
  the end; the script reports whether the restored DACL matches the original.
* **Verify, do not assume**: after taking ownership it reads the owner back and
  aborts before writing anything if the change did not take effect.
* **Rollback on error**: owner and DACL are restored in a `finally` block, so a
  failed write still leaves the key protected.
* **Dry run by default is available**: `-WhatIf` goes through every read, prints the
  planned action, and exits without touching the key.
* **Idempotent ACE**: the marker ACE is only inserted when absent.
* **Leftover detection**: if the key is already owned by Administrators, the script
  warns that a previous run did not finish and points at `-Repair`.

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `SetOwner failed: access denied` | the token does not hold `SeTakeOwnershipPrivilege`; check `whoami /priv` in the elevated window |
| `privilege not held by this token (1300)` | same as above; usually means the "elevated" window is not really elevated |
| `RegOpenKeyEx(WRITE_DAC) failed` | ownership was taken but `WRITE_DAC` was not granted; run `-Repair` |
| `dacl differs from the original` | another process changed the ACL during the run; inspect the key with `regedit` |
| Write succeeded, UI did not change | wrong feature id, or the feature is not flag-controlled on this build |

## Verification

Checked on Windows 11 25H2, build `26200.8457` - the machine the case study came from:

| Check | Result |
|---|---|
| parser on both scripts | OK |
| ASCII-only source (safe for Windows PowerShell 5.1) | OK, 0 non-ASCII characters |
| `Get-FeatureOverrides.ps1` against a live system | OK, real timestamps in every group |
| `-WhatIf` | OK, no change and no side effects |
| end-to-end privileged path | OK: privileges enabled, ownership taken, DACL granted, key deleted, DACL restored, owner returned to TrustedInstaller, restored DACL compared equal to the original |
| error path (missing root key) | OK, fails with a clear message |

The parser check used for every revision:

```powershell
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\Set-FeatureOverride.ps1), [ref]$null, [ref]$errors)
```

### One invocation gotcha

`-Confirm:$false` only behaves as a switch when the script is called **directly**
from a PowerShell session. If you wrap it in `powershell -File ...`, the outer shell
expands `$false` to the string `False` and parameter binding fails. Either call the
script directly:

```powershell
& .\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove -Confirm:$false
```

or let it prompt:

```powershell
powershell -ExecutionPolicy Bypass -File .\Set-FeatureOverride.ps1 -FeatureId 12345678 -Remove
```

## License

MIT. See [LICENSE](LICENSE).

This tool temporarily changes the ownership and ACL of a protected registry key.
That is a privileged operation with real risk if interrupted. Test on a virtual
machine first. The authors are not responsible for damage to your system.
