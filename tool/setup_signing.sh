#!/bin/bash
# One-time setup so GitHub Actions can sign and notarise the macOS build.
# Checks everything locally first, then stores five secrets in the GitHub
# repository. Nothing is written to disk and nothing is printed back.
#
#   tool/setup_signing.sh ~/Desktop/developer-id.p12
#
# Before running it:
#   1. Keychain Access -> My Certificates -> "Developer ID Application: ..."
#      -> right-click -> Export -> save as a .p12 with a password.
#   2. account.apple.com -> Sign-In and Security -> App-Specific Passwords
#      -> create one (looks like abcd-efgh-ijkl-mnop).
set -euo pipefail

P12="${1:-}"
[ -f "$P12" ] || { echo "Usage: tool/setup_signing.sh path/to/developer-id.p12"; exit 1; }
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || gh auth login

cd "$(dirname "$0")/.."
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Repository: $REPO"

read -r -s -p "Password of the .p12 file: " P12_PASSWORD; echo
read -r -p "Apple ID email of the developer account: " APPLE_ID
read -r -s -p "App-specific password: " APPLE_APP_PASSWORD; echo

# Open the .p12 in a throwaway keychain to prove the password is right and
# that it really holds a Developer ID certificate with its private key.
KEYCHAIN="$(mktemp -d)/check.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
# It is never added to the keychain search list, so your own keychains are
# not touched; it is deleted again when the script ends.
trap 'security delete-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null \
  || { echo "Could not open the .p12: wrong password?"; exit 1; }
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
[ -n "$IDENTITY" ] || {
  echo "That .p12 has no 'Developer ID Application' certificate with a private key."
  echo "Export it from 'My Certificates' so the key comes along."
  exit 1
}
TEAM_ID="$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]{10})\)$/\1/')"
echo "Certificate: $IDENTITY"

# Ask Apple's notary service something harmless: this catches a wrong
# password, a wrong team, or a licence agreement waiting to be accepted.
echo "Checking the Apple credentials..."
xcrun notarytool history --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID" >/dev/null \
  || { echo "Apple rejected those credentials (see the message above)."; exit 1; }

echo "Saving secrets to $REPO..."
base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD"      | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPO"
printf '%s' "$APPLE_ID"          | gh secret set APPLE_ID --repo "$REPO"
printf '%s' "$APPLE_APP_PASSWORD" | gh secret set APPLE_APP_PASSWORD --repo "$REPO"
printf '%s' "$TEAM_ID"           | gh secret set APPLE_TEAM_ID --repo "$REPO"

echo
echo "Done. Releases are now signed and notarised."
RUN="$(gh run list --repo "$REPO" --workflow release --event push --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
if [ -n "$RUN" ]; then
  read -r -p "Rebuild the latest release now so its download is signed too? [y/N] " again
  if [[ "$again" =~ ^[Yy] ]]; then
    gh run rerun "$RUN" --repo "$REPO"
    echo "Started. Watch it with: gh run watch $RUN --repo $REPO"
  fi
fi
echo "You can delete $P12 now."
