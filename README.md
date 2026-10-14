# TekesComputerUse

TekesComputerUse is a standalone macOS MCP server (stdio transport) for computer
use: it lets an MCP host list applications, read their accessibility trees,
capture window screenshots, and drive the mouse and keyboard. Tekes is one host
that uses it, but any MCP host that can launch a stdio server works.

> TekesComputerUse is an independent project by TekesApps and is not affiliated
> with or endorsed by Anthropic or Apple.

## Requirements

- macOS 15 or later (Apple silicon is what the packaged plugin targets)
- Xcode with Swift 6.1 or later (`Package.swift` uses tools-version 6.1)

## Quick start

```sh
git clone https://github.com/TekesApps/TekesComputerUse.git
cd TekesComputerUse
sh Scripts/build-helper.sh
```

The script builds a release executable, signs it ad hoc (or with
`TEKES_COMPUTER_USE_SIGNING_IDENTITY`, see below), verifies the signature, and
writes it to `dist/TekesComputerUseHelper`.

Register that executable with your MCP host as a stdio server, using its
absolute path and no arguments:

```json
{
  "mcpServers": {
    "tekes-computer-use": {
      "command": "/absolute/path/to/TekesComputerUse/dist/TekesComputerUseHelper",
      "args": []
    }
  }
}
```

With the Claude Code CLI:

```sh
claude mcp add tekes-computer-use -- /absolute/path/to/TekesComputerUse/dist/TekesComputerUseHelper
```

Pass `--mcp-stdio` only if your host launches the helper through LaunchServices
(for example by opening the `.app` bundle) rather than executing the binary
directly; the flag keeps the menu-bar status panel from starting in that case.
A host that executes the binary directly needs no arguments. Stdout is reserved
for JSON-RPC; diagnostics go to stderr.

## Permissions

The helper needs two macOS privacy permissions, which the user grants in
System Settings > Privacy & Security:

| Permission | Used for |
| --- | --- |
| Accessibility | Reading accessibility trees; clicking, dragging, scrolling, typing. |
| Screen Recording | Capturing the selected app window as a visual fallback. |

Call the `permission_status` tool to see the current state, and
`request_permissions` to ask macOS to show its consent UI. Requesting never
grants anything by itself, and the helper never modifies the TCC database.

macOS ties these grants to the helper's code signature. Ad-hoc-signed rebuilds
change the code directory hash (cdhash), so after rebuilding you may need to
grant the permissions again. To get a stable identity across builds, sign with
your own Developer ID:

```sh
TEKES_COMPUTER_USE_SIGNING_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
  sh Scripts/build-helper.sh
```

## Development

```sh
swift build
swift test
python3 Scripts/test-package-plugin.py
python3 Scripts/check-package-contract.py
```

`Scripts/build-plugin.sh` produces the signed `.tekesplugin` package used by
Tekes-style hosts (see [docs/host-integration.md](docs/host-integration.md)).

`Package.swift` uses `unsafeFlags` to embed `Resources/Info.plist` in the
executable, so this package cannot be consumed as a SwiftPM dependency. Build
the helper from a checkout instead.

## Documentation

- [Standalone use and macOS permissions](docs/standalone-and-tcc.md)
- [Host integration and packaging](docs/host-integration.md)
- [Contributing](CONTRIBUTING.md), [Security policy](SECURITY.md),
  [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
