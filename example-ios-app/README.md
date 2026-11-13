# Full iOS example app

The iOS counterpart of [`example-android-app`](../example-android-app): the same
full bitcoin-vision example application, screen for screen, in SwiftUI. It
includes photo capture/import, scan progress, word review/editing, layout
overrides, wallet storage, generated-seed photo backup, Penlock share-card
recovery and PSBT review/signing. It uses the adjacent `bitcoin-vision` Rust
library and models without a copied scanner implementation.

**This is a mainnet wallet and can sign real Bitcoin transactions.** Treat it as
experimental software. Never fund or use any phrase shown in this repository's
examples; those seeds are public. Do not import a real wallet just to try the
example. Release builds cover the window whenever the app leaves the
foreground, so the phrase never reaches the app switcher's snapshot; debug
builds stay visible for development. No network entitlement or upload service
is added by this example.

## One native bridge, two apps

Both apps bind to the same crate, `bitcoin-vision-mobile`, which lives in the
Android app's workspace at `../example-android-app/rust`. Android loads it as a
`cdylib` through UniFFI's Kotlin bindings; iOS links it as a static library
through UniFFI's Swift bindings. A change to the bridge is a change to both apps.

Running Cargo in the repository root builds/tests only `bitcoin-vision`. It does
not build this app, generate Swift bindings, or need Xcode.

## Building

You need Xcode (iOS 17 SDK or newer), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and the two iOS Rust targets for your rustup toolchain. No toolchain installer
runs implicitly.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
brew install xcodegen

cd example-ios-app
./build-rust.sh            # native library for device + simulator, bindings, models, fonts
xcodegen generate          # writes BitcoinVision.xcodeproj from project.yml
open BitcoinVision.xcodeproj
```

Or from the command line:

```sh
xcodebuild -project BitcoinVision.xcodeproj -scheme BitcoinVision \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`build-rust.sh` is the counterpart of the Android app's Gradle `preBuild`
tasks. It writes everything into `build/` (ignored by git):

| Output | What it is |
| --- | --- |
| `build/BitcoinVisionMobile.xcframework` | the bridge crate, `aarch64-apple-ios` and `aarch64-apple-ios-sim` static libraries |
| `build/generated/` | UniFFI Swift bindings and the C header/module map |
| `build/Resources/` | the six model files, the two IBM Plex faces, and license notices |

The Xcode target also runs `build-rust.sh` for the platform being built as a
pre-build phase, so editing the Rust bridge and pressing Run picks the change up
(Cargo is incremental). Set `SKIP_RUST_BUILD=1` in the build settings or on the
`xcodebuild` command line to reuse what was last built. The first build compiles
the whole scanner for iOS and takes a few minutes. Only arm64 simulators are
supported, matching the arm64-only Android app.

The bundle ID is `com.bitcoinvision.example`. Signing a device build needs your
own team in Xcode; no signing identity is bundled. **Installing it can update an
existing installation with that ID**, so do not install over a wallet you rely on.

Native support tests are the Android app's and run the same way:

```sh
cargo test --locked --manifest-path ../example-android-app/rust/Cargo.toml --workspace --lib
```

## Platform differences

The behaviour matches the Android app; these are the places the platform shapes it:

- **Camera** is AVFoundation, previewed fit-to-frame as CameraX's `FIT_CENTER`
  does. If camera access was denied, the page explains why and links to Settings,
  since iOS will not ask twice.
- **Photo import** uses the system photo picker and Files.
- **Incoming PSBTs** arrive through "Open in…" / the share sheet's "Copy to
  Bitcoin Vision" for `.psbt` files, where Android takes `SEND`/`VIEW` intents.
- **Screen protection**: iOS has no `FLAG_SECURE`; release builds cover the
  window outside the foreground instead.
- **Wallet storage** is one JSON file of public data (never the phrase) in the
  app's Application Support directory, written atomically.
- Android's debug-only emulator fixture route and capture-diagnostic flavour
  have no iOS counterpart.

## Licenses and assets

Project code and project-authored models use MIT OR Apache-2.0. Paddle/RapidOCR
models retain Apache-2.0; fonts retain their bundled OFL notices. These notices
are included in the app bundle under `licenses/`. The two IBM Plex faces serve the UI.
