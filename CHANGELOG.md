# Changelog

All notable changes to TekesComputerUse are recorded here. A version is a
release only after its signed `.tekesplugin` artifact has been built and
published; source changes under **Unreleased** are not a distribution promise.

## Unreleased

## 0.1.8 - 2026-10-15

First public release. Versions 0.1.0 through 0.1.7 were internal pre-releases.

- Standalone macOS MCP server (stdio) with tools for application discovery,
  accessibility-tree reads, mouse/keyboard interaction, text operations, and
  explicit `permission_status` / `request_permissions` flows.
- Installable Tekes plugin package declaring the signed MCP executable as a
  standard `mcp-server` component, with capability-based strict signature and
  TCC identity validation; every tool input schema is closed to undeclared
  arguments. The plugin display name is now "Tekes Computer Use".
- Native helper packaged as a signed `TekesComputerUseHelper.app` rather than a
  bare executable, preserving a stable macOS privacy-client boundary; MCP stdio
  is bridged through the LaunchServices-owned process when launched from the
  bundle.
- Menu-bar status panel for permissions, active MCP connections, recent
  privacy-safe activity, and copyable diagnostics.
- Package build uses a temporary staging directory so File Provider metadata in
  a synced checkout cannot invalidate the signed bundle.
- Modern MCP discovery/result compatibility alongside the legacy initialization
  path.
- Explicitly isolated, non-publishable signing-identity seam for a TCC-denial
  canary; production package identity is unchanged.
- Public release preparation: rewritten README for standalone use, security
  reporting channel and supported-versions policy, code of conduct, issue and
  pull request templates, CI with least-privilege permissions, a toolchain
  check and a pinned `actions/checkout`, and removal of internal-only
  references from docs.
