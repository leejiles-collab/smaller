#!/bin/bash
#
# Generates Smaller.xcodeproj from project.yml.
#
# The bundle identifier prefix has exactly one home: BundleConfig.swift. This
# script reads it from there and feeds it to XcodeGen and the entitlements, so
# changing it in that one file is genuinely enough.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed."
  echo
  echo "  brew install xcodegen"
  echo
  echo "Then run this script again. (SmallerKit and smallercli build with"
  echo "swift build and do not need the Xcode project.)"
  exit 1
fi

CONFIG="$ROOT/SmallerKit/Sources/SmallerKit/Models/BundleConfig.swift"
BUNDLE_PREFIX="$(sed -n 's/.*static let prefix = "\(.*\)".*/\1/p' "$CONFIG")"

if [ -z "$BUNDLE_PREFIX" ]; then
  echo "error: could not read the prefix out of $CONFIG"
  exit 1
fi

if [[ "$BUNDLE_PREFIX" == *PLACEHOLDER* ]]; then
  echo "note: bundle prefix is still '$BUNDLE_PREFIX'."
  echo "      Edit BundleConfig.swift before you try to run on a device."
fi

export BUNDLE_PREFIX
APP_GROUP="group.${BUNDLE_PREFIX}.smaller"

write_entitlements() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${APP_GROUP}</string>
	</array>
</dict>
</plist>
PLIST
}

mkdir -p "$ROOT/Support"
write_entitlements "$ROOT/Support/Smaller.entitlements"
write_entitlements "$ROOT/Support/SmallerShare.entitlements"

xcodegen generate --spec "$ROOT/project.yml"

echo
echo "Generated Smaller.xcodeproj"
echo "  bundle prefix: $BUNDLE_PREFIX"
echo "  app group:     $APP_GROUP"
