# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-18

First public release.

### Added

- `Set-FeatureOverride.ps1` - write, remove or repair a CFR feature override on a
  TrustedInstaller-owned registry key, using only documented Win32 APIs.
  - parameter sets `Set`, `Remove`, `Repair`
  - `-WhatIf` support through `SupportsShouldProcess`
  - saved-and-restored security descriptor, verified at the end of the run
  - owner verification after the ownership change, before any value is written
  - rollback of owner and DACL in `finally`
  - per-run log file under `.\logs`
- `Get-FeatureOverrides.ps1` - list overrides per group, including the key's real
  last-write time read through `RegQueryInfoKey` (the .NET registry API cannot
  report it). Read-only, no elevation required.
- `docs/case-study-start-menu.md` - a documented negative result: a successfully
  written override that changed nothing, and how the surrounding evidence was
  collected.

### Notes

- Feature ids are not shipped on purpose. They change between builds; see the case
  study for why maintaining a guess list here would be misleading.
