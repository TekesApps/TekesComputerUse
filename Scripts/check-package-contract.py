#!/usr/bin/env python3
"""Fail closed when the distributable plugin/MCP declaration drifts."""

import json
import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "Plugin" / "tekes-plugin.json"
INFO = ROOT / "Resources" / "Info.plist"
EXECUTABLE = "bin/TekesComputerUseHelper.app/Contents/MacOS/TekesComputerUseHelper"
CAPABILITIES = {
    "accessibility.control",
    "native-helper.execute",
    "screen.capture",
}


def main() -> None:
    manifest = json.loads(MANIFEST.read_bytes())
    with INFO.open("rb") as stream:
        info = plistlib.load(stream)
    matching = [
        component
        for component in manifest.get("components", [])
        if component.get("path") == EXECUTABLE
    ]
    if len(matching) != 1:
        raise SystemExit("package must declare the signed executable exactly once")
    component = matching[0]
    if component.get("id") != "computer-use" or component.get("type") != "mcp-server":
        raise SystemExit("signed executable must be the generic computer-use mcp-server")
    if set(component.get("capabilities", [])) != CAPABILITIES:
        raise SystemExit("generic MCP executable capability set drift")
    declared = {capability.get("id") for capability in manifest.get("capabilities", [])}
    if declared != CAPABILITIES:
        raise SystemExit("package capability declarations drift")
    version = manifest.get("version")
    if version != "0.1.8" or info.get("CFBundleShortVersionString") != version:
        raise SystemExit("manifest and signed app versions must both be 0.1.8")
    print(f"package contract: {version}, one signed generic mcp-server executable")


if __name__ == "__main__":
    main()
