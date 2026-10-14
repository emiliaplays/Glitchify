"""Add a verified, unsigned watchOS probe to a COPY of the released iPhone IPA.

This is an installation/audio diagnostic, not the Glitchify 1.1 release.
It never rewrites the original IPA or the existing iPhone program files.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import re
import struct
import zipfile

BASE_SHA256 = '48f708090a7ab31945d8733bc97e2e2fd2a19c07bdc1cfc1e9d3818489e3e572'
WATCH_BUNDLE_ID = 'com.spotify.client.glitchifywatch'
PHONE_BUNDLE_ID = 'com.spotify.client'
PREFIX = 'Payload/Spotify.app/Watch/GlitchifyWatch.app/'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def watch_slices(data):
    """Require device Mach-O slices, watchOS platform and deployment <=10.0."""
    magic = data[:4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count, = struct.unpack_from('>I', data, 4)
        stride = 32 if magic[-1] == 0xbf else 20
        if count > 8 or 8 + count * stride > len(data):
            raise ValueError('Invalid fat Mach-O header')
        parts = []
        for i in range(count):
            entry = 8 + stride * i
            offset, size = struct.unpack_from('>QQ' if stride == 32 else '>II', data, entry + 8)
            if offset + size > len(data):
                raise ValueError('Mach-O slice exceeds file')
            parts.extend(watch_slices(data[offset:offset + size]))
        return parts
    header_size = {b'\xce\xfa\xed\xfe': 28, b'\xcf\xfa\xed\xfe': 32}.get(magic)
    if header_size is None or len(data) < header_size:
        raise ValueError('Expected a little-endian Mach-O watch executable')
    cpu, _, filetype, ncmds, sizeofcmds = struct.unpack_from('<IIIII', data, 4)
    if filetype != 2 or header_size + sizeofcmds > len(data) or ncmds > 4096:
        raise ValueError('Invalid Mach-O executable/load commands')
    pos = header_size
    platform = version = None
    for _ in range(ncmds):
        if pos + 8 > header_size + sizeofcmds:
            raise ValueError('Truncated load command')
        command, size = struct.unpack_from('<II', data, pos)
        if size < 8 or pos + size > header_size + sizeofcmds:
            raise ValueError('Invalid load-command size')
        if command == 0x32 and size >= 24:  # LC_BUILD_VERSION
            platform, version = struct.unpack_from('<II', data, pos + 8)
        if command == 0x30 and size >= 16:  # LC_VERSION_MIN_WATCHOS
            platform = 4
            version, = struct.unpack_from('<I', data, pos + 8)
        pos += size
    if platform != 4 or version is None or version > (10 << 16):
        raise ValueError('Requires watchOS DEVICE binary with deployment target <=10.0')
    architecture = {0x0200000c: 'arm64_32', 0x0100000c: 'arm64'}.get(cpu)
    if architecture is None:
        raise ValueError(f'Unsupported Watch CPU: {cpu:#x}')
    return [architecture]


def validate_app(app):
    app = Path(app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    expected = {'CFBundleIdentifier': WATCH_BUNDLE_ID,
                'WKCompanionAppBundleIdentifier': PHONE_BUNDLE_ID,
                'WKApplication': True, 'WKRunsIndependentlyOfCompanionApp': True,
                'CFBundleShortVersionString': '3.5.3', 'CFBundleVersion': '3.5.3'}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Unexpected {key}: {info.get(key)!r}')
    if info.get('WKWatchOnly', False) or info.get('CFBundleSupportedPlatforms') != ['WatchOS']:
        raise ValueError('Watch app must be a device companion application')
    minimum = info.get('MinimumOSVersion', '')
    if not isinstance(minimum, str) or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', minimum):
        raise ValueError('Missing or invalid MinimumOSVersion')
    version = tuple(int(part) for part in minimum.split('.'))
    if (version + (0,) * (3 - len(version))) > (10, 0, 0):
        raise ValueError('MinimumOSVersion excludes the watchOS 10.0 target')
    if info.get('UIDeviceFamily') != [4]:
        raise ValueError('Device family must be Watch (4)')
    executable = info.get('CFBundleExecutable', '')
    if not executable or Path(executable).name != executable:
        raise ValueError('Invalid executable filename')
    architectures = sorted(watch_slices((app / executable).read_bytes()))
    if architectures != ['arm64', 'arm64_32']:
        raise ValueError(f'Need BOTH Series5 and newer slices, got {architectures}')
    if not (app / 'speaker-check.wav').is_file():
        raise ValueError('Missing bundled test audio')
    for path in app.rglob('*'):
        if path.is_symlink() or path.suffix == '.mobileprovision':
            raise ValueError('Probe must not carry symlinks or private provisioning profiles')
    return info, architectures


def package(base, app, output):
    base, app, output = Path(base), Path(app), Path(output)
    if base.resolve() == output.resolve() or output.exists():
        raise ValueError('Refusing to overwrite input or existing output')
    if digest(base) != BASE_SHA256:
        raise ValueError('Base IPA differs from the audited v1.0.0 release')
    info, architectures = validate_app(app)
    files = sorted(p for p in app.rglob('*') if p.is_file())
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(base) as source:
        names = source.namelist()
        if len(names) != len(set(names)) or any('/Watch/' in n for n in names):
            raise ValueError('Duplicate entries or existing Watch bundle in base')
        phone = plistlib.loads(source.read('Payload/Spotify.app/Info.plist'))
        if phone['CFBundleIdentifier'] != PHONE_BUNDLE_ID:
            raise ValueError('Unexpected phone bundle identifier')
        for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
            if phone.get(key) != info[key]:
                raise ValueError(f'Phone/Watch {key} mismatch')
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as dest:
            for item in source.infolist():
                dest.writestr(item, source.read(item))
            for path in files:
                dest.write(path, PREFIX + path.relative_to(app).as_posix())
    # Check every original uncompressed entry; signatures are refreshed by the installer.
    with zipfile.ZipFile(base) as source, zipfile.ZipFile(output) as dest:
        if dest.testzip() is not None:
            raise ValueError('Output ZIP CRC check failed')
        for name in source.namelist():
            if source.read(name) != dest.read(name):
                raise ValueError(f'Original entry changed: {name}')
        added = set(dest.namelist()) - set(source.namelist())
        if not added or not all(name.startswith(PREFIX) for name in added):
            raise ValueError('Unexpected modifications outside the new Watch bundle')
    checksum = digest(output)
    manifest = {
        'status': 'experimental-installation-and-speaker-probe',
        'prototype': '1.1-speaker-probe.1',
        'base_sha256': BASE_SHA256, 'sha256': checksum,
        'watch_bundle_id': info['CFBundleIdentifier'],
        'watch_architectures': architectures,
        'minimum_watchos': info.get('MinimumOSVersion'),
        'original_entries_unchanged': True,
        'signing': 'Watch bundle unsigned; installation requires matching phone/watch provisioning',
        'spotify_playback': False, 'device_installation_verified': False,
        'speaker_verified': False, 'background_playback_verified': False,
        'watch_file_count': len(files),
    }
    output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    output.with_suffix('.ipa.sha256').write_text(f'{checksum}  {output.name}\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--watch-app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    package(args.base, args.watch_app, args.output)
