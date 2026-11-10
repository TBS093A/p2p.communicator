# iOS: installing without the App Store

There is no Apple developer account yet, so the app is not on the App Store
or TestFlight. CI builds an **unsigned** `.ipa` (workflow `ios`, artifact
`ios-unsigned-ipa`), and you sign it with your own, free Apple ID while
installing it on your iPhone.

## Limits of a free Apple ID

* The install runs for **7 days**, then it has to be re-signed (AltStore does
  this automatically when the computer with AltServer is on the same Wi-Fi).
  Your data stays; only the signature is renewed.
* At most 3 such apps on one iPhone at a time.
* Everything Apple requires for a store app (review, export compliance) does
  not apply: the app runs only on your own devices.

## Install

1. Download `ios-unsigned-ipa` from the latest `ios` workflow run on `main`
   (GitHub → Actions → ios → the run → Artifacts) and unzip it.
2. **Check the file before signing it.** Compare its SHA-256 with
   `sha256.txt` from the same artifact (macOS: `shasum -a 256 file.ipa`,
   Windows: `certutil -hashfile file.ipa SHA256`). Never install an `.ipa`
   from anywhere else: whoever built it controls the app and your keys.
3. **Use only these well-known tools, downloaded from their official
   sites.** They ask for your Apple ID and password to sign the app; a fake
   "sideloading" tool would steal that account. Consider a separate Apple ID
   just for this.
4. Install it with one of:
   * **Sideloadly** (Windows or macOS): connect the iPhone by cable, drop the
     `.ipa` in, sign in with your Apple ID, Start.
   * **AltStore** (Windows or macOS): install AltServer on the computer and
     AltStore on the iPhone, then in AltStore → My Apps → + pick the `.ipa`.
     AltStore refreshes the 7-day signature by itself over Wi-Fi.
   * **Xcode** (macOS): open `ios/Runner.xcworkspace`, choose your Apple ID as
     the team under Signing, and Run on the connected iPhone.
5. On the iPhone: Settings → General → VPN & Device Management → trust your
   Apple ID. On iOS 16+ also turn on Settings → Privacy & Security →
   Developer Mode (the phone restarts).

The Apple ID is used only by Apple to sign the app for your device. The app
itself never sees it.

## How it differs from Android

* **Only while open.** iOS suspends apps shortly after they leave the
  screen, so the Veilid node stops and messages arrive when you open the app
  again. Background delivery would need Apple push notifications, i.e. a
  server that knows when to wake your phone, which this project avoids.
* **No self-update.** The "Aktualizacje" tile only says how to update:
  install a newer `.ipa` the same way (it replaces the app and keeps its
  data).
* Keys live in the iOS Keychain instead of the Android Keystore. Note that
  Keychain items can survive deleting the app.
