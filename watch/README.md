# Glitchify 1.1 development: Watch audio receiver experiments

**Experimental source and unsigned diagnostic only. This is not a working Spotify Watch player or a 1.1 release.** Installation and audible local speaker output were confirmed on Apple Watch Series 5 / watchOS 10.6.2 on October 14, 2026. The tester also confirmed that the bundled tone plays with the iPhone completely switched off.

## What this prototype does

- Builds a native, single-target SwiftUI watchOS app, targeting watchOS 10.0 with device `arm64_32` and `arm64` slices.
- Plays a generated three-second local two-note WAV only when the user presses the test button.
- Uses Apple's WatchKit media player, which documents speaker fallback when no Bluetooth audio route is available.
- Runs its local test without contacting an iPhone, an account service, Spotify, or the network.
- Can be embedded under `Payload/Spotify.app/Watch/GlitchifyWatch.app` in a copy of the audited v1.0.0 IPA. The packager checks every original entry remains identical.

The current `1.1-stream-route-probe.1` revision adds a separate **Audioausgabe testen** button. It schedules a finite ten-second quiet PCM signal through `AVAudioEngine` and `AVAudioPlayerNode`, using the normal playback/default audio policy. At most four quarter-second buffers are queued. It reports the actual output route and stops on cancellation, backgrounding, interruption, or a route change. The existing WatchKit file test remains available as a comparison.

This new direct-output path is unconfirmed on hardware. It uses neither the microphone nor the network and does not relay Spotify yet. A completed callback is not proof that sound was audible through the built-in speaker.

## Intended same-WLAN receiver

The requested direction is now to leave Spotify and Eevee on the iPhone and send its rendered audio to the Watch over the same reachable WLAN. The iPhone would have to remain powered on and running playback; Bluetooth proximity would not be a transport requirement. This is distinct from independent Spotify playback with the phone off.

The next gates are direct foreground speaker output on Series 5, a continuous HTTP audio response played before the response ends, then a bounded capture of the iPhone's rendered audio. Initial static inspection found Chroma's existing RemoteIO post-render observation as a capture candidate; usable PCM and an additive observer preserving phone playback/haptics are not yet verified. No microphone recording, cloud relay, or protection changes are part of this experiment. Phone background availability and Watch background speaker playback remain separate tests.

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
  --omit-phone-extensions \
  --output watch/dist/Glitchify-1.1-stream-route-probe-unsigned.ipa
```

The `Watch audio route prototype (unsigned)` GitHub workflow performs these steps on a macOS runner. It produces short-lived Actions artifacts, not a public release. Version metadata `3.5.3` matches the existing iPhone container; `1.1-stream-route-probe.1` is the diagnostic revision, not a newer upstream Spotify version. The optional `--omit-phone-extensions` switch removes exactly the known five phone extensions for a two-App-ID diagnostic; without it, every original phone entry is preserved.

## Installation gate

An unsigned Watch app cannot be installed as-is. The phone and Watch bundles require matching bundle identifiers, signatures and provisioning. If a signing tool changes the phone bundle ID, it must also update the Watch bundle ID and `WKCompanionAppBundleIdentifier` consistently. Development provisioning must include the target devices.

The first Sideloadly attempt transferred the app but failed on the Watch with `0xe8008015` (no valid provisioning profile for the executable). On October 14, a locally patched experimental iLoader build on Windows successfully provisioned and installed a separate minimal diagnostic using a free Apple ID. The installer reported `InstallComplete`, and the tester launched the app and heard its tone through the Watch speaker.

That successful test used a two-target package: the phone app and a Watch app whose identifier is the phone identifier plus `.watchkitapp`. Five phone extensions were omitted from this diagnostic to reduce App-ID use. The original release IPA is unchanged. The current workflow uses that same two-target layout. This one-device result is not confirmation that stock iLoader or Sideloadly can reproduce the installation.

Watch Developer Mode was enabled by the tester. The local signer included aggregate App-ID quota preflight, separate Watch provisioning, and a one-time certificate creation path for an account without existing iOS signing certificates. It did not bypass signature verification. No personal signing material is included in this repository.

## Hardware checks, after successful signing and installation

For the new direct-output gate, open **Glitchify Test**, disconnect Bluetooth audio, press **Audioausgabe testen**, and keep the app open for ten seconds. Record both the displayed route and whether the tone was audible. A second run should stop immediately with **Test stoppen**. The older **Testton abspielen** button tests the already-confirmed file-player path and cannot validate this new path.

For the original file test:

1. Open **Glitchify Test** on the charged Watch. Take it off the charger for the audio test.
2. Disconnect Bluetooth headphones/speakers. Keep the app open and press **Testton abspielen**. The tone is finite and quiet; adjust normal device volume if necessary.
3. Record whether audio is actually audible from the Watch. A successful media completion callback alone does not prove the output route.
4. Repeat with the iPhone disconnected while leaving Watch networking settings available as appropriate. This local fixture itself needs no network.
5. Record separately what happens when lowering the wrist or leaving the app. Background playback is not promised by this diagnostic.

The app tries the visible WatchKit controller and then the root controller. If the SwiftUI host exposes neither, it reports a presentation error instead of pretending playback started. This must be checked on hardware.

## Remaining 1.1 work

- Verify longer local playback and the actual behavior when the display sleeps or the app leaves the foreground. The successful three-second test does not establish either behavior.
- Establish the actual same-WLAN audio relay: direct output, incremental network playback, bounded phone PCM observation, pairing/access control and pause/seek/route-change handling. The current probe implements none of the phone/network stages yet.
- An independent Spotify player with the phone off would still need its own audio source and authentication; that is not provided by the relay design.
- Validate on newer Watch hardware before claiming Series 5-and-newer compatibility.

Confirmed so far: Windows provisioning and installation through the paired iPhone, foreground speaker output on Series 5, and replay of the bundled local tone with the iPhone completely switched off. Audible output and the disconnected-iPhone test are tester reports; installation completion is also present in the installer log. The signed profiles were structurally inspected, but this inspection was not a separate cryptographic signature verification or independent device-identifier match.

The old WatchKit media API is for complete local/downloaded files and short foreground media; it does not accept a live audio stream. Apple's normal long-form speaker support is limited to supported newer watches/watchOS versions. This probe does not solve that platform constraint.

## References

- [Apple: single-target watchOS applications](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit)
- [Apple: WatchKit media player and audio route](https://developer.apple.com/documentation/watchkit/wkinterfacecontroller/presentmediaplayercontroller(with:options:completion:))
- [Apple: audio session activation and newer speaker support](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:))
- [Apple: distributing to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
- [Spotify: Apple Watch support](https://support.spotify.com/us/article/spotify-on-apple-watch/)
