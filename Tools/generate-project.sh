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

# XcodeGen (2.46.0) writes the StoreKit configuration path relative to the
# .xcodeproj, but Xcode resolves it from the .xcscheme file, which sits two
# directories deeper. Left alone the setting shows red in the scheme editor and
# an Xcode-launched run silently talks to the real App Store instead of
# Support/Smaller.storekit — the paywall then has no price and StoreKit reports
# "No active account".
#
# The file also has to be a member of the project or Xcode cannot resolve the
# reference at all; that half is handled in project.yml, which adds it with
# buildPhase: none so a test-only file never reaches the shipped bundle.
SCHEME="$ROOT/Smaller.xcodeproj/xcshareddata/xcschemes/Smaller.xcscheme"
WANT='identifier = "../../../Support/Smaller.storekit"'
if [ -f "$SCHEME" ]; then
  sed -i '' \
    's|identifier = "\.\./\.\./Support/Smaller\.storekit"|identifier = "../../../Support/Smaller.storekit"|' \
    "$SCHEME"
  if ! grep -qF "$WANT" "$SCHEME"; then
    echo
    echo "warning: could not set the StoreKit configuration path in the scheme."
    echo "         Check Product > Scheme > Edit Scheme > Run > Options — if"
    echo "         StoreKit Configuration is red or None, pick Smaller.storekit."
  fi
fi

echo
echo "Generated Smaller.xcodeproj"
echo "  bundle prefix: $BUNDLE_PREFIX"
echo "  app group:     $APP_GROUP"
