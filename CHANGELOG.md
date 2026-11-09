# Changelog

## Unreleased

### Added
- Native Feedback menu opens a draft in the default mail app.
- Contribution, privacy, support and release documentation.
- Source-control exclusions for personal data, secrets and build products.
- CI checks for native logic, the web API and storage.
- Synthetic-data persistence regressions, including concurrent processes.

### Fixed
- Native edits no longer replace invalid JSON state or its backup.
- Native and web transactions share a process lock and reload before editing.
- Unrelated edits from other current app instances are retained.
- Native storage errors are visible; title, note and deadline editors stay open
  when their save fails.
- Removed machine-specific browser test paths and documented dependencies.

### Status
This source preview has no packaged public release. License selection,
Developer ID signing and notarization remain release decisions.
