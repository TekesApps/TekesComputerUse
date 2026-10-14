# Host integration

## Choose the correct artifact

| Use | Artifact | TCC identity expectation |
| --- | --- | --- |
| Local source development | `dist/TekesComputerUseHelper` from `Scripts/build-helper.sh` | Ad-hoc signing is expected; previous consent may not carry over. |
| Distribution to a host | `TekesComputerUse-<version>.tekesplugin` from `Scripts/build-plugin.sh` | Use the signed native `.app` contained in the package. |

The installable package contains this signed MCP-server entrypoint:

```text
bin/TekesComputerUseHelper.app/Contents/MacOS/TekesComputerUseHelper
```

When invoked from that bundle, the executable starts a LaunchServices-owned app
instance and bridges its MCP stdin/stdout over a local Unix socket. This keeps
the signed app bundle, rather than an arbitrary parent host process, as the
macOS privacy client.

## Generic MCP configuration

After a host has installed or extracted the reviewed plugin package, configure
the host to run the absolute path to the packaged entrypoint:

```text
command: /absolute/plugin/root/bin/TekesComputerUseHelper.app/Contents/MacOS/TekesComputerUseHelper
arguments: []
transport: stdio
```

The host must preserve stdin, stdout, and the helper's working process for the
life of the MCP session. Do not wrap it in a shell that writes logs to stdout.
The helper only accepts local IPC for its internal bridge; remote MCP transport
is the host's separate responsibility.

Opening `TekesComputerUseHelper.app` in Finder or through LaunchServices starts its menu-bar status
panel. A host that itself uses LaunchServices must pass `--mcp-stdio`; a host that executes the
packaged entrypoint above directly needs no arguments. Each MCP session records only the host name,
tool name, target application identifier, outcome, and time for the local status panel. Tool input,
typed text, screenshots, and accessibility trees are never written to the activity history.

## Host responsibilities

A compatible host must:

1. Display and obtain its own approval before non-read-only tool calls.
2. Treat `request_permissions` as a user-initiated request, not a successful
   grant.
3. Re-read `permission_status` after macOS consent changes before retrying an
   operation.
4. Surface denied or unavailable TCC permissions without auto-retrying them.
5. Keep the installed helper artifact and its signing provenance intact.

The host must not edit the helper, re-sign it ad hoc, or substitute a different
binary at the configured path. Doing so changes its designated requirement and
can invalidate the user's established privacy consent.

## Package build inputs

`Scripts/build-plugin.sh` builds the release executable, creates the `.app`
bundle in a temporary staging directory, signs and verifies it, then creates a
deterministic Kernel format-1 archive with the repository-owned
`Scripts/package-plugin.py`. The source tree is not
used as the signed bundle staging area, which avoids File Provider metadata
invalidating the code signature.

The manifest declares the executable once as `mcp-server`. Its
`native-helper.execute` capability preserves the ordinary strict code-signature
receipt and revalidation path used for any executable component with a stable
macOS privacy identity; hosts must not infer MCP from a `native-helper` type.

Packaging has no dependency on any host checkout or executable. The archive
writer rejects symlinks, special files, oversized entries, oversized expanded
payloads, and excessive entry counts before publishing the output atomically.

The plugin manifest version, `Info.plist` version, package filename, and
release notes must be changed together for every release.

A one-use TCC-denial canary can be built with
`TEKES_COMPUTER_USE_QUALIFICATION_IDENTIFIER` in the reserved
`com.tekes.computer-use.helper.qualification.*` namespace and a distinct
`TEKES_COMPUTER_USE_QUALIFICATION_ARCHIVE` path. This artifact exists only to
prove the real signed helper's denied path without resetting or requesting TCC.
The build refuses to bundle it or overwrite the production archive. It must
never be installed as the product, copied into a runtime manifest, or
published.
