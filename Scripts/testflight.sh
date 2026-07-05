#!/bin/bash
# Build, sign (Apple Distribution) and upload an iOS build of TriGenius to
# TestFlight / App Store Connect. Bumps only the build number — MARKETING_VERSION
# is owned by release.sh (macOS). No git commit/tag, no GitHub release.
#
# Usage: Scripts/testflight.sh
#
# One-time setup (not done by this script):
#   1. Create the app record in App Store Connect (bundle id net.Narica.TriGenius).
#   2. App Store Connect API key (.p8, role App Manager). Point the script at it via
#      Scripts/testflight.env (gitignored), which is sourced if present:
#        export ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
#        export ASC_KEY_ID=XXXXXXXXXX
#        export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Optional local, gitignored credential file.
[[ -f "$REPO_ROOT/Scripts/testflight.env" ]] && source "$REPO_ROOT/Scripts/testflight.env"

: "${ASC_KEY_PATH:?set ASC_KEY_PATH to your App Store Connect API .p8 (see Scripts/testflight.env)}"
: "${ASC_KEY_ID:?set ASC_KEY_ID to the API key id}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID to the API key issuer id}"
# xcodebuild's -authenticationKeyPath rejects relative paths, so canonicalize to
# absolute (expanding a leading ~) before the existence check.
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"
if [[ ! -f "$ASC_KEY_PATH" ]]; then
	echo "error: ASC_KEY_PATH does not point to a file: $ASC_KEY_PATH" >&2
	exit 1
fi
ASC_KEY_PATH="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"

PROJECT="TriGenius.xcodeproj"
SCHEME="TriGenius"

# Apple Distribution is what App Store / TestFlight builds are signed with; automatic
# signing (-allowProvisioningUpdates) creates it and the App Store profiles on demand.
IDENTITIES="$(security find-identity -v -p codesigning | grep '"Apple Distribution:' || true)"
if [[ -z "$IDENTITIES" ]]; then
	echo "warning: no 'Apple Distribution' identity found in the keychain — automatic" >&2
	echo "         signing will attempt to create one (needs Xcode signed into the team)." >&2
fi

CURRENT_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | sed -E 's/[^0-9]*([0-9]+);.*/\1/')"
NEXT_BUILD=$((CURRENT_BUILD + 1))
echo "Bumping CURRENT_PROJECT_VERSION $CURRENT_BUILD -> $NEXT_BUILD"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PROJECT/project.pbxproj"

WORK_DIR="$(mktemp -d)"
echo "Using temporary work dir: $WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/TriGenius.xcarchive"
EXPORT_PATH="$WORK_DIR/export"

echo "Archiving (iOS)..."
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$ARCHIVE_PATH" \
	-allowProvisioningUpdates \
	CODE_SIGN_ENTITLEMENTS=TriGenius/TriGenius-Release.entitlements

echo "Exporting signed .ipa..."
# Sign+upload are decoupled on purpose: an API key on -exportArchive forces
# cloud-managed distribution signing (which this team isn't granted), so the export
# runs key-less — automatic signing picks the local Apple Distribution cert and
# -allowProvisioningUpdates creates the App Store profiles via the Xcode Apple ID —
# and the API key is used only for the upload below.
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE_PATH" \
	-exportPath "$EXPORT_PATH" \
	-exportOptionsPlist Scripts/ExportOptions-AppStore.plist \
	-allowProvisioningUpdates

IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' -print -quit)"
if [[ -z "$IPA_PATH" ]]; then
	echo "error: no .ipa produced in $EXPORT_PATH" >&2
	exit 1
fi

echo "Uploading $IPA_PATH to App Store Connect..."
# altool discovers the key as AuthKey_<id>.p8 under $API_PRIVATE_KEYS_DIR, so stage a
# correctly-named copy regardless of what the .p8 is called on disk.
KEYS_DIR="$WORK_DIR/private_keys"
mkdir -p "$KEYS_DIR"
cp "$ASC_KEY_PATH" "$KEYS_DIR/AuthKey_${ASC_KEY_ID}.p8"
API_PRIVATE_KEYS_DIR="$KEYS_DIR" xcrun altool --upload-app \
	-f "$IPA_PATH" -t ios \
	--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "Done: build $NEXT_BUILD uploaded. It appears in TestFlight after a few minutes"
echo "of App Store Connect processing, then assign it to your testers."
