# Glitchify 1.1 development: Watch audio receiver experiments

**Experimental source and unsigned diagnostic only; not a 1.1 release.** The phone PCM observer and synthetic WLAN receiver have been tested separately on hardware. The newly added paired music relay still requires its end-to-end hardware test. The local speaker test works on Series 5 / watchOS 10.6.2, including with the iPhone switched off; the relay requires the phone to remain on.

## Paired 20-second music relay test

`1.1-phone-relay-probe.1` connects the observed phone audio output to the Watch receiver. The phone serves one finite 20-second, 24 kHz mono PCM response over TLS on Wi-Fi port 8766. The render callback only downmixes/downsamples into a bounded single-producer ring; network work runs separately. Pause emits silence, excess backlog ends the test, and the server window expires after 170 seconds from phone app launch. This is a foreground experiment with reduced volume and preview-quality downsampling, not a continuous or background player.

The public artifact contains no pairing credentials and does not start a server. Run `local_pair_relay.py` locally with `--source` and `--output` to create a **private test copy**, optionally using `--phone-host` for the iPhone's private IPv4 address. The script requires Python `cryptography`, creates a fresh access key and a one-day TLS identity, and gives the Watch only the private CA's public certificate and the access key. The Watch validates the TLS chain, validity and fixed server identity against that app-local anchor; no device trust-store changes are needed. **Never publish the paired IPA, its identity or its keys.** Both targets then require local re-signing.

Open Glitchify on the iPhone, allow its requested local-network access, and start a song. On the Watch enter the iPhone address and press **iPhone-Musik testen** within the three-minute window. Keep both apps open for this first test. Watch Stop, leaving the Watch app, timeout and audio interruption cancel the request. The earlier synthetic WLAN and local-file tests remain available. A successful build does not establish audible relay playback; that remains the next hardware gate.

## What this prototype does

- Builds a native, single-target SwiftUI watchOS app, targeting watchOS 10.0 with device `arm64_32` and `arm64` slices.
- Plays a generated three-second local two-note WAV only when the user presses the test button.
- Uses Apple's WatchKit media player, which documents speaker fallback when no Bluetooth audio route is available.
- Runs its local test without contacting an iPhone, an account service, Spotify, or the network.
- Can be embedded under `Payload/Spotify.app/Watch/GlitchifyWatch.app` in a copy of the audited v1.0.0 IPA. The packager checks every original entry remains identical.

The earlier `1.1-stream-route-probe.1` revision added a separate **Audioausgabe testen** button. It schedules a finite ten-second quiet PCM signal through `AVAudioEngine` and `AVAudioPlayerNode`, using the normal playback/default audio policy. At most four quarter-second buffers are queued. It reports the actual output route and stops on cancellation, backgrounding, interruption, or a route change. The existing WatchKit file test remains available as a comparison.

The tester confirmed audible output from this ten-second direct-output test on Series 5 / watchOS 10.6.2 on October 14. The exact displayed route is still pending. A completed callback alone is not proof that sound was audible.

## Current WLAN receiver test

Revision `1.1-lan-receiver-probe.1` adds **WLAN-Ton testen**. It receives one paced HTTP response incrementally with `URLSessionDataDelegate` and schedules PCM while the response is still arriving. It accepts only private IPv4 addresses, port 8765, the fixed test endpoint, the exact PCM header and a 960,000-byte response. Redirects are rejected. The receiver limits its own byte buffer to 64 KiB and its scheduled PCM to four 100 ms buffers. A thirty-second deadline, eight-second stall timeout, Stop, backgrounding and audio-route/interruption handling end playback and cancel the request. It does not download a file for later playback or loop clips.

Run `python3 watch/lan_test_server.py --bind YOUR_PRIVATE_IPV4` on a computer reachable in the same WLAN. The server binds only that address, serves only synthetic audio, expires after five minutes, and changes no firewall settings. Enter its IPv4 address on the Watch and press **WLAN-Ton testen**. There are quiet changing tones and a silent interval every fifth second. Confirm both audible output and **Start während der Übertragung bestätigt**, then test Stop and leaving the app. A later test with iPhone Bluetooth disconnected is needed to distinguish a direct Watch Wi-Fi path from watchOS proxying through the paired phone.

On October 14, the tester confirmed audible changing tones and **Start während der Übertragung bestätigt** on Series 5 / watchOS 10.6.2. An initial test after disabling iPhone Bluetooth returned -1009; the tester subsequently reported that WLAN audio now works. This is user-reported foreground playback, not a packet trace or proof of background operation.

The receiver still has **no Spotify relay, authentication for personal music, or background playback**. The computer's finite, synthetic source tests the receiver before integrating the phone source. No local address or personal signing data is committed to this repository.

## Opt-in phone PCM diagnostic

`1.1-phone-pcm-probe.1` adds a separate iPhone helper for a three-minute observation window after each app launch. It records only format, frame counts, silence/error counts and a signal-level measurement in the app's cache. It does not save or transmit audio, read account data, change audio-session categories, enable microphone input, or replace a render callback.

The helper validates the pinned phone/Chroma image identities, import symbols and existing Chroma audio-hook pointers before changing three main-image import pointers. It forwards each existing start/stop/dispose implementation once and adds only its own post-render listener. Unsupported formats, format changes and concurrent callbacks are rejected. Static callback contexts are never freed or reused during the process, and the render callback uses no allocations, locks, Objective-C calls or I/O. These are implementation safeguards; preserving phone playback and haptics still requires a device test.

The packaging step adds one helper, an explicit Info.plist opt-in, and one dependency in Chroma's unused load-command padding. It verifies all other archive entries and executable sections are unchanged. Recursive signing is required. The stable release remains unchanged. On October 14 the observer reported valid 44.1 kHz stereo planar float PCM, two starts and one stop, with no rejected buffers or listener errors. The tester confirmed normal play/pause/resume. No audio was saved or transmitted during that observer test. The complete music relay remains unverified.

## Intended same-WLAN receiver

The requested direction is now to leave Spotify and Eevee on the iPhone and send its rendered audio to the Watch over the same reachable WLAN. The iPhone would have to remain powered on and running playback; Bluetooth proximity would not be a transport requirement. This is distinct from independent Spotify playback with the phone off.

The continuous synthetic HTTP response has been heard before completion on the tester's Watch, and the additive phone observer subsequently reported valid PCM while preserving tested play/pause/resume. The next gate is audible end-to-end playback through the paired TLS relay. No microphone recording or cloud relay is part of this experiment. Phone background availability and Watch background speaker playback remain separate tests.

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
  --output watch/dist/Glitchify-1.1-lan-receiver-probe-unsigned.ipa
```

The `Watch paired phone audio relay test (unsigned)` GitHub workflow performs these Watch steps and additionally compiles, ad-hoc signs and embeds the opt-in phone observer on a macOS runner. It produces short-lived Actions artifacts, not a public release. Version metadata `3.5.3` matches the existing iPhone container; `1.1-lan-receiver-probe.1` is the Watch diagnostic revision, not a newer upstream Spotify version. The optional `--omit-phone-extensions` switch removes exactly the known five phone extensions for a two-App-ID diagnostic; without it, every original phone entry is preserved.

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
- Establish the actual same-WLAN audio relay: synthetic incremental network playback is confirmed by the tester; the new paired TLS path and pause/seek/route-change handling for real audio require end-to-end verification.
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

