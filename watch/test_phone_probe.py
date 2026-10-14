import struct
import unittest
import package_phone_probe as probe


def helper_fixture():
    name = probe.INSTALL_NAME.encode() + b'\0'
    size = (24 + len(name) + 7) & ~7
    identity = (struct.pack('<6I', 0xd, size, 24, 0, 0, 0) + name).ljust(size, b'\0')
    platform = struct.pack('<6I', 0x32, 24, 2, 0x100100, 0x120000, 0)
    length = size + 24 + 16
    signature = struct.pack('<4I', 0x1d, 16, 32 + length, 8)
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 6, 3, length, 0, 0)
    return header + identity + platform + signature + b'\xfa\xde\x0c\xc0\0\0\0\x08'


class ProbeChecks(unittest.TestCase):
    def test_structural_helper_check(self):
        probe.validate_helper(helper_fixture())

    def test_reject_truncated_headers_and_commands(self):
        original = helper_fixture()
        for length in (0, 20, 31, 33, 50, len(original) - 4):
            with self.subTest(length=length), self.assertRaises(ValueError):
                probe.validate_helper(original[:length])

    def test_reject_wrong_architecture_platform_and_identity(self):
        original = helper_fixture()
        variants = []
        for offset, value in ((4, 0x200000c), (8, 2), (12, 2), (24, 0x200000)):
            data = bytearray(original); struct.pack_into('<I', data, offset, value); variants.append(data)
        cmds, _, _ = probe.commands(original)
        data = bytearray(original); struct.pack_into('<I', data, cmds[1][1] + 8, 7); variants.append(data)
        data = bytearray(original); data[56] = ord('x'); variants.append(data)
        for data in variants:
            with self.subTest(data=data[:32]), self.assertRaises(ValueError):
                probe.validate_helper(data)

    def test_reject_signature_out_of_bounds(self):
        data = bytearray(helper_fixture()); cmds, _, _ = probe.commands(data)
        struct.pack_into('<I', data, cmds[-1][1] + 8, len(data))
        with self.assertRaises(ValueError): probe.validate_helper(data)

    def test_reject_unpinned_chroma(self):
        with self.assertRaises(ValueError): probe.append_dependency(helper_fixture())


if __name__ == '__main__':
    unittest.main()
