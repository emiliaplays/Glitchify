# Source notes

## Included code

| File | Purpose |
| --- | --- |
| `reverse_bridge.c` | Chroma-local compatibility for the supplied player's state and track classes. |
| `hud_suppression.c` | App-local Metal performance-overlay suppression. |
| `stock_ui.c` | Disables the audited Chroma redesign preferences and performs the one-time native-lyrics source migration. |
| `settings_filter.c` | Filters conflicting redesign controls and unavailable paid/settings entries. |
| `haptics_pause_guard.c` | Coordinates the existing foreground music-haptics gate with recognized playing/paused state. |

The helpers contain binary identity checks and offsets for the exact supplied build. They are not generic patches for other Spotify or Chroma releases. Their release binary hashes are recorded in `release-manifest.json`.

The host tests exercise bounded parsing, identity checks, preference policies and mocked lifecycle/state callbacks. They do not execute ARM64 app code or prove physical iPhone behavior. The iPhone behavior was checked separately by the tester.

## Run the host tests

Use Linux or WSL with Python 3 and GCC or Clang installed. Supply your own local copy of the Glitchify IPA:

```sh
python3 run_host_tests.py --ipa /path/to/Glitchify.ipa
```

The runner extracts the needed Chroma binary as inert fixture data into a temporary directory, compiles the host tests with address/undefined-behavior sanitizers, runs them, and removes temporary files when finished. It does not upload the IPA or connect to an iPhone.

Use `--cc clang` to select Clang. If sanitizer runtimes are unavailable, `--no-sanitize` explicitly runs the same suites without ASan/UBSan; the default keeps both sanitizers enabled. All five suites passed against the released IPA with GCC and both sanitizers.

## Build scope

These are the helper sources and tests used during development. The original assembly scripts depended on supplied third-party IPAs, local cross-compilers, signing tools and intermediate builds. Those private working directories, SDK/tool binaries, crash logs, USB captures and obsolete test IPAs are not part of this repository.

The prebuilt release is the tested artifact. Compiling a helper with a different toolchain does not promise a byte-identical release binary; preparing and signing an entire IPA also requires the matching third-party inputs. Do not treat this source inventory as a complete source-only rebuild recipe.

## Artwork

`logo.png` is the selected opaque master artwork. It was generated with ImageGen from the tester's reference: the classic circular Spotify symbol with exactly three black curved bands, pastel lavender/pink/cyan coloring, black background, and horizontal digital glitch fragments. The generated artwork was resized into the app's icon sizes without changing program code.
