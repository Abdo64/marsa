# Signing the macOS build

Without signing, macOS blocks the downloaded app until the user right-clicks it
and chooses *Open*. A build that is signed with a **Developer ID** certificate
and **notarised** by Apple opens normally on any Mac.

The release workflow does both automatically once five repository secrets
exist. Until then it publishes an unsigned build, exactly as before.

## What you need

- Membership of the [Apple Developer Program](https://developer.apple.com/programs/)
  (99 USD a year). A free Apple ID cannot create Developer ID certificates.
- To be the team's **Account Holder**: only that role can create this kind of
  certificate.

An *Apple Development* or *Apple Distribution* certificate is not enough. Those
are for running on your own devices and for the App Store; apps downloaded from
a website need **Developer ID Application**.

## One-time setup

1. **Create the certificate.** In Xcode: Settings → Accounts → select the team →
   Manage Certificates → **+** → *Developer ID Application*.
2. **Export it.** Open Keychain Access, find *Developer ID Application: Your
   Name (TEAMID)*, expand it so the private key is included, right-click →
   Export, save as `developer-id.p12` and choose a password.
3. **Create an app-specific password** for notarisation at
   [account.apple.com](https://account.apple.com) → Sign-In and Security →
   App-Specific Passwords.
4. **Find your Team ID** (ten characters) at
   [developer.apple.com/account](https://developer.apple.com/account) →
   Membership details.
5. **Add the secrets** in the GitHub repository: Settings → Secrets and
   variables → Actions → New repository secret.

   | Secret | Value |
   | --- | --- |
   | `MACOS_CERTIFICATE_P12` | output of `base64 -i developer-id.p12` |
   | `MACOS_CERTIFICATE_PASSWORD` | the password chosen in step 2 |
   | `APPLE_ID` | the Apple ID email of the developer account |
   | `APPLE_APP_PASSWORD` | the app-specific password from step 3 |
   | `APPLE_TEAM_ID` | the Team ID from step 4 |

6. **Delete `developer-id.p12`** from your disk once the secret is saved. It is
   the key to publishing software under your name.

The next version tag you push is then signed, notarised and stapled. The
workflow's last step asks macOS itself (`spctl`) to confirm the disk image is
accepted, so a release cannot go out half-signed.

## Windows

The Windows installer is unsigned as well, which is why SmartScreen warns on
first run. Removing that warning needs a code-signing certificate from a
certificate authority, or Microsoft's Trusted Signing service. This workflow
does not sign for Windows yet.
