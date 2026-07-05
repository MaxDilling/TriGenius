# Release script

`release.sh` builds, signs, notarizes, packages and publishes a macOS release of TriGenius. It's run manually from your own Mac (the one with Xcode-beta) — there is no CI for this.

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
