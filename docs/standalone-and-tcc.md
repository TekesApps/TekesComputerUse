# Standalone use and macOS permissions

## Purpose

`TekesComputerUseHelper` is a standalone MCP server for macOS computer use. It
does not need the Tekes desktop app to run. A compatible MCP
host launches the helper as a stdio subprocess, sends JSON-RPC requests on
stdin, and reads responses on stdout.

The host's plugin/capability approval and macOS privacy permission are separate
decisions:

```text
Host approves tool use ──► helper is allowed to run
macOS user consent      ──► Accessibility / Screen Recording may be used
```

Neither decision implies the other.

## What each permission enables

| Permission | Used for | Without it |
| --- | --- | --- |
| Accessibility | Reading an app's accessibility tree; clicking, dragging, scrolling, typing, and selecting text. | State-reading and interaction tools report that Accessibility is not granted. |
| Screen Recording | Capturing the selected app window as a visual fallback. | `get_app_state` can still return its Accessibility-based state and reports that a screenshot is unavailable. |
| No macOS permission | Listing regular running applications and reading permission state. | These read-only operations remain available. |

The helper exposes `permission_status` to inspect the current state and
`request_permissions` to ask macOS to show its consent UI. The latter only
requests; it never grants permission itself.

## Connecting an MCP host

Build a release helper first:

```sh
sh Scripts/build-helper.sh
```

Register the resulting absolute executable path in the host's MCP server
configuration. The host-specific configuration format varies, but the process
contract is always equivalent to:

```text
command: /absolute/path/to/TekesComputerUseHelper
arguments: []
transport: stdio
```

Do not send ordinary logging to stdout: stdout is reserved for JSON-RPC.
Diagnostic output belongs on stderr.

## First-use sequence

1. Install a helper whose source revision, SHA-256 digest, and signing identity
   are known to the user or administrator.
2. Add it to a compatible MCP host and approve the host's requested computer-use
   capabilities according to that host's policy.
3. Call `permission_status`.
4. When a required permission is false, call `request_permissions` with only the
   needed permission flags. macOS opens its system consent experience.
5. The user grants or declines consent in macOS System Settings, then the host
   calls `permission_status` again before retrying the blocked operation.

A denial is a normal, durable user choice. Hosts must report it clearly and
must not loop permission prompts or retry input/screen actions without another
explicit user decision.

## Release and upgrade identity

macOS identifies a privacy client through its signed designated requirement.
Local development uses an ad-hoc signature, which is intentionally not a stable
upgrade identity. Distributable builds must use the publisher's stable Apple
signing identity:

```sh
TEKES_COMPUTER_USE_SIGNING_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
  sh Scripts/build-helper.sh
```

Keep the bundle identifier and signing identity stable across releases.
Replacing a release helper with an ad-hoc or differently signed binary can
require the user to grant privacy permissions again. Release artifacts should
be traceable to an exact source revision and SHA-256 digest; notarization is
recommended for external distribution.

## Non-goals and security boundary

TekesComputerUse does not:

- modify the macOS TCC database;
- bypass, pre-approve, or silently reset Accessibility or Screen Recording;
- treat host capability approval as macOS consent;
- capture arbitrary screens when Screen Recording access is unavailable.

Report any suspected permission, input-injection, screen-capture, or signing
identity bypass privately under the repository's [security policy](../SECURITY.md).
