"""Offline regression tests using only synthetic IPAs and temporary files."""
from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
import wave
import zipfile


HERE = Path(__file__).resolve().parent


def load_local(name):
    spec = importlib.util.spec_from_file_location('watch_test_' + name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load_local('package_probe')
prepare = load_local('prepare')
ARM64 = 0x0100000C
ARM64_32 = 0x0200000C


def thin(cpu=ARM64_32, platform=4, minimum=(10 << 16), legacy=False):
    command = (struct.pack('<4I', 0x30, 16, minimum, minimum) if legacy
               else struct.pack('<6I', 0x32, 24, platform, minimum, minimum, 0))
    if cpu == ARM64_32:
        return struct.pack('<7I', 0xFEEDFACE, cpu, 0, 2, 1, len(command), 0) + command
    return struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, len(command), 0, 0) + command


def fat(parts=None, wide=False):
    parts = parts or [(ARM64_32, thin()), (ARM64, thin(ARM64))]
    stride = 32 if wide else 20
    result = bytearray(8 + stride * len(parts))
    struct.pack_into('>II', result, 0, 0xCAFEBABF if wide else 0xCAFEBABE, len(parts))
    for index, (cpu, part) in enumerate(parts):
        result.extend(b'\0' * (-len(result) % 16))
        offset = len(result)
        result.extend(part)
        entry = (struct.pack('>IIQQII', cpu, 0, offset, len(part), 4, 0) if wide
                 else struct.pack('>5I', cpu, 0, offset, len(part), 4))
        start = 8 + stride * index
        result[start:start + stride] = entry
    return bytes(result)


def watch_info():
    return {
        'CFBundleIdentifier': probe.WATCH_BUNDLE_ID,
        'CFBundleExecutable': 'GlitchifyWatch',
        'WKCompanionAppBundleIdentifier': probe.PHONE_BUNDLE_ID,
        'WKApplication': True,
        'WKRunsIndependentlyOfCompanionApp': True,
        'CFBundleShortVersionString': '3.5.3',
        'CFBundleVersion': '3.5.3',
        'CFBundleSupportedPlatforms': ['WatchOS'],
        'UIDeviceFamily': [4],
        'MinimumOSVersion': '10.0',
    }


class MachOTests(unittest.TestCase):
    def test_device_architectures_and_fat_formats(self):
        self.assertEqual(probe.watch_slices(thin()), ['arm64_32'])
        self.assertEqual(probe.watch_slices(thin(ARM64)), ['arm64'])
        for wide in (False, True):
            with self.subTest(fat64=wide):
                self.assertEqual(sorted(probe.watch_slices(fat(wide=wide))), ['arm64', 'arm64_32'])

    def test_legacy_watch_deployment_command(self):
        self.assertEqual(probe.watch_slices(thin(legacy=True)), ['arm64_32'])

    def test_other_platforms_rejected(self):
        for platform in (1, 2, 3, 6, 7, 9):  # Includes iOS and watchOS simulator.
            with self.subTest(platform=platform), self.assertRaises(ValueError):
                probe.watch_slices(thin(platform=platform))

    def test_newer_deployment_target_rejected_even_in_one_fat_slice(self):
        for version in ((10 << 16) | (1 << 8), 11 << 16):
            with self.subTest(version=version), self.assertRaises(ValueError):
                probe.watch_slices(fat([(ARM64_32, thin(minimum=version)), (ARM64, thin(ARM64))]))

    def test_older_device_deployment_is_allowed(self):
        self.assertEqual(probe.watch_slices(thin(minimum=9 << 16)), ['arm64_32'])

    def test_x86_device_platform_cannot_masquerade_as_watch(self):
        with self.assertRaisesRegex(ValueError, 'CPU'):
            probe.watch_slices(thin(cpu=0x01000007))

    def test_missing_platform_or_wrong_filetype_rejected(self):
        no_platform = struct.pack('<7I', 0xFEEDFACE, ARM64_32, 0, 2, 0, 0, 0)
        dylib = bytearray(thin()); struct.pack_into('<I', dylib, 12, 6)
        for value in (no_platform, dylib, b'not a Mach-O'):
            with self.subTest(value=bytes(value[:16])), self.assertRaises(ValueError):
                probe.watch_slices(bytes(value))

    def test_malformed_load_commands_rejected(self):
        cases = []
        for offset, value in ((16, 4097), (20, 999), (32, 0), (32, 999)):
            data = bytearray(thin()); struct.pack_into('<I', data, offset, value); cases.append(data)
        for index, data in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(ValueError):
                probe.watch_slices(bytes(data))

    def test_fat_table_bounds_rejected(self):
        too_many = struct.pack('>II', 0xCAFEBABE, 9)
        missing_entries = struct.pack('>II', 0xCAFEBABE, 2)
        out_of_bounds = bytearray(fat()); struct.pack_into('>I', out_of_bounds, 16, 0xFFFFFF00)
        for data in (too_many, missing_entries, out_of_bounds):
            with self.subTest(data=bytes(data[:20])), self.assertRaises(ValueError):
                probe.watch_slices(bytes(data))


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='glitchify-watch-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / 'GlitchifyWatch.app'; self.app.mkdir()
        self.info = watch_info(); self.write_info()
        (self.app / 'GlitchifyWatch').write_bytes(fat())
        (self.app / 'speaker-check.wav').write_bytes(b'synthetic test audio')
        (self.app / 'Resources').mkdir()
        (self.app / 'Resources' / 'fixture.txt').write_text('local fixture', encoding='utf-8')
        self.base = self.root / 'synthetic-base.ipa'
        self.output = self.root / 'synthetic-output.ipa'
        self.make_base()

    def write_info(self):
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))

    def make_base(self, phone_updates=None, extra=None):
        info = {'CFBundleIdentifier': probe.PHONE_BUNDLE_ID,
                'CFBundleShortVersionString': '3.5.3', 'CFBundleVersion': '3.5.3'}
        info.update(phone_updates or {})
        entries = {
            'Payload/Spotify.app/Info.plist': plistlib.dumps(info, fmt=plistlib.FMT_BINARY),
            'Payload/Spotify.app/Spotify': b'original signed phone executable\x00\xff',
            'Payload/Spotify.app/Frameworks/fixture.dylib': b'original library',
            'Payload/Spotify.app/_CodeSignature/CodeResources': b'original signature resource',
        }
        entries.update(extra or {})
        with zipfile.ZipFile(self.base, 'w') as archive:
            for name, data in entries.items():
                item = zipfile.ZipInfo(name, date_time=(2026, 1, 2, 3, 4, 6))
                item.create_system = 3
                item.external_attr = 0o100755 << 16
                item.compress_type = zipfile.ZIP_DEFLATED
                item.comment = b'preserve this entry'
                archive.writestr(item, data)

    def package_fixture(self, **options):
        # The production hash remains pinned. Only this synthetic fixture is trusted here.
        with mock.patch.object(probe, 'BASE_SHA256', probe.digest(self.base)), redirect_stdout(io.StringIO()):
            probe.package(self.base, self.app, self.output, **options)

    def extension_entries(self):
        entries = {probe.PLUGINS_PREFIX: b''}
        for index, root in enumerate(probe.PHONE_EXTENSION_ROOTS):
            entries[root] = b''
            entries[root + 'Info.plist'] = plistlib.dumps({
                'CFBundleIdentifier': probe.PHONE_BUNDLE_ID + f'.fixture{index}',
                'CFBundleExecutable': 'Extension',
            })
            entries[root + 'Extension'] = b'original extension executable' + bytes([index])
            entries[root + 'Resources/fixture.dat'] = b'extension resource'
        return entries

    def test_valid_companion_metadata(self):
        info, architectures = probe.validate_app(self.app)
        self.assertEqual(info, self.info)
        self.assertEqual(architectures, ['arm64', 'arm64_32'])

    def test_metadata_identity_companion_and_versions_rejected(self):
        invalid = {
            'CFBundleIdentifier': 'wrong.watch', 'WKCompanionAppBundleIdentifier': 'wrong.phone',
            'WKApplication': False, 'WKRunsIndependentlyOfCompanionApp': False,
            'CFBundleShortVersionString': '1.1', 'CFBundleVersion': '1',
            'WKWatchOnly': True, 'CFBundleSupportedPlatforms': ['WatchSimulator'],
            'UIDeviceFamily': [1],
        }
        for key, value in invalid.items():
            with self.subTest(key=key):
                self.info = watch_info(); self.info[key] = value; self.write_info()
                with self.assertRaises(ValueError): probe.validate_app(self.app)

    def test_missing_metadata_rejected(self):
        for key in ('CFBundleIdentifier', 'WKCompanionAppBundleIdentifier', 'WKApplication',
                    'WKRunsIndependentlyOfCompanionApp', 'CFBundleShortVersionString', 'CFBundleVersion', 'UIDeviceFamily'):
            with self.subTest(key=key):
                self.info = watch_info(); del self.info[key]; self.write_info()
                with self.assertRaises(ValueError): probe.validate_app(self.app)

    def test_plist_minimum_os_cannot_exclude_series5(self):
        for minimum in ('10.1', '11.0', 'garbage', None):
            with self.subTest(minimum=minimum):
                self.info = watch_info()
                if minimum is None: del self.info['MinimumOSVersion']
                else: self.info['MinimumOSVersion'] = minimum
                self.write_info()
                with self.assertRaises(ValueError): probe.validate_app(self.app)

    def test_missing_required_architecture_and_duplicate_slice_rejected(self):
        binaries = (thin(), thin(ARM64), fat([(ARM64_32, thin()), (ARM64_32, thin())]))
        for index, binary in enumerate(binaries):
            with self.subTest(index=index):
                (self.app / 'GlitchifyWatch').write_bytes(binary)
                with self.assertRaisesRegex(ValueError, 'BOTH'): probe.validate_app(self.app)

    def test_executable_path_escape_rejected(self):
        for name in ('', '../outside', '/outside'):
            with self.subTest(name=name):
                self.info['CFBundleExecutable'] = name; self.write_info()
                with self.assertRaises(ValueError): probe.validate_app(self.app)

    def test_missing_audio_rejected(self):
        (self.app / 'speaker-check.wav').unlink()
        with self.assertRaisesRegex(ValueError, 'audio'): probe.validate_app(self.app)

    def test_provisioning_profile_rejected(self):
        (self.app / 'embedded.mobileprovision').write_bytes(b'not a real profile')
        with self.assertRaisesRegex(ValueError, 'provisioning'): probe.validate_app(self.app)

    def test_original_entries_and_metadata_unchanged_and_additions_scoped(self):
        before = self.base.read_bytes()
        self.package_fixture()
        self.assertEqual(self.base.read_bytes(), before)
        with zipfile.ZipFile(self.base) as original, zipfile.ZipFile(self.output) as output:
            self.assertIsNone(output.testzip())
            for old in original.infolist():
                with self.subTest(name=old.filename):
                    new = output.getinfo(old.filename)
                    self.assertEqual(original.read(old), output.read(new))
                    for field in ('date_time', 'external_attr', 'create_system', 'comment', 'compress_type'):
                        self.assertEqual(getattr(old, field), getattr(new, field), field)
            expected_added = {probe.PREFIX + path.relative_to(self.app).as_posix()
                              for path in self.app.rglob('*') if path.is_file()}
            self.assertEqual(set(output.namelist()) - set(original.namelist()), expected_added)
        manifest = json.loads(self.output.with_suffix('.manifest.json').read_text())
        self.assertEqual(manifest['sha256'], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertTrue(manifest['original_entries_unchanged'])
        self.assertTrue(manifest['retained_original_entries_unchanged'])
        self.assertFalse(manifest['omit_phone_extensions'])
        self.assertEqual(manifest['removed_phone_extensions'], [])
        self.assertEqual(manifest['removed_entry_count'], 0)
        self.assertEqual(manifest['app_id_target_count'], 2)
        for flag in ('spotify_playback', 'device_installation_verified', 'speaker_verified', 'background_playback_verified'):
            self.assertIs(manifest[flag], False)
        self.assertEqual(manifest['watch_architectures'], ['arm64', 'arm64_32'])
        self.assertEqual(manifest['minimum_watchos'], '10.0')
        self.assertEqual(self.output.with_suffix('.ipa.sha256').read_text().split()[0], manifest['sha256'])

    def test_wrong_base_hash_rejected_without_output(self):
        with self.assertRaisesRegex(ValueError, 'Base IPA'):
            probe.package(self.base, self.app, self.output)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.output.with_suffix('.manifest.json').exists())

    def test_modified_base_rejected_after_auditing_fixture(self):
        accepted = probe.digest(self.base)
        with self.base.open('ab') as stream: stream.write(b'tamper')
        with mock.patch.object(probe, 'BASE_SHA256', accepted), self.assertRaisesRegex(ValueError, 'Base IPA'):
            probe.package(self.base, self.app, self.output)
        self.assertFalse(self.output.exists())

    def test_input_and_existing_output_never_overwritten(self):
        before = self.base.read_bytes()
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            probe.package(self.base, self.app, self.base)
        self.assertEqual(self.base.read_bytes(), before)
        self.output.write_bytes(b'existing output')
        with self.assertRaisesRegex(ValueError, 'overwrite'): self.package_fixture()
        self.assertEqual(self.output.read_bytes(), b'existing output')

    def test_existing_watch_bundle_rejected(self):
        self.make_base(extra={'Payload/Spotify.app/Watch/Other.app/Info.plist': b'existing'})
        with self.assertRaisesRegex(ValueError, 'Watch bundle'): self.package_fixture()
        self.assertFalse(self.output.exists())

    def test_wrong_phone_identity_rejected(self):
        self.make_base({'CFBundleIdentifier': 'wrong.phone'})
        with self.assertRaisesRegex(ValueError, 'phone bundle'): self.package_fixture()
        self.assertFalse(self.output.exists())

    def test_phone_and_watch_versions_must_match(self):
        for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
            with self.subTest(key=key):
                self.make_base({key: '99.0'})
                with self.assertRaises(ValueError): self.package_fixture()
                self.assertFalse(self.output.exists())

    def test_default_call_preserves_all_five_extensions(self):
        self.make_base(extra=self.extension_entries())
        self.package_fixture()  # Existing three-positional-argument API.
        with zipfile.ZipFile(self.base) as original, zipfile.ZipFile(self.output) as output:
            for name in original.namelist():
                self.assertEqual(output.read(name), original.read(name), name)
        manifest = json.loads(self.output.with_suffix('.manifest.json').read_text())
        self.assertEqual(manifest['app_id_target_count'], 7)
        self.assertEqual(manifest['removed_phone_extensions'], [])
        self.assertTrue(manifest['original_entries_unchanged'])

    def test_omit_extensions_removes_exact_known_scope_and_retains_every_other_byte(self):
        extensions = self.extension_entries()
        sentinels = {
            'Payload/Spotify.app/Resources/PlugIns-not-a-directory.txt': b'keep me',
            'Payload/Spotify.app/Resources/IntentsExtension.appex-not-a-bundle': b'keep me too',
            'Payload/Spotify.app/Frameworks/ExtensionSupport.framework/fixture': b'framework retained',
        }
        self.make_base(extra=extensions | sentinels)
        before = self.base.read_bytes()
        self.package_fixture(omit_phone_extensions=True)
        self.assertEqual(self.base.read_bytes(), before)
        with zipfile.ZipFile(self.base) as original, zipfile.ZipFile(self.output) as output:
            self.assertFalse(any('PlugIns' in name.split('/') for name in output.namelist()))
            self.assertEqual(set(original.namelist()) - set(output.namelist()), set(extensions))
            for old in original.infolist():
                if old.filename in extensions:
                    continue
                new = output.getinfo(old.filename)
                self.assertEqual(original.read(old), output.read(new), old.filename)
                for field in ('date_time', 'external_attr', 'create_system', 'comment', 'compress_type'):
                    self.assertEqual(getattr(old, field), getattr(new, field), old.filename)
            self.assertEqual(probe.bundle_roots(output.namelist()), {probe.PHONE_ROOT, probe.PREFIX})
            watch = plistlib.loads(output.read(probe.PREFIX + 'Info.plist'))
            self.assertEqual(watch['CFBundleIdentifier'], probe.PHONE_BUNDLE_ID + '.watchkitapp')
            self.assertEqual(watch['WKCompanionAppBundleIdentifier'], probe.PHONE_BUNDLE_ID)
        manifest = json.loads(self.output.with_suffix('.manifest.json').read_text())
        self.assertFalse(manifest['original_entries_unchanged'])
        self.assertTrue(manifest['retained_original_entries_unchanged'])
        self.assertEqual(manifest['removed_phone_extensions'], list(probe.PHONE_EXTENSION_ROOTS))
        self.assertEqual(manifest['removed_entry_count'], len(extensions))
        self.assertEqual(manifest['retained_original_entry_count'], 4 + len(sentinels))
        self.assertEqual(manifest['app_id_target_count'], 2)
        self.assertEqual({target['bundle_id'] for target in manifest['app_id_targets']},
                         {probe.PHONE_BUNDLE_ID, probe.WATCH_BUNDLE_ID})

    def test_omit_extensions_rejects_unknown_roots_and_orphan_files_before_output(self):
        for name in ('Unknown.appex/Info.plist', 'IntentsExtension.appex-backup/Info.plist',
                     'unrelated.txt'):
            with self.subTest(name=name):
                self.make_base(extra=self.extension_entries() | {probe.PLUGINS_PREFIX + name: b'keep'})
                with self.assertRaisesRegex(ValueError, 'Unknown phone PlugIns'):
                    self.package_fixture(omit_phone_extensions=True)
                self.assertFalse(self.output.exists())

    def test_omit_extensions_rejects_missing_known_root_or_metadata(self):
        cases = ({}, {name: data for name, data in self.extension_entries().items()
                      if not name.startswith(probe.PHONE_EXTENSION_ROOTS[-1])},
                 {name: data for name, data in self.extension_entries().items()
                  if name != probe.PHONE_EXTENSION_ROOTS[0] + 'Info.plist'})
        for index, entries in enumerate(cases):
            with self.subTest(index=index):
                self.make_base(extra=entries)
                with self.assertRaises(ValueError):
                    self.package_fixture(omit_phone_extensions=True)
                self.assertFalse(self.output.exists())

    def test_omit_extensions_rejects_unknown_target_nested_inside_known_root(self):
        self.make_base(extra=self.extension_entries() | {
            probe.PHONE_EXTENSION_ROOTS[0] + 'Resources/Unexpected.appex/Info.plist': b'unknown'})
        with self.assertRaisesRegex(ValueError, 'Unknown nested app or extension'):
            self.package_fixture(omit_phone_extensions=True)
        self.assertFalse(self.output.exists())

    def test_omit_extensions_rejects_plugins_elsewhere_in_base_or_watch(self):
        self.make_base(extra=self.extension_entries() | {
            'Payload/Spotify.app/Resources/PlugIns/Unknown.appex/Info.plist': b'unknown'})
        with self.assertRaisesRegex(ValueError, 'Unexpected PlugIns'):
            self.package_fixture(omit_phone_extensions=True)
        self.assertFalse(self.output.exists())
        self.make_base(extra=self.extension_entries())
        nested = self.app / 'PlugIns' / 'Unexpected.appex'
        nested.mkdir(parents=True)
        (nested / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'unexpected'}))
        with self.assertRaisesRegex(ValueError, 'must not contain any PlugIns'):
            self.package_fixture(omit_phone_extensions=True)
        self.assertFalse(self.output.exists())

    def test_omit_extensions_rejects_unexpected_app_target_outside_plugins(self):
        self.make_base(extra=self.extension_entries() | {
            'Payload/Other.app/Executable': b'unknown target without plist'})
        with self.assertRaisesRegex(ValueError, 'exactly the phone and Watch'):
            self.package_fixture(omit_phone_extensions=True)
        self.assertFalse(self.output.exists())

    def test_post_write_verification_rejects_silent_retained_content_change(self):
        self.make_base(extra=self.extension_entries())
        real_write = zipfile.ZipFile.writestr

        def corrupt_output(archive, name, data, *args, **kwargs):
            filename = name.filename if isinstance(name, zipfile.ZipInfo) else name
            if Path(archive.filename) == self.output and filename == probe.PHONE_ROOT + 'Spotify':
                data += b'unintended modification'
            return real_write(archive, name, data, *args, **kwargs)

        with mock.patch.object(zipfile.ZipFile, 'writestr', corrupt_output):
            with self.assertRaisesRegex(ValueError, 'Retained original entry changed'):
                self.package_fixture(omit_phone_extensions=True)
        self.assertFalse(self.output.with_suffix('.manifest.json').exists())

    def test_post_write_verification_rejects_silent_retained_entry_deletion(self):
        self.make_base(extra=self.extension_entries())
        real_write = zipfile.ZipFile.writestr

        def lose_output_entry(archive, name, data, *args, **kwargs):
            filename = name.filename if isinstance(name, zipfile.ZipInfo) else name
            if Path(archive.filename) == self.output and filename == probe.PHONE_ROOT + 'Spotify':
                return
            return real_write(archive, name, data, *args, **kwargs)

        with mock.patch.object(zipfile.ZipFile, 'writestr', lose_output_entry):
            with self.assertRaisesRegex(ValueError, 'Output entry set differs'):
                self.package_fixture(omit_phone_extensions=True)
        self.assertFalse(self.output.with_suffix('.manifest.json').exists())


class AudioFixtureTests(unittest.TestCase):
    def test_tone_is_local_finite_quiet_and_has_silent_gaps(self):
        with tempfile.TemporaryDirectory(prefix='glitchify-tone-test-') as directory:
            path = Path(directory) / 'speaker-check.wav'
            prepare.make_tone(path)
            with wave.open(str(path), 'rb') as audio:
                self.assertEqual((audio.getnchannels(), audio.getsampwidth(), audio.getframerate()), (1, 2, 22050))
                self.assertEqual(audio.getnframes(), 3 * 22050)
                self.assertEqual(audio.getcomptype(), 'NONE')
                data = audio.readframes(audio.getnframes())
            samples = struct.unpack('<' + 'h' * (len(data) // 2), data)
            self.assertGreater(max(abs(sample) for sample in samples), 0)
            self.assertLessEqual(max(abs(sample) for sample in samples), 3276)
            self.assertEqual(samples[0], 0)
            self.assertEqual(samples[-1], 0)
            self.assertTrue(all(sample == 0 for sample in samples[22050:int(1.75 * 22050)]))
            self.assertTrue(all(sample == 0 for sample in samples[int(2.75 * 22050):]))


if __name__ == '__main__':
    unittest.main(verbosity=2)
