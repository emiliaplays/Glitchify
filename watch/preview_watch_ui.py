"""Run the actual Watch UI in an available small Watch simulator and save proof."""
import json
from pathlib import Path
import subprocess
import time

def run(*args):
    return subprocess.check_output(args, text=True)

def main():
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
    choices = [d for runtime, values in devices.items() if 'watchOS' in runtime
               for d in values if d.get('isAvailable') and 'Apple Watch' in d['name']]
    if not choices:
        raise RuntimeError('No Watch simulator available')
    choices.sort(key=lambda d: (not any(s in d['name'] for s in ['40mm', '41mm']), d['name']))
    device = choices[0]
    print('Watch UI preview:', device['name'], flush=True)
    if device['state'] != 'Booted': run('xcrun', 'simctl', 'boot', device['udid'])
    run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
    subprocess.run(['xcodebuild', '-project', 'watch/GlitchifyWatch.xcodeproj', '-scheme', 'GlitchifyWatch',
                    '-configuration', 'Release', '-sdk', 'watchsimulator',
                    '-destination', 'id='+device['udid'], '-derivedDataPath', 'watch/sim-build',
                    'CODE_SIGNING_ALLOWED=NO', 'build'], check=True)
    app = 'watch/sim-build/Build/Products/Release-watchsimulator/GlitchifyWatch.app'
    run('xcrun', 'simctl', 'install', device['udid'], app)
    run('xcrun', 'simctl', 'launch', device['udid'], 'com.spotify.client.watchkitapp')
    time.sleep(3)
    Path('watch/ui-preview').mkdir(exist_ok=True)
    run('xcrun', 'simctl', 'io', device['udid'], 'screenshot', 'watch/ui-preview/watch-player.png')
    Path('watch/ui-preview/device.txt').write_text(device['name']+'\n', encoding='utf-8')

if __name__ == '__main__': main()
