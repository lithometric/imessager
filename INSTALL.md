# Installing iMessager

iMessager runs on macOS 14 or later. There's no download yet, so you build it from this repo. It takes a couple of minutes.

## Build and install

1. **Get the tools.** Building needs the macOS 26 SDK, which comes with Xcode 26 or later from the App Store (Xcode 26 needs macOS 15.6 or later). If you don't want all of Xcode, the Command Line Tools are enough: `xcode-select --install`. Check with `swift --version`, which should say Swift 6.2 or later.
2. **Clone and install.**

   ```bash
   git clone https://github.com/lithometric/imessager
   cd imessager
   scripts/build-app.sh --install
   ```

   This builds a release copy, copies it to `/Applications` and opens it.
3. **First launch.** The app opens a setup checklist for Full Disk Access, your OpenRouter key, and Contacts and Messages access. The steps are in the [README](README.md#run-it).

## Update

```bash
cd imessager
git pull
scripts/build-app.sh --install
```

The script quits the running copy, replaces it and reopens it.

**If macOS asks for permissions again after an update:** macOS remembers permissions for an app's signature. The script signs with your Apple Development certificate when you have one (Xcode › Settings › Accounts › Manage Certificates › **+** › Apple Development; a free Apple account works). Without one, each rebuild looks like a new app to macOS: remove iMessager from Full Disk Access with − and add it again.

| Command | What it does |
|---|---|
| `scripts/build-app.sh` | Builds `build/iMessager.app` only |
| `scripts/build-app.sh --run` | Builds and opens it from `build/` without installing |
| `scripts/build-app.sh --install` | Builds, copies to `/Applications` and opens it |
| `CODESIGN_IDENTITY="…" scripts/build-app.sh` | Signs with a specific certificate |

## Share a built copy

If someone doesn't want to install Xcode, you can send them your build:

```bash
scripts/build-app.sh
ditto -c -k --keepParent build/iMessager.app iMessager.zip
```

They unzip it, drag iMessager to Applications and open it. The app isn't notarized, so macOS blocks it the first time:

- **macOS 15 and later:** click Done, then open System Settings › Privacy & Security, scroll to "iMessager was blocked" and click **Open Anyway**.
- **macOS 14:** Control-click the app › Open › Open.

Two limits:

- The build only runs on the same kind of Mac it was built on, Apple silicon or Intel (`uname -m` prints `arm64` for Apple silicon).
- Only share it with people who trust you. They're giving it Full Disk Access.

## Public download (not set up yet)

A download that opens without the Open Anyway step needs:

- A **Developer ID Application** certificate, from the Apple Developer Program ($99/year). Create it in Xcode › Settings › Accounts › Manage Certificates.
- **Notarization.** Sign with the hardened runtime and the `com.apple.security.automation.apple-events` entitlement (without it, sending through Messages fails), submit with `xcrun notarytool submit`, then attach the ticket with `xcrun stapler staple`.
- A **universal build** for both Apple silicon and Intel.

`scripts/build-app.sh` doesn't do these steps yet.
