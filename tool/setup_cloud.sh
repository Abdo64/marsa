#!/bin/bash
# One-time setup so Marsa can offer "Sign in to Dropbox / Google Drive" for
# sync. Takes the app keys you registered (docs/cloud-sync.md), keeps them in
# cloud_keys.json for builds on this computer (not committed) and stores them
# as secrets in the GitHub repository for released builds.
#
#   tool/setup_cloud.sh
#
# Leave an answer empty to skip that service.
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -p "Dropbox app key: " DROPBOX_APP_KEY
read -r -p "Google OAuth client ID: " GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET=
if [ -n "$GOOGLE_CLIENT_ID" ]; then
  read -r -p "Google OAuth client secret: " GOOGLE_CLIENT_SECRET
  [ -n "$GOOGLE_CLIENT_SECRET" ] || { echo "Google needs both the ID and the secret."; exit 1; }
fi
[ -n "$DROPBOX_APP_KEY$GOOGLE_CLIENT_ID" ] || { echo "Nothing entered."; exit 1; }

for v in "$DROPBOX_APP_KEY" "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET"; do
  case "$v" in *[\"\\[:space:]]*) echo "A key contains a space or quote; paste it again."; exit 1;; esac
done

printf '{"DROPBOX_APP_KEY":"%s","GOOGLE_CLIENT_ID":"%s","GOOGLE_CLIENT_SECRET":"%s"}\n' \
  "$DROPBOX_APP_KEY" "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET" > cloud_keys.json
echo "Wrote cloud_keys.json (ignored by git)."

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  set_secret() { if [ -n "$2" ]; then printf '%s' "$2" | gh secret set "$1" --repo "$REPO"; fi; }
  set_secret DROPBOX_APP_KEY "$DROPBOX_APP_KEY"
  set_secret GOOGLE_CLIENT_ID "$GOOGLE_CLIENT_ID"
  set_secret GOOGLE_CLIENT_SECRET "$GOOGLE_CLIENT_SECRET"
  echo "Done. The next release offers these services."
else
  echo "GitHub CLI is not signed in, so the repository secrets were not set."
  echo "Run 'gh auth login' and this script again for released builds."
fi
echo "Build here with:  flutter build macos --release --dart-define-from-file=cloud_keys.json"
