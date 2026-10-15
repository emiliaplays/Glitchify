# Glitchify 1.1: Watch + Windows prerelease candidate

Spotify and Eevee run on the iPhone. The native Watch app receives rendered music over the same reachable Wi-Fi network and plays it through the Watch's selected output. The phone must be powered on and playing. This is a relay, not standalone Spotify on watchOS.

## Revision .3

- Native Watch player with title/artist, progress, previous/play/pause/next controls, connection page and diagnostics.
- Digital Crown adjusts local Watch volume from 0 to 100%; the saved value does not change phone volume.
- Audio background mode is enabled. The receiver belongs to the app independently of its visible page. Real music no longer explicitly stops when the display dims or the app backgrounds. The default audio route policy preserves the tested speaker route. Screen-off/background speaker operation on Series 5 still needs a hardware test.
- The phone observer uses the output-bus format for post-render samples. Using the input rate could cause slow pitch and excessive backlog trimming when the actual output rate differed.
- Windows receives separate left/right channels as 48 kHz stereo PCM16. Watch retains 24 kHz downmixed mono. At a 48 kHz source the stereo path does no sample-rate conversion; other rates use a bounded preview-quality resampler.
- Small Windows receiver: manual iPhone IP, optional saved address, local pause, volume and stereo WAV recording. No bundled pairing credentials.

## Hardware evidence

The Series 5 / watchOS 10.6.2 tester confirmed two minutes of music, iPhone pause/resume, Watch Stop and reconnect with revision .2. Windows reception was audible, but the tester reported slow/different audio. Counters showed roughly 48,000 rendered frames per second while the observer used 44,100 Hz; revision .3 addresses that mismatch.

Stereo separation, 48 kHz test-tone pitch/duration, fractional conversion, bounded ring recovery, control request authentication/framing and Windows stereo WAV/TLS/audio tests pass locally. Revision .3 hardware confirmation is pending: sound speed, remote commands, Crown volume and screen-off playback must be tested. Building both Watch architectures does not establish compatibility with every newer model.

## Pair locally before installing

Public artifacts contain no identity or pairing token and do not start a relay server. Python 3.10+ and cryptography are required:

```sh
python -m pip install cryptography
python local_pair_relay.py --source Glitchify-Watch-Test-unsigned.ipa --output Glitchify-private.ipa
```

In the source tree, the script is watch/local_pair_relay.py. Each invocation creates fresh random credentials shared only by that private iPhone/Watch package. The TLS identity lasts one day. Recreate from the public unsigned IPA, sign and reinstall when it expires. Never publish the paired IPA, identity, Apple profiles or credentials. Public downloads cannot use the maintainer's pairing.

Sign BOTH app targets for your own devices. The Watch bundle identifier must be the signed phone identifier plus .watchkitapp; WKCompanionAppBundleIdentifier must match the phone. A custom experimental Windows iLoader successfully provisioned this two-target build with a free Apple ID. Stock Sideloadly did not supply the Watch profile in our test. Use a signing workflow that supports Watch provisioning, such as an appropriately configured Xcode workflow; phone-only installation is insufficient. Development signing may also require Developer Mode on the Watch. No signing certificates or profiles are included.

The package omits the five audited phone extensions to keep two app targets. Stable v1.0.0 is unchanged. Version metadata 3.5.3 belongs to the original phone container; GlitchifyPrototypeRevision identifies the test revision.

## Connect the Watch

1. Open Glitchify on the iPhone, allow its Local Network request and start a song.
2. Find the phone's IPv4 address in Settings > Wi-Fi > information for the connected network.
3. Open Glitchify Test on the Watch. Swipe to Connection, enter the iPhone IP and connect. Both devices must reach one another on the same local network.
4. On the player, turn the Crown for local volume. Previous/next/play/pause control the phone. Commands are sent once; unavailable controls or unconfirmed commands are shown.
5. **Empfang stoppen** on Connection disconnects Watch audio. Pause on the player pauses the iPhone instead.
6. To test background audio, establish audible playback, lower the wrist for two minutes, then return to the watch face with the Crown and test again.

One audio receiver at a time. Stop Watch reception before connecting Windows. Audio uses TLS TCP 8766; bounded status/control requests use TLS TCP 8767 with the same private pairing. Keep these services on the local network. Commands require the phone process to own Now Playing and the private MediaRemote API to be available; support is experimental and must be checked on each iOS version.

## Windows

Install .NET 8 Windows Desktop Runtime, unpack the Windows ZIP and start Glitchify Audio.exe. Import your own paired IPA before signing, then enter the iPhone IP. The optional **IP-Adresse speichern** checkbox restores the address on future launches; otherwise the input starts blank. Pause affects PC output only. Enable WAV recording before connecting. Recording is 48 kHz stereo PCM16, unaffected by PC volume and continuing through local pause. Stop finalizes the file. A bounded buffer may skip old audio after a network stall rather than accumulate delay.

Chroma settings on iPhone remain under **Spotify Settings > Account > Mod Settings**.

## Build

The GitHub workflow builds the arm64 iPhone helper and arm64_32 / arm64 Watch slices with Xcode 16.4. It runs packaging checks, Swift buffer tests and C audio/control tests under sanitizers. Independent archive checks compare retained phone entries, all 52 Chroma sections and its original text seal. Public artifacts must contain no pairing resources.

References: [Apple output-bus sample rates](https://developer.apple.com/library/archive/qa/qa1777/_index.html), [Apple background audio](https://developer.apple.com/documentation/watchkit/playing-background-audio), [OnePlayer speaker feature](https://oneplayer.cn/guide/watch_guide/watch-speaker.html), [MediaRemote declarations](https://github.com/theos/headers/blob/master/MediaRemote/MediaRemote.h). OnePlayer is a behavior reference; its implementation is not copied.
