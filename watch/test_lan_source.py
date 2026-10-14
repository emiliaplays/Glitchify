import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location('lan_source', Path(__file__).with_name('lan_test_server.py'))
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class LANSourceTests(unittest.TestCase):
    def test_private_only_binding(self):
        for address in ['10.0.0.2', '172.16.0.5', '192.168.1.23']:
            self.assertTrue(source.allowed_address(address))
        for address in ['0.0.0.0', '127.0.0.1', '8.8.8.8', '192.168.1.255', '172.32.0.1']:
            self.assertFalse(source.allowed_address(address))

    def test_pcm_duration_amplitude_and_silence(self):
        size = 0
        peak = 0
        for block in range(source.BLOCKS):
            data = source.tone_block(block)
            size += len(data)
            samples = struct.unpack('<2400h', data)
            peak = max(peak, max(abs(sample) for sample in samples))
            if block // 10 % 5 == 4:
                self.assertFalse(any(samples))
        self.assertEqual(size, 960_000)
        self.assertGreater(peak, 500)
        self.assertLessEqual(peak, 900)

    def test_no_implicit_unbounded_audio(self):
        for index in [-1, 200, 10_000]:
            with self.assertRaises(ValueError):
                source.tone_block(index)


if __name__ == '__main__':
    unittest.main()
