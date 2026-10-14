#!/usr/bin/env python3
"""Run Linux C host tests against inert Chroma data from your own IPA.

No app/ARM64 code is executed. No IPA or extracted binary is kept in this repo.
The reverse-bridge test maps Mach-O segments itself; the other tests read the
raw file. These tests do not compile iOS dylibs or reproduce the full app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
EXPECTED_UUID = bytes.fromhex("d4c75c03b90b329d83b960d768cc43aa")
MAX_IMAGE = 128 * 1024 * 1024
TESTS = (
    ("reverse-state-track", "reverse_bridge_host_test.c", ("-DREVERSE_ENABLE_TRACK_ALIAS=1",), True),
    ("hud", "hud_suppression_host_test.c", (), False),
    ("stock-ui", "stock_ui.c", ("-DSTOCK_UI_TEST=1",), False),
    ("settings", "settings_filter_host_test.c", (), True),
    ("haptics-pause", "haptics_pause_guard_host_test.c", (), True),
)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check_fixture(data):
    """Reject the wrong image or malformed load commands before the C tests."""
    if len(data) < 32:
        raise ValueError("Chroma image is too short")
    magic, cpu, subtype, filetype, count, command_bytes, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, subtype, filetype) != (0xFEEDFACF, 0x100000C, 0, 6):
        raise ValueError("Tests require the audited arm64 Chroma dylib")
    end = 32 + command_bytes
    if count > 256 or end > len(data) or command_bytes > 65536:
        raise ValueError("Invalid Mach-O command bounds")
    offset = 32
    uuids = []
    segments = 0
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        kind, size = struct.unpack_from("<2I", data, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError("Invalid load-command size")
        if kind == 0x1B:
            if size != 24:
                raise ValueError("Invalid UUID command")
            uuids.append(data[offset + 8:offset + 24])
        if kind == 0x19:
            if size < 72:
                raise ValueError("Truncated segment command")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", data, offset + 24)
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            if (vmaddr + vmsize >= MAX_IMAGE or filesize > vmsize
                    or fileoff + filesize > len(data) or section_count > (size - 72) // 80):
                raise ValueError("Invalid segment/section bounds")
            segments += 1
        offset += size
    if offset != end or uuids != [EXPECTED_UUID] or not segments:
        raise ValueError("This IPA does not contain the audited Chroma image")


def fixture_from_ipa(path):
    with zipfile.ZipFile(path) as archive:
        matches = [item for item in archive.infolist()
                   if re.fullmatch(r"Payload/[^/]+\.app/Frameworks/spotifyglass\.dylib", item.filename)]
        if len(matches) != 1 or not 0 < matches[0].file_size <= 64 * 1024 * 1024:
            raise ValueError("IPA must contain exactly one bounded spotifyglass.dylib")
        data = archive.read(matches[0])
    check_fixture(data)
    return data


def run(command, *, environment=None):
    result = subprocess.run(command, text=True, capture_output=True, env=environment)
    if result.returncode:
        raise RuntimeError(
            f"{Path(command[0]).name} failed (exit {result.returncode})\n"
            f"{result.stdout}{result.stderr}"
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", required=True, type=Path, help="Your own working Glitchify/compatible IPA")
    parser.add_argument("--cc", help="C compiler executable (default: gcc, then clang)")
    parser.add_argument("--no-sanitize", action="store_true", help="Explicitly omit ASan/UBSan if unavailable")
    parser.add_argument("--report", type=Path, help="Optional JSON result; contains hashes, not local IPA paths")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("Run this script on Linux, including inside WSL")
    compiler = shutil.which(args.cc) if args.cc else (shutil.which("gcc") or shutil.which("clang"))
    if not compiler:
        parser.error("Install GCC or Clang, or supply --cc /path/to/compiler")
    compiler_version = run([compiler, "--version"]).stdout.splitlines()[0]
    data = fixture_from_ipa(args.ipa)
    flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-Wno-cast-function-type",
             "-fno-omit-frame-pointer", "-I", str(HERE)]
    if not args.no_sanitize:
        flags.append("-fsanitize=address,undefined")
        if "clang" in compiler_version.lower():
            # ObjC runtime mocks use typed dispatch casts, just as objc_msgSend.
            flags.append("-fno-sanitize=function")
    environment = os.environ.copy()
    environment["UBSAN_OPTIONS"] = environment.get("UBSAN_OPTIONS", "") + ":halt_on_error=1"
    results = []
    with tempfile.TemporaryDirectory(prefix="glitchify-host-tests-") as directory:
        work = Path(directory)
        fixture = work / "chroma-inert.data"
        fixture.write_bytes(data)
        for name, source_name, defines, needs_fixture in TESTS:
            executable = work / name
            source = HERE / source_name
            run([compiler, *flags, *defines, str(source), "-o", str(executable)])
            command = [str(executable)] + ([str(fixture)] if needs_fixture else [])
            result = run(command, environment=environment)
            if "PASS" not in result.stdout:
                raise RuntimeError(f"{name} produced no PASS result")
            if result.stderr:
                raise RuntimeError(f"{name} emitted unexpected diagnostics:\n{result.stderr}")
            print(f"PASS {name}: {result.stdout.strip()}")
            results.append({"name": name, "source": source_name,
                            "source_sha256": digest(source.read_bytes()), "output": result.stdout.strip()})
    report = {
        "result": "PASS", "compiler": compiler_version,
        "sanitizers": not args.no_sanitize, "chroma_data_sha256": digest(data),
        "reverse_track_alias_enabled": True, "tests": results,
        "limits": "Host mocks and inert binary metadata only; no iOS/ARM64 execution or full app rebuild.",
    }
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"PASS: all {len(results)} host suites; temporary fixture and executables removed")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile) as error:
        raise SystemExit(f"Host tests failed: {error}") from error
