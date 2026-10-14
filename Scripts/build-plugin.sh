#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
production_identifier=com.tekes.computer-use.helper
qualification_identifier=${TEKES_COMPUTER_USE_QUALIFICATION_IDENTIFIER:-}
qualification_archive=${TEKES_COMPUTER_USE_QUALIFICATION_ARCHIVE:-}
version=$(plutil -extract version raw -o - "$plugin_root/Plugin/tekes-plugin.json")
production_archive="$plugin_root/dist/TekesComputerUse-$version.tekesplugin"

if [ -n "$qualification_identifier" ]; then
  case "$qualification_identifier" in
    com.tekes.computer-use.helper.qualification.*) ;;
    *) echo "qualification identifier must use the reserved qualification namespace" >&2; exit 64 ;;
  esac
  if [ -z "$qualification_archive" ] || [ -n "${TEKES_BUNDLED_PLUGIN_DESTINATION:-}" ]; then
    echo "qualification builds require a separate archive and cannot be bundled" >&2
    exit 64
  fi
  case "$qualification_archive" in
    /*) ;;
    *) echo "qualification archive must be an absolute path outside the repository" >&2; exit 64 ;;
  esac
  canonical_qualification_archive=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$qualification_archive")
  canonical_production_archive=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$production_archive")
  case "$canonical_qualification_archive" in
    "$plugin_root"/*) echo "qualification archive must remain outside the repository" >&2; exit 64 ;;
  esac
  if [ "$canonical_qualification_archive" = "$canonical_production_archive" ]; then
    echo "qualification archive must not overwrite the production artifact" >&2
    exit 64
  fi
  bundle_identifier=$qualification_identifier
  archive=$qualification_archive
else
  if [ -n "$qualification_archive" ]; then
    echo "qualification archive requires a qualification identifier" >&2
    exit 64
  fi
  bundle_identifier=$production_identifier
  archive=$production_archive
fi

python3 "$plugin_root/Scripts/check-package-contract.py"
swift build --package-path "$plugin_root" -c release
staging_directory=$(mktemp -d "${TMPDIR:-/tmp}/tekes-computer-use.XXXXXX")
trap 'rm -rf "$staging_directory"' EXIT
staging_root="$staging_directory/Plugin"
mkdir -p "$staging_root"
cp "$plugin_root/Plugin/tekes-plugin.json" "$staging_root/tekes-plugin.json"
cp -R "$plugin_root/Plugin/skills" "$staging_root/skills"
cp -R "$plugin_root/Plugin/assets" "$staging_root/assets"

# Keep the signed .app out of the source tree. This workspace may be backed by File Provider,
# which immediately adds FinderInfo to .app directories and makes codesign reject them.
app_bundle="$staging_root/bin/TekesComputerUseHelper.app"
executable="$app_bundle/Contents/MacOS/TekesComputerUseHelper"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$plugin_root/.build/release/TekesComputerUseHelper" "$executable"
cp "$plugin_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$plugin_root/Plugin/assets/ComputerUseIcon.png" \
  "$app_bundle/Contents/Resources/ComputerUseIcon.png"
cp "$plugin_root/Plugin/assets/ComputerUseStatusIcon.svg" \
  "$app_bundle/Contents/Resources/ComputerUseStatusIcon.svg"

if [ -n "$qualification_identifier" ]; then
  plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$app_bundle/Contents/Info.plist"
fi

# iCloud/Finder metadata invalidates macOS code signatures when the workspace is synced.
xattr -cr "$app_bundle"
# File Provider may restore an empty FinderInfo attribute immediately after recursive clearing.
# codesign rejects it even though it contains no useful metadata, so remove that exact attribute
# once more on the bundle root immediately before signing.
xattr -d com.apple.FinderInfo "$app_bundle" 2>/dev/null || true
signing_identity=${TEKES_COMPUTER_USE_SIGNING_IDENTITY:--}
if [ "$signing_identity" = "-" ]; then
  codesign --force --deep --sign - --identifier "$bundle_identifier" "$app_bundle"
else
  codesign --force --deep --options runtime --timestamp --sign "$signing_identity" \
    --identifier "$bundle_identifier" "$app_bundle"
fi
codesign --verify --deep --strict --verbose=2 "$app_bundle"

mkdir -p "$plugin_root/dist"
python3 "$plugin_root/Scripts/package-plugin.py" "$staging_root" "$archive"
xattr -c "$archive"
if [ -n "${TEKES_BUNDLED_PLUGIN_DESTINATION:-}" ]; then
  mkdir -p "$(dirname "$TEKES_BUNDLED_PLUGIN_DESTINATION")"
  cp "$archive" "$TEKES_BUNDLED_PLUGIN_DESTINATION"
  xattr -c "$TEKES_BUNDLED_PLUGIN_DESTINATION"
  echo "Bundled $TEKES_BUNDLED_PLUGIN_DESTINATION"
fi
echo "Created $archive"
if [ -n "$qualification_identifier" ]; then
  echo "Qualification-only artifact; do not bundle, install as product, or publish"
fi
