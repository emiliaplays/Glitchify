# Glitchify 1.1: paired iPhone-to-Watch audio

Experimental development branch; not a v1.1 release. Spotify and Eevee remain on the iPhone. The native Watch app receives the phone's rendered audio over the same reachable WLAN and plays it through its selected audio output. The iPhone must remain powered on and playing; this is not an independent Spotify player.

## Hardware evidence

On October 14, the Series 5 / watchOS 10.6.2 tester confirmed audible music from the paired TLS relay, including pause and resume from the iPhone. The counters recorded valid 44.1 kHz stereo float source audio. An earlier attempt stopped at 66 transmitted chunks because its 0.68-second source ring filled; audible playback alone therefore did not establish a complete 20-second transfer.

Earlier local-file, direct PCM and synthetic WLAN tests also produced speaker audio. The local file worked with the phone switched off. After an initial Bluetooth-off network error, the tester reported WLAN audio working; no independent packet trace was taken. Continuous music and background operation remain hardware gates.

## Current revision: 1.1-phone-relay-probe.2

The new revision replaces the 20-second response and three-minute launch window with a live, chunked HTTP response over TLS. Sending runs on its own serial queue, separately from the phone UI. A bounded single-producer ring holds at most 65,536 mono samples; a delayed consumer resumes from recent samples instead of terminating on the first overflow. The Watch also bounds its receive and scheduled-audio buffers, preserving PCM sample alignment when discarding an old backlog. Such recovery can cause an audible gap; counters expose resynchronization and underflow.

The Watch has a **Musik empfangen** button, an immediately visible **Wiedergabe stoppen** button, output-route and elapsed-playback status. The receiver cancels on Stop, leaving the Watch app, audio interruption, route change or an eight-second network stall. A connection has a twelve-hour upper limit. The phone captures only while a paired receiver is connected; disconnect cancels capture. Pause emits silence. Phone playback is not muted by this prototype.

Audio is 24 kHz mono PCM16 with preview-quality downsampling and reduced Watch gain. No microphone, account-data access, cloud relay, audio recording or changes to the phone's render callback are added. The source observer preserves the existing Chroma audio chain. Phone background availability and Watch background speaker playback require separate hardware tests; keep both apps open for the first longer-playback test.

## Local pairing and installation

The public artifact contains no pairing credentials and starts no relay server. Create a private copy locally:

```sh
python3 watch/local_pair_relay.py --source /path/to/unsigned.ipa \
  --output /path/to/private-test.ipa --phone-host YOUR_PRIVATE_IPHONE_IPV4
```

The script requires Python `cryptography`. It creates a fresh access key and a one-day TLS identity, and embeds only the CA public certificate and access key in the Watch target. The Watch checks the certificate chain, expiry and fixed server identity against its app-local trust anchor. No system trust-store changes are needed. **Never publish the paired IPA, its identity or its keys.** Re-create and re-sign this development copy when its one-day identity expires.

Both targets require local signing with matching identifiers and device provisioning. The Watch bundle identifier must be the signed phone identifier plus `.watchkitapp`, and `WKCompanionAppBundleIdentifier` must match the phone. An experimental Windows iLoader build has successfully installed the two-target package using a free Apple ID; stock Sideloadly initially failed with a missing Watch profile. This is not a guarantee that stock signing tools support this layout.

The diagnostic omits exactly the previously audited five phone extensions to fit the two-App-ID layout. Stable v1.0.0 remains unchanged. No certificates, provisioning profiles, personal addresses, device logs or paired test IPAs belong in this repository.

## Longer-playback check

1. Open Glitchify on the iPhone, permit its local-network access and start music.
2. On the Watch, open Glitchify Test, enter the phone's private IPv4 address if needed and select **Musik empfangen**.
3. Keep both apps open for two minutes. Check audible output, increasing elapsed playback, and any gaps.
4. Pause for five seconds and resume on the iPhone, then use Watch **Wiedergabe stoppen**. Confirm silence and that a fresh connection can start.
5. Test phone lock/background, Watch display sleep, Wi-Fi loss/reconnection and other Watch models separately. None is implied by a successful foreground test.

The previous synthetic twenty-second WLAN test, ten-second PCM test and three-second WatchKit file test remain available for diagnosis.

## Build and verification

The GitHub workflow uses Xcode 16.4 on macOS, compiles the phone helper with strict warnings and ad-hoc signature verification, and builds both Watch `arm64_32` and `arm64` slices for watchOS 10+. It runs 42 packaging tests, Swift endpoint/buffer checks and C bounds/resampler/concurrent-ring checks with AddressSanitizer and UndefinedBehaviorSanitizer. Actions artifacts are temporary unsigned test builds, not releases.

Local packaging independently compares retained phone files, all 52 Chroma sections and its existing text seal, and checks exactly two app targets. Version metadata `3.5.3` matches the existing iPhone container; the `GlitchifyPrototypeRevision` field distinguishes Watch diagnostic revisions.

```sh
python3 -m unittest discover -s watch -p 'test_*.py' -v
swiftc watch/LANPCMBuffer.swift watch/LANPCMBufferTests.swift -o /tmp/lan-tests
/tmp/lan-tests
clang -std=c11 -Wall -Wextra -Werror -pthread -fsanitize=address,undefined \
  watch/PhoneRelayCoreTests.c -o /tmp/relay-tests
/tmp/relay-tests
```

## Remaining release gates

- Verify sustained music, stop/restart and recovery with the current revision on hardware.
- Establish phone background behavior and Watch speaker behavior when its screen sleeps.
- Replace the development pairing/one-day identity process with a usable pairing flow.
- Verify newer Watch models before claiming Series 5-and-newer compatibility.

## References

- [Apple: single-target watchOS applications](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit)
- [Apple: Network connection queues](https://developer.apple.com/documentation/network/nwconnection/queue)
- [Apple: local-network TLS identities](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)
- [Apple: audio session activation](https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:))
- [Apple: resource timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource)
- [Apple: distributing to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
