#!/bin/bash
# Build, sign, notarize and publish a macOS release of TriGenius to GitHub Releases.
#
# Usage: Scripts/release.sh [version] [--withios]
#   Scripts/release.sh                 # patch-bump the last released version
#   Scripts/release.sh 1.2.0           # release an explicit version
#   Scripts/release.sh --withios       # ...and push the same build to TestFlight
#
# One-time setup (not done by this script):
#   xcrun notarytool store-credentials TriGenius-Notary \
#     --key <AuthKey.p8> --key-id <KEY_ID> --issuer <ISSUER_ID>
set -euo pipefail

VERSION=""
WITH_IOS=0
for arg in "$@"; do
	case "$arg" in
	--withios) WITH_IOS=1 ;;
	-*)
		echo "error: unknown flag: $arg (usage: Scripts/release.sh [version] [--withios])" >&2
		exit 1
		;;
	*)
		if [[ -n "$VERSION" ]]; then
			echo "error: version given more than once: $VERSION, $arg" >&2
			exit 1
		fi
		VERSION="$arg"
		;;
	esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="TriGenius.xcodeproj"
SCHEME="TriGenius"

# With no version given, patch-bump the newest release *tag* — the record of what
# actually shipped. MARKETING_VERSION in the project is deliberately not the source:
# it can be edited between releases, so bumping it would skip the pending version.
if [[ -z "$VERSION" ]]; then
	LATEST_TAG="$(git tag --list 'v*' --sort=-v:refname | head -1)"
	if [[ -z "$LATEST_TAG" ]]; then
		echo "error: no v* tag to increment from — pass the version explicitly" >&2
		exit 1
	fi
	if [[ ! "${LATEST_TAG#v}" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]]; then
		echo "error: cannot patch-bump tag $LATEST_TAG — pass the version explicitly" >&2
		exit 1
	fi
	VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((${BASH_REMATCH[4]:-0} + 1))"
	echo "No version given — bumping $LATEST_TAG -> $VERSION"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
	echo "error: version must look like X.Y or X.Y.Z, got: $VERSION" >&2
	exit 1
fi

TAG="v$VERSION"
DIST_DIR="$REPO_ROOT/dist"
DMG_PATH="$DIST_DIR/TriGenius-$VERSION.dmg"

# Untracked files are fine to release over — notes, scratch dirs and `ref/` are
# routinely lying around, and `dist/` is gitignored anyway. Modified *tracked* files
# are not: the release commit stages only project.pbxproj, so any other edit would
# ship inside the .dmg while staying absent from the tagged commit.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
	echo "error: tracked files have uncommitted changes — commit or stash them first" >&2
	echo "       (untracked files are fine and do not block a release)" >&2
	git status --short --untracked-files=no >&2
	exit 1
fi

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
# Pinned derived data so the Sparkle SPM artifact (generate_appcast) is at a known path.
xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration Release \
	-destination 'generic/platform=macOS' \
	-archivePath "$ARCHIVE_PATH" \
	-derivedDataPath "$WORK_DIR/DerivedData" \
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
# No --deep: it would stamp the app's entitlements onto every nested binary,
# breaking Sparkle's XPC installer service (which needs its own); nested code
# keeps its valid export-time signatures and is only sealed by the outer one.
ENTITLEMENTS_PLIST="$WORK_DIR/entitlements.plist"
codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml "$APP_PATH"
codesign --force --options runtime --timestamp \
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
# diskutil images the *contents* of the given folder as the volume root, so
# stage a folder holding the .app (plus the usual /Applications drop link) —
# imaging $APP_PATH directly would put the app's Contents/ at the root, where
# neither users nor generate_appcast find an app bundle.
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
DMG_ROOT="$WORK_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/TriGenius.app"
ln -s /Applications "$DMG_ROOT/Applications"
diskutil image create from --format UDZO --volumeName TriGenius "$DMG_ROOT" "$DMG_PATH"

echo "Generating Sparkle appcast..."
# EdDSA-sign the DMG and emit appcast.xml (single-item feed for just this
# release; SUFeedURL resolves it via GitHub's /releases/latest/download/).
# Needs the Sparkle private key generated once per machine via generate_keys.
SPARKLE_BIN="$WORK_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="$WORK_DIR/appcast"
mkdir -p "$APPCAST_DIR"
cp "$DMG_PATH" "$APPCAST_DIR/"
"$SPARKLE_BIN/generate_appcast" "$APPCAST_DIR" \
	--download-url-prefix "https://github.com/MaxDilling/TriGenius/releases/download/$TAG/" \
	--link "https://github.com/MaxDilling/TriGenius/releases"

echo "Publishing release $TAG..."
git add "$PROJECT/project.pbxproj"
git commit -m "release: TriGenius $VERSION"

git tag "$TAG"
git push origin HEAD "$TAG"
gh release create "$TAG" "$DMG_PATH" "$APPCAST_DIR/appcast.xml" --title "TriGenius $VERSION" --generate-notes

echo "Done: $DMG_PATH published as $TAG"

if [[ "$WITH_IOS" -eq 1 ]]; then
	echo
	echo "Uploading the same build to TestFlight..."
	# --no-bump: this script already set MARKETING_VERSION and CURRENT_PROJECT_VERSION
	# and committed them, so both platforms ship the identical version/build pair and
	# the tree stays clean after the tag. Run last on purpose — a failed upload then
	# costs a rerun of testflight.sh, not the whole archive + notarization.
	if ! Scripts/testflight.sh --no-bump; then
		echo "error: TestFlight upload failed. The macOS release $TAG is already published;" >&2
		echo "       retry the iOS half alone with: Scripts/testflight.sh --no-bump" >&2
		exit 1
	fi
fi
