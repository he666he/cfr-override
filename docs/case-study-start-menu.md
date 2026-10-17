# Case study: the Start menu that would not go back

English | [简体中文](case-study-start-menu.zh-CN.md)

This is the investigation that produced this tool. It is worth publishing because
the negative result is more useful than the code: **writing a feature override can
succeed and still change nothing.**

## The symptom

Windows 11 25H2, build `26200.8457`. Windows Update was paused until 2126, no
cumulative update had been installed since `2026-08-05`, yet the Start menu switched
from the classic design to the new one between one boot and the next.

Everything below was measured on that machine.

## What was ruled out

| Hypothesis | Evidence against it |
|---|---|
| An update was installed | `Get-HotFix` newest entry `KB5089549` dated 2026-08-05; `Get-WindowsPackage` showed zero packages installed in the previous 7 days |
| A shell package was updated | `StartMenuExperienceHost` 10.0.26100.4768, install folder timestamp `2026-08-05 22:42` |
| The update could simply be uninstalled | `DISM /Online /Remove-Package` returned `0x800f0825` (`CBS_E_CANNOT_UNINSTALL`): the LCU is a baseline for the 25H2 enablement package and is marked permanent |
| A feature flag was flipped recently | First pass said no: every key under `Overrides\0` carries a last-write time of `2026-08-05 22:42`. That was an incomplete measurement - see below |

That last row is where the first version of this document was wrong, and it is worth
keeping as a lesson: **the override store is not one bucket.** `Overrides` contains
several priority groups, and only one of them was checked at first.

Checking all groups changed the picture completely:

```
10-17 14:21   38 overrides written   <- the machine's first boot of the day
10-17 14:23    6 overrides written
10-16 19:18   11 overrides written
```

So feature state **is** being written on this machine, in bulk, at boot time, in the
group-4 bucket - even with Windows Update paused. The group-0 snapshot from August
was simply a different bucket that never changes.

Practical consequence: when investigating "the UI changed by itself", query every
group, not just group 0. `Get-FeatureOverrides.ps1 -Recent 7` does this by default.

Note: the .NET registry API cannot report a key's last-write time (`Get-Item`
returns an empty value). The timestamps above come from `RegQueryInfoKey`, which is
why `Get-FeatureOverrides.ps1` exposes that field.

## The attempt

The community id for the merged Pinned/Recommended Start menu is `47205210`. Writing
it as `EnabledState=1` succeeded:

```
step 2: become owner      -> owner is now: BUILTIN\Administrators
step 3: grant DACL        -> DACL updated
step 4: write values      -> 47205210 -> EnabledState=1 (off)
step 5: restore protection-> DACL restore: success, owner restore: success
```

After a reboot the Start menu was unchanged.

## What that means

The first guess was simply the wrong id for this build. `47205210` belongs to the
build-7019 era; this machine runs `.8457`.

## Resolution

A targeted bisect found the real one.

Start from `Get-FeatureOverrides.ps1 -Recent 3`: 186 overrides had been written in
the previous three days, and the largest single burst was 38 overrides in group 4,
all in the same minute - the machine's first boot of the day.

Filtering those to `EnabledState = 2` left 33 candidates. Disabling all 33 restored
the classic Start menu, which proved the flag was in that set. Then bisect by
halves, one reboot per round:

```
33 -> 16 -> 8 -> 4 -> 2 -> 1
```

Result, on Windows 11 25H2 build `26200.8457`:

| | |
|---|---|
| group | `4` |
| feature id | **`3036241548`** |
| `EnabledState = 2` | new Start menu |
| `EnabledState = 1` | classic Start menu |
| original `EnabledStateOptions` | `1` (the tool writes `0`; no observed difference) |
| original `Variant` | `0` |

```powershell
# classic Start menu
.\Set-FeatureOverride.ps1 -FeatureId 3036241548 -Group 4 -State Disabled
# back to the new menu
.\Set-FeatureOverride.ps1 -FeatureId 3036241548 -Group 4 -State Enabled
```

Reboot after either. This id is good for `26200.8457` only - do not assume it
carries to another build.

## Transferable lessons

* A feature id is worth nothing without the build number. Always record both.
* CFR state and CFR code live in different places. Uninstalling an update can revert
  the code and leave the state behind, which is why a UI "comes back".
* `0x800f0825` on an LCU means it is a baseline package. No amount of DISM coaxing
  will remove it.
* Pausing Windows Update does not stop Defender definition updates or Store app
  updates. Both arrive through the same client.
* When a UI changes "by itself", sort overrides by last-write time across **all**
  groups and look for a burst at a boot. That burst is the candidate set.
* Bisecting 33 features costs six reboots and is far cheaper than guessing ids.
