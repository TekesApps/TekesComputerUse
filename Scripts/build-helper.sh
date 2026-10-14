#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
configuration=${1:-release}

swift build --package-path "$repo_root" -c "$configuration"
source="$repo_root/.build/$configuration/TekesComputerUseHelper"
destination="$repo_root/dist/TekesComputerUseHelper"
mkdir -p "$repo_root/dist"
cp "$source" "$destination"
xattr -c "$destination"

signing_identity=${TEKES_COMPUTER_USE_SIGNING_IDENTITY:--}
if [ "$signing_identity" = "-" ]; then
  codesign --force --sign - --identifier com.tekes.computer-use.helper "$destination"
else
  codesign --force --options runtime --timestamp --sign "$signing_identity" \
    --identifier com.tekes.computer-use.helper "$destination"
fi
codesign --verify --strict --verbose=2 "$destination"
shasum -a 256 "$destination"
