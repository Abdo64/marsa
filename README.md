# Marsa

Marsa (مرسى, "harbour") is an open-source SSH and SFTP client for Windows and
macOS. Your hosts, keys and snippets live in encrypted vaults that sync across
your devices and your team through storage **you** control: one of your own
servers, or any shared folder. There is no account, no subscription and no
Marsa server.

Android and iOS are planned on the same codebase.

![Hosts](docs/screenshots/hosts-dark.png)

| Terminal | SFTP |
| --- | --- |
| ![Terminal](docs/screenshots/terminal-dark.png) | ![SFTP](docs/screenshots/sftp-light.png) |

## Features

- **Hosts** with groups, tags, search, jump hosts (ProxyJump) and import from
  `~/.ssh/config`. A host can sign in with **this device's SSH keys**
  (`~/.ssh/id_*`), used in place and never copied into the vault, so each
  device connects with its own key.
- **Terminal**: xterm-compatible, 256/true colour, several sessions side by
  side, copy/paste, reconnect, four colour schemes.
- **SFTP**: two panes (this computer and the server), upload and download of
  files and whole folders with progress, rename, delete, new folder,
  permissions.
- **Keychain**: generate Ed25519 or RSA keys, import existing ones (including
  passphrase-protected), copy the public key, install it on a host in one
  click. **Identities** let many hosts share one username/password/key.
- **Vaults**: several per device (for example *Personal* and *Team*), each
  with its own master password and its own sync location.
- **Sync** over SFTP to a server you own, or through a folder (iCloud Drive,
  OneDrive, Dropbox, Syncthing, a network share).
- **Port forwarding**: local, remote and dynamic (SOCKS5).
- **Snippets**: saved commands you can send to any open terminal.
- **Known hosts**: server keys are pinned on first use and synced, so a
  changed key is caught on every device.
- **Remember on this device**: optionally keep a vault's key in the macOS
  Keychain or Windows Credential Manager, so the app opens without typing the
  master password.
- **Light and dark themes**, or follow the system.
- Small: the macOS app is about 19 MB zipped (universal), with no bundled
  browser engine.

## How vaults and sync work

A vault is one file. Its contents are compressed and encrypted with
AES-256-GCM; the key is derived from your master password with Argon2id. The
master password is never stored, so a forgotten password cannot be recovered.

Sync mirrors that same encrypted file to a location you pick. The sync target
only ever sees ciphertext, and the sync settings themselves (server address,
credentials) stay in the local copy and are never uploaded.

**First device:** Settings → *Set up sync*. Choose *Your server (SFTP)* and
fill it in from any saved host, or choose a folder.

**Every other device:** on the unlock screen choose *Join a synced vault*,
enter the master password and point it at the same location. To avoid
retyping the server details, use *Copy link* next to Sync in Settings on the
first device and paste it into the join dialog; the link holds the location
only, never a password or key.

**Sharing with a team:** create a separate vault for shared servers, sync it
somewhere the team can reach, and give teammates the location and the master
password. To revoke someone, change the master password and whatever access
they had to the sync location.

Changes are merged record by record (last edit wins, deletions are
remembered), so two people editing different hosts never overwrite each other.
Sync runs when you unlock, shortly after every change, and every few minutes.

## Install

No compiling needed. These links always point at the latest release:

| Platform | Download | Then |
| --- | --- | --- |
| macOS (Apple Silicon and Intel) | [**Marsa-macos.dmg**](https://github.com/AdnanBolifa/marsa/releases/latest/download/Marsa-macos.dmg) | Open it and drag Marsa to Applications |
| Windows 10/11 (64-bit) | [**Marsa-windows-setup.exe**](https://github.com/AdnanBolifa/marsa/releases/latest/download/Marsa-windows-setup.exe) | Run the installer; no administrator rights needed |
| Windows, no install | [Marsa-windows-portable.zip](https://github.com/AdnanBolifa/marsa/releases/latest/download/Marsa-windows-portable.zip) | Unzip anywhere and run `marsa.exe` |

All versions are on the [Releases page](https://github.com/AdnanBolifa/marsa/releases).

The builds are not code-signed yet ([how to enable it](docs/signing.md)), so
the first launch needs one extra click:

- **macOS:** right-click Marsa in Applications and choose *Open*, then *Open*
  again. (If macOS says the app is damaged, run
  `xattr -dr com.apple.quarantine /Applications/Marsa.app` once.)
- **Windows:** on the SmartScreen prompt choose *More info* → *Run anyway*.

## Build from source

You need the [Flutter SDK](https://docs.flutter.dev/get-started/install)
(stable channel) and the platform toolchain: Xcode on macOS, Visual Studio
with the "Desktop development with C++" workload on Windows.

```sh
flutter pub get
flutter run -d macos          # or: -d windows
flutter build macos --release # build/macos/Build/Products/Release/Marsa.app
flutter build windows --release # build\windows\x64\runner\Release\
```

Flutter cannot cross-compile desktop apps: the Windows build must run on
Windows. You rarely need to, though. Pushing a version tag makes GitHub Actions
build the macOS disk image and the Windows installer and publish them:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

### Tests

```sh
flutter analyze
flutter test
```

`flutter test --update-goldens tool/screenshots_test.dart` re-renders every
screen with demo data into `docs/screenshots/`, which is the quickest way to
review a design change.

`flutter test integration_test -d macos` (or `-d windows`) runs the real app
in a window: a full new-user journey (vault, host, terminal, SFTP, remember,
lock, reopen) and the OS credential store.

`test/ssh_integration_test.dart` starts a throwaway, unprivileged `sshd` on a
loopback port inside a temp directory and exercises real connections: key
authentication, host-key pinning, jump hosts, an interactive shell, SFTP
transfers, port forwards and vault sync over SFTP. It needs `/usr/sbin/sshd`
(present on macOS and most Linux systems) and is skipped elsewhere. It does not
touch `~/.ssh`.

## Project layout

```
lib/core/   vault encryption, data model, merge and sync (no UI)
lib/ssh/    connections, keys, port forwarding, SFTP backends, sessions
lib/ui/     screens and themes
test/       unit, UI layout and end-to-end SSH tests
```

Per-device data is in the user's application-support directory
(`~/Library/Application Support/dev.marsa.marsa` on macOS,
`%APPDATA%\dev.marsa\Marsa` on Windows).

## Security notes and current limits

- This project has not had an independent security audit.
- Private keys are stored unencrypted *inside* the encrypted vault. A
  passphrase-protected key is unlocked once at import; from then on the vault's
  master password is what protects it.
- "Remember on this device" stores the vault key (not the password) in the
  OS credential store. Anyone who can use your signed-in OS account can then
  open the vault; leave it off on shared computers.
- Device SSH keys are read from `~/.ssh` at connect time. A
  passphrase-protected key asks for its passphrase once per app run. Keys
  that live only in an agent or on a hardware token are not supported.
- Anyone with the master password and access to the sync location can read the
  vault. Vault sharing has no per-user permissions.
- The macOS build runs without the App Sandbox, because an SFTP client needs
  to read and write files anywhere you choose.
- Not implemented yet: local terminal, SSH agent forwarding, Mosh/Telnet/serial,
  auto-lock and biometric unlock, drag and drop into the SFTP panes, resuming
  interrupted transfers.

## Roadmap

- Android and iOS apps (the core and SSH layers are already platform-neutral).
- Installers: MSIX/Inno Setup for Windows, notarised DMG for macOS.
- Auto-lock and OS keychain/biometric unlock.
- WebDAV and S3 sync targets.

## License

[MIT](LICENSE). Third-party components are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) and in the app under
Settings → About.
