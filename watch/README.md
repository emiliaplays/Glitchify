# Glitchify 1.1 development: native Watch speaker probe

**Experimental source and unsigned diagnostic only. This is not a working Spotify Watch player or a 1.1 release.** The first hardware target is Apple Watch Series 5 on watchOS 10.6.2. Neither installation nor speaker output has been confirmed on that device yet.

## What this prototype does

- Builds a native, single-target SwiftUI watchOS app, targeting watchOS 10.0 with device `arm64_32` and `arm64` slices.
- Plays a generated three-second local two-note WAV only when the user presses the test button.
- Uses Apple's WatchKit media player, which documents speaker fallback when no Bluetooth audio route is available.
- Runs its local test without contacting an iPhone, an account service, Spotify, or the network.
- Can be embedded under `Payload/Spotify.app/Watch/GlitchifyWatch.app` in a copy of the audited v1.0.0 IPA. The packager checks every original entry remains identical.

The source does not replace Spotify's existing iPhone WatchConnectivity delegate. The original iPhone application may still use its own WatchConnectivity implementation.

## Build and inspect

Use a Mac with Xcode 16.4 and XcodeGen 2.42+:

```sh
python3 -m unittest discover -s watch -p 'test_*.py' -v
python3 watch/prepare.py
xcodegen generate --spec watch/project.yml
xcodebuild -project watch/GlitchifyWatch.xcodeproj -scheme GlitchifyWatch \
  -configuration Release -sdk watchos -destination 'generic/platform=watchOS' \
  -derivedDataPath watch/build CODE_SIGNING_ALLOWED=NO \
  ARCHS='arm64_32 arm64' ONLY_ACTIVE_ARCH=NO build
python3 watch/package_probe.py --base /path/to/released/Glitchify.ipa \
  --watch-app watch/build/Build/Products/Release-watchos/GlitchifyWatch.app \
  --output watch/dist/Glitchify-1.1-speaker-probe-unsigned.ipa
```

The `Watch prototype (unsigned)` GitHub workflow performs these steps on a macOS runner. It produces short-lived Actions artifacts, not a public release. Version metadata `3.5.3` matches the existing iPhone container; `1.1-speaker-probe.1` is the diagnostic revision, not a newer upstream Spotify version.

## Installation gate

An unsigned Watch app cannot be installed as-is. The phone and Watch bundles require matching bundle identifiers, signatures and provisioning. If a signing tool changes the phone bundle ID, it must also update the Watch bundle ID and `WKCompanionAppBundleIdentifier` consistently. Development provisioning must include the target devices.

[Sideloadly 0.70.1 explicitly documents](https://sideloadly.io/changelog) retaining embedded WatchKit apps and re-signing them with updated bundle identifiers. It is therefore the first installation path to test using the existing signing account. Successful provisioning, transfer and launch of this particular single-target app on the paired Watch remain unverified. A Mac with Xcode and valid signing is the documented fallback. Do not remove the working phone app merely to troubleshoot Watch provisioning.

## Hardware checks, after successful signing and installation

1. Open **Glitchify Test** on the charged Watch. Take it off the charger for the audio test.
2. Disconnect Bluetooth headphones/speakers. Keep the app open and press **Testton abspielen**. The tone is finite and quiet; adjust normal device volume if necessary.
3. Record whether audio is actually audible from the Watch. A successful media completion callback alone does not prove the output route.
4. Repeat with the iPhone disconnected while leaving Watch networking settings available as appropriate. This local fixture itself needs no network.
5. Record separately what happens when lowering the wrist or leaving the app. Background playback is not promised by this diagnostic.

The app tries the visible WatchKit controller and then the root controller. If the SwiftUI host exposes neither, it reports a presentation error instead of pretending playback started. This must be checked on hardware.

## Remaining 1.1 work

- Verify Watch provisioning and installation through the paired iPhone.
- Verify Series 5 speaker output and the actual behavior when the display sleeps.
- Establish a supported independent Spotify audio source, authentication and playback implementation. A phone remote-control API or the phone's existing tweaks do not provide an audio decoder/stream for the Watch.
- Validate on newer Watch hardware before claiming Series 5-and-newer compatibility.

The old WatchKit media API is for complete local/downloaded files and short foreground media; it does not accept a live audio stream. Apple's normal long-form speaker support is limited to supported newer watches/watchOS versions. This probe does not solve that platform constraint.

## References

- [Apple: single-target watchOS applications](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit)
- [Apple: WatchKit media player and audio route](https://developer.apple.com/documentation/watchkit/wkinterfacecontroller/presentmediaplayercontroller(with:options:completion:))
- [Apple: audio session activation and newer speaker support](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:))
- [Apple: distributing to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
- [Spotify: Apple Watch support](https://support.spotify.com/us/article/spotify-on-apple-watch/)
