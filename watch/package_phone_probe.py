"""Add an opt-in, metadata-only phone PCM observer to a COPY of the Watch test.

Only the audited Chroma's load-command padding and phone Info.plist change;
all executable sections and every other original archive entry are preserved.
The installer must recursively re-sign the resulting diagnostic.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zipfile

PHONE = 'Payload/Spotify.app/'
CHROMA = PHONE + 'Frameworks/spotifyglass.dylib'
HELPER = PHONE + 'Frameworks/GlitchifyPhonePCMProbe.dylib'
INSTALL_NAME = '@rpath/GlitchifyPhonePCMProbe.dylib'
CHROMA_SHA = '6d854c742ebbc7959f5ef6f4075881568d3f0d422817be9c1e5c337b9a73175b'
PHONE_INFO = PHONE + 'Info.plist'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def commands(data):
    if len(data) < 32:
        raise ValueError('Truncated Mach-O')
    magic, cpu, subtype, kind, count, size, flags, _ = struct.unpack_from('<8I', data)
    if (magic, cpu, subtype, kind) != (0xfeedfacf, 0x100000c, 0, 6) or flags & 0x200000:
        raise ValueError('Expected non-PIE arm64 dylib')
    if not 1 <= count <= 256 or size > 65536 or 32 + size > len(data):
        raise ValueError('Invalid command area')
    result, at = [], 32
    for _ in range(count):
        if at + 8 > 32 + size:
            raise ValueError('Truncated load command')
        cmd, length = struct.unpack_from('<II', data, at)
        if length < 8 or length % 8 or at + length > 32 + size:
            raise ValueError('Invalid load command')
        result.append((cmd, at, length))
        at += length
    if at != 32 + size:
        raise ValueError('Unused command bytes')
    return result, count, size


def validate_helper(data):
    cmds, _, _ = commands(data)
    identifiers, signatures, platforms = [], [], []
    for cmd, at, length in cmds:
        if cmd == 0xe:
            raise ValueError('Dylib has LC_LOAD_DYLINKER')
        if cmd == 0xd:
            if length < 24:
                raise ValueError('Truncated identity')
            offset, = struct.unpack_from('<I', data, at + 8)
            if not 24 <= offset < length:
                raise ValueError('Invalid identity offset')
            identifiers.append(data[at + offset:at + length].split(b'\0')[0].decode('ascii'))
        if cmd == 0x32:
            if length < 24:
                raise ValueError('Truncated platform')
            platforms.append(struct.unpack_from('<II', data, at + 8))
        if cmd == 0x1d:
            if length != 16:
                raise ValueError('Invalid code-signature command')
            offset, size = struct.unpack_from('<II', data, at + 8)
            if not size or offset + size > len(data) or data[offset:offset + 4] != b'\xfa\xde\x0c\xc0':
                raise ValueError('Missing signature SuperBlob')
            signatures.append((offset, size))
    if identifiers != [INSTALL_NAME] or len(signatures) != 1:
        raise ValueError('Wrong helper identity or signature count')
    if len(platforms) != 1 or platforms[0][0] != 2 or platforms[0][1] > 0x100100:
        raise ValueError('Expected iOS device deployment <=16.1')


def append_dependency(data):
    if sha(data) != CHROMA_SHA:
        raise ValueError('Chroma differs from the audited release')
    cmds, count, size = commands(data)
    sections = []
    for cmd, at, length in cmds:
        if cmd == 0x19:
            if length < 72:
                raise ValueError('Truncated segment')
            nsects, = struct.unpack_from('<I', data, at + 64)
            if nsects > (length - 72) // 80:
                raise ValueError('Truncated section array')
            for i in range(nsects):
                offset, = struct.unpack_from('<I', data, at + 72 + i * 80 + 48)
                if offset:
                    sections.append(offset)
    encoded = INSTALL_NAME.encode('ascii') + b'\0'
    length = (24 + len(encoded) + 7) & ~7
    end = 32 + size
    if not sections or end + length > min(sections) or any(data[end:end + length]):
        raise ValueError('No unused header padding')
    addition = (struct.pack('<6I', 0xc, length, 24, 0, 0, 0) + encoded).ljust(length, b'\0')
    out = bytearray(data)
    struct.pack_into('<II', out, 16, count + 1, size + length)
    out[end:end + length] = addition
    if out[:16] != data[:16] or out[24:end] != data[24:end] or out[end + length:] != data[end + length:]:
        raise ValueError('Unexpected edit outside load-command padding')
    commands(out)
    return bytes(out)


def package(source, helper, output, relay=False):
    source, helper, output = map(Path, (source, helper, output))
    if output.exists() or output.resolve() in (source.resolve(), helper.resolve()):
        raise ValueError('Refusing to overwrite any input or existing output')
    binary = helper.read_bytes()
    validate_helper(binary)
    with zipfile.ZipFile(source) as original:
        names = original.namelist()
        if len(names) != len(set(names)) or HELPER in names or original.testzip():
            raise ValueError('Unexpected source archive')
        info = plistlib.loads(original.read(PHONE_INFO))
        if info.get('CFBundleIdentifier') != 'com.spotify.client' or 'GlitchifyPhonePCMProbe' in info:
            raise ValueError('Unexpected phone identity or existing probe')
        info['GlitchifyPhonePCMProbe'] = True
        info['GlitchifyPhonePCMRevision'] = '1.1-phone-pcm-probe.1'
        if relay:
            info['GlitchifyPhoneRelayRevision'] = '1.1-phone-relay-probe.1'
        changed = {CHROMA: append_dependency(original.read(CHROMA)),
                   PHONE_INFO: plistlib.dumps(info, fmt=plistlib.FMT_BINARY)}
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as target:
            for entry in original.infolist():
                target.writestr(entry, changed.get(entry.filename, original.read(entry)))
            entry = zipfile.ZipInfo(HELPER)
            entry.create_system = 3
            entry.external_attr = 0o100755 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            target.writestr(entry, binary)
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as target:
        if target.testzip() or set(target.namelist()) != set(names) | {HELPER}:
            raise ValueError('Invalid output entry set or CRC')
        for name in names:
            if target.read(name) != changed.get(name, original.read(name)):
                raise ValueError(f'Unexpected content change: {name}')
        if target.read(HELPER) != binary:
            raise ValueError('Helper changed during packaging')
    report = {'revision': '1.1-phone-relay-probe.1' if relay else '1.1-phone-pcm-probe.1', 'sha256': sha(output.read_bytes()),
        'relay_capable': relay, 'relay_pairing_bundled': False,
        'helper_sha256': sha(binary), 'source_sha256': sha(source.read_bytes()),
        'changed_entries': list(changed), 'added_entries': [HELPER],
        'unchanged_source_entries': len(names) - len(changed), 'executable_sections_unchanged': True,
        'audio_saved': False, 'audio_transmitted': False, 'runtime_verified': False,
        'signing': 'Requires recursive signing for phone and Watch'}
    output.with_suffix('.manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--relay', action='store_true')
    args = parser.parse_args()
    package(args.source, args.helper, args.output, args.relay)
