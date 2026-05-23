## [0.1.1] - 2026-05-23 - mcp_bundle 0.4.0 cascade

### Changed (cascade)
- `mcp_bundle` caret bumped from `^0.3.0` to `^0.4.0`. mcp_browser does not touch `UiSection.pages` directly, so this release is a caret-only cascade. Consumers should bump to `^0.1.1`.

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- Direct CDP browser engine and context lifecycle.
- Authenticated-session auth profile store and reuse.
- Structured operations — search, download, extraction templates.
- Pluggable audit subsystem (file / KV sinks, audit trail).
- Policy engine and policy ports.
- Engine / context / auth-profile registries.
- Browser-specific ports composing the 4-Primitive Contract from `mcp_bundle`.
