# File2File

**Android / iOS P2P file transfer and personal NAS client**  
Direct P2P · Encrypted by default · No public IP required · Powered by [webrpc](https://www.webrpc.cn/)

Transfer files between your phone and other devices, or browse, upload, and download folders on a personal NAS you run yourself. Traffic prefers an encrypted peer-to-peer path instead of uploading everything to a public cloud.

[简体中文](README.md) · English

---

## Contents

- [What is File2File?](#what-is-file2file)
- [Who is it for?](#who-is-it-for)
- [Core features](#core-features)
- [Related projects](#related-projects)
- [Getting started](#getting-started)
- [Build from source](#build-from-source)
- [FAQ](#faq)
- [Tech stack](#tech-stack)
- [Keywords](#keywords)

---

## What is File2File?

**File2File** (this repository is the Flutter mobile client) is a cross-platform mobile app built on [webrpc](https://www.webrpc.cn/). It combines two workflows in one UI:

1. **P2P chat and file transfer** — message and send files after a direct session; no need to park files on a public cloud first.
2. **Personal NAS / drive** — connect to your own [`mywebdisk-server`](https://github.com/xiaoming-software/mywebdisk) to browse, upload, download, search, and organize directories on hardware you control.

Transport is encrypted by default. **No public IP** or router port mapping is required. A Token identifies a device; a passphrase can restrict who connects to you.

For Windows / macOS / Linux, use the desktop client:  
[File2File Desktop](https://github.com/xiaoming-software/File2File-Desktop/tree/main)

---

## Who is it for?

- People who regularly move installers, media, or documents between **phone ↔ PC** or **phone ↔ phone**
- Anyone who wants secure access to **home PC or NAS folders** while traveling, with files staying on a path they choose
- Users of [File2File Desktop](https://github.com/xiaoming-software/File2File-Desktop/tree/main) who need a matching mobile client

---

## Core features

### Chat and file transfer

- Multi-session management: create, rename, connect, disconnect, delete, clear local history
- Text messages and file sends (photo library and system file picker)
- Transfer progress and retry; save received media to the album or download locally
- Interoperable with [File2File Desktop](https://github.com/xiaoming-software/File2File-Desktop/tree/main) over the same webrpc session and message protocol

<img src="img/file2windows.png" alt="Sending a photo from the app to a computer" width="280">

*Send a photo from the phone to a computer. Progress, speed, and “sent” status show in the session.*

### Personal NAS / drive

After connecting to a self-hosted [`mywebdisk-server`](https://github.com/xiaoming-software/mywebdisk):

<img src="img/mywebdisk.png" alt="Drive session list" width="280">

*Drive tab: connected personal NAS sessions and “New drive”.*

| Capability | Description |
| --- | --- |
| Browse | Directory listing, parent path, capacity and free space |
| Upload / download | Album or multi-file queued uploads; dedicated task page with progress and retry |
| Preview | Editable text save; images; progressive audio/video playback |
| Organize | Create folders, rename, move, delete, multi-select batch actions |
| Search | Full-drive filename search |

<img src="img/mywebdisk-data.png" alt="Browsing a personal NAS folder in the app" width="280">

*Inside a drive: capacity, search, folders, and files in one list.*

Files remain under the directory you configure on the server; reads and writes use an encrypted webrpc P2P channel.

---

## Related projects

| Project | Role | Link |
| --- | --- | --- |
| **webrpc** | P2P transport and Token service | [https://www.webrpc.cn/](https://www.webrpc.cn/) |
| **File2File Desktop** | Windows / macOS / Linux client | [GitHub repo](https://github.com/xiaoming-software/File2File-Desktop/tree/main) |
| **mywebdisk** | Personal NAS server (`mywebdisk-server`) | [GitHub repo](https://github.com/xiaoming-software/mywebdisk) |
| **File2File App** (this repo) | Android / iOS mobile client | This repository |

---

## Getting started

Both peers (or the NAS server) need a [webrpc](https://www.webrpc.cn/) **Token** and **password**. Register on the website to obtain Tokens, or use **one-click registration** in the app when available (subject to webrpc rules shown in the UI).

> Never commit Tokens, passwords, or passphrases to the repository, scripts, or public docs. Enter them only inside the app.

### 1. Sign in on mobile

1. Install the app: Android APKs are on [GitHub Releases](https://github.com/xiaoming-software/File2File-App/releases), or build from source below. iOS requires a source build and signing on macOS.
2. Sign in with a [webrpc](https://www.webrpc.cn/) Token and password, and set a **passphrase** (required; peers need it to connect to you).
3. Optionally remember the account for the next launch.

### 2. Transfer files with a PC or another phone

1. The peer runs [File2File Desktop](https://github.com/xiaoming-software/File2File-Desktop/tree/main) or another File2File App and stays online.
2. On mobile, create a session with the peer Token and passphrase (if set).
3. After the session connects, send text and files.

Peers connecting to you must use the passphrase you set at login.

### 3. Connect a personal NAS

1. On the machine that holds your files, download and start `mywebdisk-server` from [mywebdisk](https://github.com/xiaoming-software/mywebdisk) (Token, password, permission passphrase, and share path).
2. Sign into the phone app with a **different** Token (not the NAS server Token).
3. Under **Drive**, create a connection with the server Token and `--permission` passphrase.
4. Browse, upload, download, and manage files after connect.

Server flags and prebuilt binaries: [mywebdisk repository](https://github.com/xiaoming-software/mywebdisk).

---

## Build from source

Android release APKs are published on [GitHub Releases](https://github.com/xiaoming-software/File2File-App/releases) (arm64). iOS is not sideloaded from GitHub; build and sign on macOS. For development, use the scripts below.

### Requirements

- [Flutter](https://flutter.dev/) (verified with Flutter 3.47+ / Dart 3.13+)
- Android: Android SDK, JDK; physical device or an **arm64** emulator (the webrpc Android library is `arm64-v8a`)
- iOS: Xcode and CocoaPods (a valid signing identity is required for devices)

Optional local env helper:

```bash
source tool/env.sh
flutter doctor
```

### Android emulator (one-shot)

If AVD `File2File_API35_arm64` is configured (recommended 1080×1920):

```bash
./tool/run_android_emulator.sh
```

Or manually:

```bash
source tool/env.sh
flutter emulators --launch File2File_API35_arm64
flutter run -d emulator-5554
```

> The webrpc Android library currently ships **arm64-v8a** only. Use an arm64 emulator or arm64 device — not an x86 system image.

### iOS Simulator (one-shot)

Requires macOS, Xcode, and an installed iOS Simulator runtime. Defaults to **iPhone 15**:

```bash
./tool/run_ios_simulator.sh
```

Pick another model (must match `xcrun simctl list devices available`):

```bash
IOS_SIMULATOR="iPhone 15 Pro" ./tool/run_ios_simulator.sh
```

> `webrpc-sdk/libwebrpc-ios.a` is for physical devices. The Simulator uses `libwebrpc-ios-simulator.a` (Apple Silicon arm64). Intel simulators are not covered.

### Common commands

```bash
flutter pub get
flutter run          # attached device / emulator
flutter build apk    # Android
flutter build ios    # iOS (macOS + Xcode signing required)
```

Native webrpc bits live under `webrpc-sdk/`. On Android, `libwebrpc.so` is under `android/app/src/main/jniLibs/arm64-v8a/`.

### Publish the Android APK (GitHub Release)

Set `VERSION_NAME` at the top of the script, then:

```bash
./tool/release_android.sh
```

The script generates a local upload keystore on first run, sets `versionCode` from a timestamp, builds a release APK, pushes tag `v<version>`, and publishes it as the Latest GitHub Release.

Keep `android/keystore/upload.jks` and `android/key.properties` backed up (they are gitignored). Losing or rotating the key means users cannot upgrade over the old app.

---

## FAQ

**How is this different from a typical cloud drive app?**  
Chat transfers are device-to-device. The drive feature talks to your own [`mywebdisk-server`](https://github.com/xiaoming-software/mywebdisk); you choose the folder. The platform does not host your file contents.

**Does it work without a public IP?**  
Yes. Connectivity uses [webrpc](https://www.webrpc.cn/). No fixed public IP or port mapping is required.

**Where do I get a Token?**  
Register and manage Tokens at [webrpc](https://www.webrpc.cn/). The app may also offer one-click registration when enabled.

**Why do I need two Tokens for NAS?**  
One Token for home `mywebdisk-server`, another for the phone client. When adding a drive in the app, enter the **server** Token and passphrase. See [mywebdisk](https://github.com/xiaoming-software/mywebdisk).

**Does it work with the desktop client?**  
Yes — use [File2File Desktop](https://github.com/xiaoming-software/File2File-Desktop/tree/main). Both sides must be online with the correct Token / passphrase.

**Android emulator cannot load the native library?**  
Use an arm64 image and the `arm64-v8a` `libwebrpc.so`. Do not use an x86 emulator.

---

## Tech stack

| Layer | Technology |
| --- | --- |
| App | Flutter (Android / iOS) |
| P2P transport | [webrpc](https://www.webrpc.cn/) C ABI via `dart:ffi` |
| Local state | Secure storage for Tokens / session and transfer metadata |

---

## Keywords

File2File, File2File App, P2P file transfer, peer-to-peer file sharing, mobile file transfer, personal NAS, private cloud drive, no public IP, webrpc, Flutter, Android, iOS, mywebdisk, encrypted transfer

---

## Links

- webrpc (Tokens): [https://www.webrpc.cn/](https://www.webrpc.cn/)
- File2File Desktop: [https://github.com/xiaoming-software/File2File-Desktop/tree/main](https://github.com/xiaoming-software/File2File-Desktop/tree/main)
- mywebdisk server: [https://github.com/xiaoming-software/mywebdisk](https://github.com/xiaoming-software/mywebdisk)
- Chinese README: [README.md](README.md)

> File2File moves data between peers; it does not host your files. Keep Tokens and passphrases private, and only connect to devices and people you trust.
