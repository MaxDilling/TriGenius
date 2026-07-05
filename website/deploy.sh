#!/usr/bin/env bash
# Build the site and force-push dist/ to the gh-pages branch of origin.
# gh-pages then serves it at the custom domain in $DOMAIN (via the CNAME file).
set -euo pipefail
cd "$(dirname "$0")"

DOMAIN="trigenius.narica.net"
BRANCH="gh-pages"
DIST="dist"

REMOTE_URL="$(git remote get-url origin)"

deno task build

# GitHub Pages extras: custom domain, skip Jekyll, SPA fallback so /privacy
# resolves on a direct hit / refresh.
echo "$DOMAIN" > "$DIST/CNAME"
touch "$DIST/.nojekyll"
cp "$DIST/index.html" "$DIST/404.html"

# Publish dist/ as a single fresh commit on gh-pages (orphan-style, no history).
pushd "$DIST" >/dev/null
rm -rf .git
git init -q
git add -A
git -c user.name="TriGenius Deploy" -c user.email="deploy@trigenius" \
  commit -q -m "Deploy $(date -u +%FT%TZ)"
git branch -M "$BRANCH"
git push -f "$REMOTE_URL" "HEAD:$BRANCH"
rm -rf .git
popd >/dev/null

echo "Deployed → https://$DOMAIN/privacy"
