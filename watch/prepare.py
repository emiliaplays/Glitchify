"""Generate the local audio fixture and asset catalogue; no network or account data."""
from pathlib import Path
import json
import math
import struct
import subprocess
import wave


def make_tone(path: Path) -> None:
    """A quiet, finite three-second two-note fixture with faded edges."""
    rate = 22050
    samples = bytearray()
    for i in range(3 * rate):
        t = i / rate
        # Two short notes separated by silence, at approximately -20 dBFS peak.
        segment = t if t < 1.25 else t - 1.75
        active = 0 <= segment < 1.0
        envelope = min(1.0, segment / .06, (1.0 - segment) / .06) if active else 0
        frequency = 440 if t < 1.25 else 660
        sample = round(3276 * max(0, envelope) * math.sin(2 * math.pi * frequency * t))
        samples += struct.pack('<h', sample)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(rate)
        audio.writeframes(samples)


def prepare() -> None:
    root = Path(__file__).resolve().parent
    resources = root / 'Generated' / 'Resources'
    make_tone(resources / 'speaker-check.wav')
    assets = resources / 'Assets.xcassets'
    icons = assets / 'AppIcon.appiconset'
    icons.mkdir(parents=True, exist_ok=True)
    info = {'author': 'xcode', 'version': 1}
    (assets / 'Contents.json').write_text(json.dumps({'info': info}), encoding='utf-8')
    # Xcode's single-size watchOS app-icon catalogue; reuse the released artwork.
    subprocess.run(['sips', '-z', '1024', '1024', str(root.parent / 'logo.png'),
                    '--out', str(icons / 'AppIcon.png')], check=True)
    (icons / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': 'AppIcon.png', 'idiom': 'universal',
                    'platform': 'watchos', 'size': '1024x1024'}],
        'info': info,
    }, indent=2), encoding='utf-8')


if __name__ == '__main__':
    prepare()
