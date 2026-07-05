# Release scripts

Two manual scripts, run from your own Mac (the one with Xcode-beta) — there is no CI:

- **`release.sh`** — macOS: Developer ID build → notarize → `.dmg` → GitHub Release.
- **`testflight.sh`** — iOS: Apple Distribution build → upload to App Store Connect / TestFlight.

# macOS release (`release.sh`)

`release.sh` builds, signs, notarizes, packages and publishes a macOS release of TriGenius.

## One-time setup

1. **Developer ID Application certificate** — must already be in your login keychain. Check with:
   ```
   security find-identity -v -p codesigning
   ```
   You should see exactly one `"Developer ID Application: ..."` entry for team `748ZUJYR3Q`. If missing, create/download it from [Apple Developer → Certificates](https://developer.apple.com/account/resources/certificates/list) and install it (double-click the `.cer`).

2. **`gh` CLI**, logged in with a token that has `repo` scope:
   ```
   gh auth login
   ```

3. **App Store Connect API key** for notarization — generate one at [App Store Connect → Users and Access → Integrations → API Keys](https://appstoreconnect.apple.com/access/integrations/api) (role: *Developer* is enough). Download the `.p8` file, note the **Key ID** and **Issuer ID**, then register it locally once:
   ```
   xcrun notarytool store-credentials TriGenius-Notary \
     --key /path/to/AuthKey_XXXXXXXXXX.p8 \
     --key-id <KEY_ID> \
     --issuer <ISSUER_ID>
   ```
   This stores the credentials in your keychain under the profile name `TriGenius-Notary`, which the script references — you only need to do this once per Mac.

## Cutting a release

From a clean working tree (no uncommitted changes):

```
Scripts/release.sh 1.1.0
```

This will:
1. Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the Xcode project
2. Archive and export a Developer ID–signed build (using `TriGenius/TriGenius-Release.entitlements`, `aps-environment: production`)
3. Notarize and staple it
4. Package it as `dist/TriGenius-1.1.0.dmg`
5. Commit the version bump, tag `v1.1.0`, push both, and publish a GitHub Release with the `.dmg` attached

Takes a few minutes, mostly waiting on Apple's notarization service. If notarization is rejected, the script prints the rejection log automatically.

# iOS TestFlight (`testflight.sh`)

`testflight.sh` bumps only the build number, archives the iOS build signed with **Apple Distribution**, and uploads it straight to App Store Connect (no git commit/tag, no GitHub release — betas are throwaway). `MARKETING_VERSION` stays owned by `release.sh`; you can upload many builds per version.

## One-time setup

1. **App record in App Store Connect** — [Apps → +](https://appstoreconnect.apple.com/apps): platform **iOS**, bundle id `net.Narica.TriGenius`. Without it the upload is rejected.

2. **App IDs with capabilities** — `net.Narica.TriGenius` *and* the widget `net.Narica.TriGenius.WeeklyTargetWidget` must have HealthKit, iCloud/CloudKit, Push and App Groups enabled in the [Developer portal](https://developer.apple.com/account/resources/identifiers/list). Automatic signing (`-allowProvisioningUpdates`) creates the App Store provisioning profiles and the Apple Distribution certificate on demand.

3. **App Store Connect API key** for the upload — an [API key](https://appstoreconnect.apple.com/access/integrations/api) with role **App Manager**. Download the `.p8` (you keep the raw file — unlike notarization, the `TriGenius-Notary` keychain profile isn't used here). Point the script at it via a gitignored `Scripts/testflight.env`:
   ```
   export ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
   export ASC_KEY_ID=XXXXXXXXXX
   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

## Uploading a build

```
Scripts/testflight.sh
```

Bumps `CURRENT_PROJECT_VERSION`, archives, signs and uploads. The build appears in TestFlight after a few minutes of "Processing".

## Getting it to testers

In App Store Connect → your app → **TestFlight**:

- **Internal Testers** (up to 100) — people in *Users and Access* on your team. Instant, **no review**. Simplest for a small fixed circle.
- **External Testers** (up to 10,000) — invited by email or public link. The **first build needs Beta App Review** (~1 day; HealthKit may draw questions). Create a group, add their emails.
