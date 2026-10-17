# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-10-18

### Fixed

- `Set-FeatureOverride.ps1` resolved `-LogPath` from `$PSScriptRoot` inside a
  parameter default. `$PSScriptRoot` is empty while parameter defaults are evaluated
  when the script is started with `powershell -File`, so every `-File` invocation
  failed before doing anything. The path is now resolved in the script body. This is
  the invocation form the README recommends for first-time users, so it mattered.

### Added

- `docs/case-study-start-menu.zh-CN.md` - Chinese translation of the case study.
- Case study outcome: on Windows 11 25H2 build `26200.8457`, group 4 feature id
  `3036241548` switches between the new and classic Start menu. `47205210`, which is
  what the guides quote, does nothing on that build.

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
