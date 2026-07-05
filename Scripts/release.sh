#!/bin/bash
# Build, sign, notarize and publish a macOS release of TriGenius to GitHub Releases.
# Usage: Scripts/release.sh <version>   e.g. Scripts/release.sh 1.2.0
#
# One-time setup (not done by this script):
#   xcrun notarytool store-credentials TriGenius-Notary \
#     --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
set -euo pipefail

VERSION="${1:?Usage: Scripts/release.sh <version, e.g. 1.2.0>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
	echo "error: version must look like X.Y or X.Y.Z, got: $VERSION" >&2
	exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="TriGenius.xcodeproj"
SCHEME="TriGenius"
TAG="v$VERSION"
DIST_DIR="$REPO_ROOT/dist"
DMG_PATH="$DIST_DIR/TriGenius-$VERSION.dmg"

# if [[ -n "$(git status --porcelain)" ]]; then // Do not check for now
# 	echo "error: working tree is not clean — commit or stash changes first" >&2
# 	exit 1
# fi

if git rev-parse "$TAG" >/dev/null 2>&1 || git ls-remote --tags origin "$TAG" | grep -q "$TAG"; then
	echo "error: tag $TAG already exists locally or on origin" >&2
	exit 1
fi

IDENTITIES="$(security find-identity -v -p codesigning | grep '"Developer ID Application:' || true)"
IDENTITY_COUNT="$(echo "$IDENTITIES" | grep -c . || true)"
if [[ "$IDENTITY_COUNT" -ne 1 ]]; then
	echo "error: expected exactly one 'Developer ID Application' identity in the keychain, found $IDENTITY_COUNT" >&2
	exit 1
fi
SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')"
echo "Using signing identity: $SIGN_IDENTITY"

echo "Bumping MARKETING_VERSION -> $VERSION"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PROJECT/project.pbxproj"

CURRENT_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | sed -E 's/[^0-9]*([0-9]+);.*/\1/')"
NEXT_BUILD=$((CURRENT_BUILD + 1))
echo "Bumping CURRENT_PROJECT_VERSION $CURRENT_BUILD -> $NEXT_BUILD"
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PROJECT/project.pbxproj"

WORK_DIR="$(mktemp -d)"
# trap 'rm -rf "$WORK_DIR"' EXIT	// do not delete the work dir for now, so we can inspect it if something goes wrong
echo "Using temporary work dir: $WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/TriGenius.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
APP_PATH="$EXPORT_PATH/TriGenius.app"
NOTARIZE_ZIP="$WORK_DIR/TriGenius-notarize.zip"

echo "Archiving..."
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=macOS' \
	-archivePath "$ARCHIVE_PATH" \
	-allowProvisioningUpdates \
	CODE_SIGN_ENTITLEMENTS=TriGenius/TriGenius-Release.entitlements \
	ENABLE_HARDENED_RUNTIME=YES

echo "Exporting (Developer ID)..."
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE_PATH" \
	-exportPath "$EXPORT_PATH" \
	-exportOptionsPlist Scripts/ExportOptions.plist \
	-allowProvisioningUpdates

echo "Re-signing with hardened runtime + secure timestamp..."
# Reuse the entitlements xcodebuild already resolved into the exported app (with
# com.apple.application-identifier / team-identifier / $(TeamIdentifierPrefix) filled
# in) rather than the raw project entitlements file — codesign does no variable
# substitution, and a signature missing application-identifier fails App Sandbox
# validation at launch (RBSRequestErrorDomain/163, "Launchd job spawn failed").
ENTITLEMENTS_PLIST="$WORK_DIR/entitlements.plist"
codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml "$APP_PATH"
codesign --force --deep --options runtime --timestamp \
	--entitlements "$ENTITLEMENTS_PLIST" \
	--sign "$SIGN_IDENTITY" "$APP_PATH"

echo "Submitting for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
if ! xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile TriGenius-Notary --wait; then
	echo "Notarization failed — fetching log for the most recent submission:" >&2
	SUBMISSION_ID="$(xcrun notarytool history --keychain-profile TriGenius-Notary | awk '/id:/{print $2; exit}')"
	xcrun notarytool log "$SUBMISSION_ID" --keychain-profile TriGenius-Notary
	exit 1
fi

echo "Stapling..."
xcrun stapler staple "$APP_PATH"

echo "Packaging .dmg..."
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
diskutil image create from --format UDZO --volumeName TriGenius "$APP_PATH" "$DMG_PATH"

echo "Publishing release $TAG..."
git add "$PROJECT/project.pbxproj"
git commit -m "release: TriGenius $VERSION"

git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "$DMG_PATH" --title "TriGenius $VERSION" --generate-notes

echo "Done: $DMG_PATH published as $TAG"
