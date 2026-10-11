# Signing in to Dropbox and Google Drive

Marsa can keep a vault's encrypted file in Dropbox or Google Drive after a
sign-in in the browser. For that, Dropbox and Google must know the app: each
needs a free app registration, done once by whoever publishes the build.
Builds made without the keys work as before and simply do not show the two
options.

The keys identify the app, not a person. They give no access to anybody's
files; each user still signs in and approves Marsa themselves.

## Dropbox

1. Open <https://www.dropbox.com/developers/apps> and choose **Create app**.
2. **Scoped access**, then **App folder** (Marsa only ever sees its own
   folder), and a name. The name becomes the folder under *Apps* in each
   user's Dropbox.
3. On the **Permissions** tab tick `files.content.write` and
   `files.content.read`, then **Submit**.
4. On the **Settings** tab:
   - add the redirect URI `http://localhost:53127/`
   - set *Allow public clients (Implicit Grant & PKCE)* to **Allow**
5. Copy the **App key**.

A new Dropbox app is in development mode, which caps how many people can link
it. Use **Apply for production** on the Settings tab before sharing widely.

## Google Drive

1. Open <https://console.cloud.google.com>, create a project, and enable the
   **Google Drive API** for it.
2. Under **Google Auth Platform** (OAuth consent screen) choose **External**,
   fill in the app name and your email, and add the scope
   `.../auth/drive.appdata`. This scope only reaches Marsa's own hidden
   folder, so Google does not require a security review for it.
3. **Publish the app** (status *In production*). While it is left in
   *Testing*, only listed test users can sign in and every sign-in expires
   after seven days.
4. Under **Clients** create an OAuth client of type **Desktop app**. Copy the
   **client ID** and **client secret**. (Google issues a "secret" to desktop
   apps but does not treat it as confidential; it ships inside the app.)

## Give the keys to the build

```sh
tool/setup_cloud.sh
```

It asks for the three values, writes them to `cloud_keys.json` for local
builds (ignored by git) and stores them as repository secrets, so the next
tagged release includes them. To build locally:

```sh
flutter build macos --release --dart-define-from-file=cloud_keys.json
```

## What is stored where

- The vault file in the cloud drive is the same encrypted file used by every
  other sync target. The drive never sees its contents.
- Signing in gives Marsa a token, kept inside the encrypted local vault on
  that device. It is never written to the synced file or to a sync link, so
  each device signs in for itself.
- To cut a device off, remove Marsa under *Connected apps* in Dropbox or
  *Third-party apps* in the Google account.
