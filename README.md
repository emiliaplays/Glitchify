<p align="center"><img src="logo.png" width="180" alt="Glitchify pastel glitch icon"></p>

# Glitchify

A Spotify iOS build combining Eevee integration, the standard Spotify interface, lyrics, and music haptics, with a pastel glitch icon.

**[Download the latest release](https://github.com/emiliaplays/Glitchify/releases/latest)**

## What works in this release

- Standard Spotify Home, library and player, with the conflicting Chroma redesign disabled.
- Eevee integration and settings, including song selection, skipping and disabling shuffle.
- Lyrics in the normal player, using LRCLIB as the default source when the previous source was disabled or missing.
- Foreground and background music haptics. Foreground vibration now stops when playback is paused.
- Hidden developer performance overlay and filtered unavailable Chroma settings/purchase entries.
- Glitchify app name and pastel glitch artwork.

This release does not unlock Chroma Plus. Filtering unavailable settings does not enable paid or server-backed services. Lyrics depend on the selected provider's coverage and network access.

## Install

1. Download **Glitchify.ipa** from [Releases](https://github.com/emiliaplays/Glitchify/releases/latest).
2. Optionally compare its SHA-256 with **Glitchify.ipa.sha256** from the same release.
3. Sign and install the IPA with [Sideloadly](https://sideloadly.io/) using your own signing account.
4. Launch Glitchify. For system music haptics, enable **Settings → Accessibility → Music Haptics** on your iPhone.

**Chroma settings are located inside the app under Spotify Settings → Account → Mod Settings.**

The release does not include a personal provisioning profile. Signing and certificate renewal remain the installer's responsibility. The existing bundle identifier is retained, so this can replace an installation that uses the same identifier; it is not configured as a separate side-by-side app.

## Tested configuration

The final branded build was confirmed working by its tester on **iOS 27.2 with Sideloadly** on October 14, 2026. This is one tested configuration, not a compatibility claim for every iPhone or iOS version.

The functional basis is the tested `reverse-v9-haptics-pause` build. Branding changes only the main bundle's name/icon metadata and adds icon PNGs; all 20 Mach-O files remain byte-identical to that basis. The internal compatibility revision and upstream version metadata are intentionally retained. The release tag `v1.0.0` identifies Glitchify's release, not a newer Spotify binary.

## Source and tests

This repository contains the five custom compatibility helpers and their host tests. It is **not** the full source code of Spotify, Chroma or EeveeSpotify, and it does not provide a complete source-only rebuild of those third-party applications.

See [SOURCE_NOTES.md](SOURCE_NOTES.md) for the module inventory and test instructions, [release-manifest.json](release-manifest.json) for hashes, and [CHANGELOG.md](CHANGELOG.md) for this release's scope.

## Credits

- [Spotify](https://www.spotify.com/) — base application and original symbol.
- [EeveeSpotify / whoeevee](https://github.com/whoeevee/EeveeSpotifyReborn) — Eevee functionality and lyrics integration.
- [Chroma](https://chroma.pw/) — the supplied modification's haptics and related features.
- [LRCLIB](https://lrclib.net/) — lyrics source.
- [Sideloadly](https://sideloadly.io/) — the tested signing/installation tool.

Glitchify is an independent customization project and is not affiliated with or endorsed by these projects. Third-party components retain their respective notices and licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Reporting a problem

Open an issue here with the Glitchify release, iOS version, installation method and steps to reproduce. State whether it involves playback, lyrics, the interface or haptics. Remove account details and device identifiers from any logs or screenshots before attaching them. Problems specific to this combined build should be reported here rather than attributed to an unmodified upstream project.
