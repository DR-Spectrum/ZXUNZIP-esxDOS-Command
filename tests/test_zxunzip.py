"""Run the assembled dot command on a Z80 emulator with an esxDOS filesystem."""
import io
from pathlib import Path
import random
import re
import struct
import unittest
import zipfile
import zlib

import z80


ROOT = Path(__file__).resolve().parents[1]
IMAGE = (ROOT / "bin/ZXUNZIP").read_bytes()
SYMBOLS = {
    name: int(value, 16)
    for name, value in re.findall(
        r"^(\w+): EQU 0x([0-9A-Fa-f]+)",
        (ROOT / "bin/ZXUNZIP.sym").read_text(),
        re.M,
    )
}


def make_zip(entries, method=zipfile.ZIP_DEFLATED, comment=b"", streaming=False):
    class Stream(io.BytesIO):
        def seek(self, *args):
            raise io.UnsupportedOperation("non-seekable")

    target = Stream() if streaming else io.BytesIO()
    with zipfile.ZipFile(target, "w", compression=method) as archive:
        for name, data in entries:
            archive.writestr(name, data)
        archive.comment = comment
    return target.getvalue()


def zip_with_raw_deflate(name, data, compressed):
    source = make_zip([(name, data)], zipfile.ZIP_STORED)
    central = source.index(b"PK\x01\x02", 30 + len(name) + len(data))
    header = bytearray(source[:30 + len(name)])
    trailer = bytearray(source[central:])
    struct.pack_into("<H", header, 8, 8)
    struct.pack_into("<I", header, 18, len(compressed))
    struct.pack_into("<H", trailer, 10, 8)
    struct.pack_into("<I", trailer, 20, len(compressed))
    struct.pack_into("<I", trailer, len(trailer) - 6, len(header) + len(compressed))
    return bytes(header) + compressed + bytes(trailer)


class Spectrum:
    def __init__(self, archive=b"", files=None, ramtop=0xFF57, stack=0xFEE0,
                 stkend=0x6200, udg=0xFF58):
        self.machine = z80.Z80Machine()
        self.machine.memory[0x2000:0x2000 + len(IMAGE)] = IMAGE
        self.machine.memory[0x5CB2:0x5CB4] = ramtop.to_bytes(2, "little")
        self.machine.memory[0x5C7B:0x5C7D] = udg.to_bytes(2, "little")
        self.machine.memory[0x5C65:0x5C67] = stkend.to_bytes(2, "little")
        self.stack = stack
        self.machine.set_input_callback(lambda port: 0xFF)
        self.files = {b"GAMES.ZIP": archive, **(files or {})}
        self.handles = {}
        self.screen = bytearray()
        self.machine.memory[0x5C84:0x5C86] = (0x4000).to_bytes(2, "little")
        self.row = self.column = 0
        self.writes = 0
        self.short_write = False

    def name(self, address):
        return bytes(self.machine.memory[address:address+128]).split(b"\0", 1)[0]

    def esxdos(self, op):
        m = self.machine
        assert m.hl == m.ix or op in (0x9B, 0x9F), hex(op)
        error = 0
        if op == 0x9A:
            name = self.name(m.hl)
            assert m.a == ord("*")
            if m.b == 6 and name in self.files:
                error = 18
            elif m.b == 1 and name not in self.files:
                error = 6
            else:
                if m.b == 6:
                    self.files[name] = b""
                handle = next(i for i in range(8) if i not in self.handles)
                self.handles[handle] = [name, 0]
                m.a = handle
        elif op == 0x9B:
            del self.handles[m.a]
        elif op == 0xAD:
            del self.files[self.name(m.hl)]
        else:
            handle = self.handles[m.a]
            name, offset = handle
            if op == 0xA1:
                m.memory[m.hl:m.hl+11] = b"\0" * 7 + struct.pack("<I", len(self.files[name]))
            elif op == 0x9F:
                assert m.l == 0 and m.ix == 0
                handle[1] = min((m.bc << 16) | m.de, len(self.files[name]))
            elif op == 0x9D:
                chunk = self.files[name][offset:offset + m.bc]
                m.memory[m.hl:m.hl + len(chunk)] = chunk
                m.bc = len(chunk)
                handle[1] += len(chunk)
            elif op == 0x9E:
                self.writes += 1
                if self.short_write:
                    m.bc -= 1
                chunk = bytes(m.memory[m.hl:m.hl + m.bc])
                self.files[name] += chunk
                handle[1] += m.bc
            else:
                raise AssertionError(f"Unexpected esxDOS call {op:02x}")
        m.hl = 0xBEEF
        m.de = 0xD00D
        m.f = int(bool(error))
        if error:
            m.a = error
        m.memory[0x3C00:0x4000] = b"\xA5" * 1024

    def cell_address(self, row, column):
        return 0x4000 + ((row & 0x18) << 8) + ((row & 7) << 5) + column

    def print_rom_byte(self, char):
        self.screen.append(char)
        if char == 13:
            self.row += 1
            self.column = 0
        else:
            if char == 32:
                address = self.cell_address(self.row % 24, self.column)
                self.machine.memory[address:address+0x800:0x100] = bytes(8)
            self.column += 1
            if self.column == 32:
                self.row += 1
                self.column = 0
        address = self.cell_address(self.row % 24, self.column)
        self.machine.memory[0x5C84:0x5C86] = address.to_bytes(2, "little")
        self.machine.de = 0xD00D

    def run(self, arguments=b"GAMES.ZIP"):
        m = self.machine
        for breakpoint in (8, 16, 0x0100):
            m.set_breakpoint(breakpoint)
        m.memory[0x6100:0x6100 + len(arguments) + 1] = arguments + b"\r"
        m.hl = 0x6100
        m.sp = self.stack
        m.memory[m.sp:m.sp+2] = b"\x00\x01"
        m.pc = SYMBOLS["entry"]
        for _ in range(20000):
            m.ticks_to_stop = 100000
            if not m.run() & 1:
                continue
            if m.pc == 0x0100:
                assert not self.handles, self.handles
                return self.screen.decode("ascii").replace("\r", "\n")
            ret = int.from_bytes(m.memory[m.sp:m.sp+2], "little")
            if m.pc == 8:
                self.esxdos(m.memory[ret])
                m.pc = ret + 1
            elif m.pc == 16:
                self.print_rom_byte(m.a)
                m.pc = ret
            else:
                raise AssertionError(f"Unexpected breakpoint {m.pc:04x}")
            m.sp += 2
        raise AssertionError(f"Command did not return, PC={m.pc:04x}")


class UnzipTests(unittest.TestCase):
    def test_help_draws_brackets_without_using_rom_glyphs(self):
        spectrum = Spectrum()
        help_text = spectrum.run(b"-h")
        self.assertNotIn("[", help_text)
        self.assertNotIn("]", help_text)
        line = ".zxunzip FILE.ZIP [number]"
        for char, pixels in (("[", b"\x38" + b"\x20" * 6 + b"\x38"),
                             ("]", b"\x38" + b"\x08" * 6 + b"\x38")):
            address = spectrum.cell_address(1, line.index(char))
            self.assertEqual(bytes(spectrum.machine.memory[address:address+0x800:0x100]), pixels)

    def test_help_and_memory_guard(self):
        archive = make_zip([("A.TAP", b"data")])
        spectrum = Spectrum(archive, stkend=0x7000)
        help_text = spectrum.run(b"-h")
        self.assertIn("ZXUNZIP 0.5", help_text)
        self.assertIn(".zxunzip FILE.ZIP  number ", help_text.splitlines())
        self.assertIn(".zxunzip -l FILE.ZIP", help_text)
        self.assertIn(".TZX .TAP .MDV .Z80", help_text)
        self.assertIn(".SNA .DSK .TRD .SCR", help_text)
        self.assertIn("Need free RAM 7000-EFFF", spectrum.run())
        self.assertIn("1 A.TAP", spectrum.run(b"-l GAMES.ZIP"))
        self.assertNotIn(b"A.TAP", spectrum.files)

        for layout in (
            {"stack": 0xEF00},
            {"ramtop": 0xDFFF},
            {"ramtop": 0x6FFF},
            {"udg": 0xEFFF},
        ):
            with self.subTest(layout=layout):
                spectrum = Spectrum(archive, **layout)
                self.assertIn("Need free RAM 7000-EFFF", spectrum.run())
                self.assertNotIn(b"A.TAP", spectrum.files)

    def test_list_option_requires_a_filename_and_no_extra_arguments(self):
        archive = make_zip([("A.TAP", b"data")])
        for args in (b"-l", b"-list GAMES.ZIP", b"-l GAMES.ZIP 1", b"GAMES.ZIP -l"):
            with self.subTest(args=args):
                spectrum = Spectrum(archive)
                self.assertIn(".zxunzip -l FILE.ZIP", spectrum.run(args))
                self.assertNotIn(b"A.TAP", spectrum.files)
        spectrum = Spectrum(archive)
        self.assertIn("1 A.TAP", spectrum.run(b"  -L  GAMES.ZIP  "))
        self.assertNotIn(b"A.TAP", spectrum.files)

    def test_normal_ramtop_and_explicit_clear_preserve_basic_memory(self):
        data = b"data" * 200
        archive = make_zip([("A.TAP", data)])
        for layout in ({}, {"ramtop": 0x6FFF, "stack": 0x6FD0}):
            with self.subTest(layout=layout):
                spectrum = Spectrum(archive, **layout)
                memory = spectrum.machine.memory
                basic = bytes(range(128))
                memory[0x6000:0x6080] = basic
                ramtop = bytes(memory[0x5CB2:0x5CB4])
                self.assertIn("Saved A.TAP", spectrum.run())
                self.assertEqual(spectrum.files[b"A.TAP"], data)
                self.assertEqual(bytes(memory[0x5CB2:0x5CB4]), ramtop)
                self.assertEqual(bytes(memory[0x6000:0x6080]), basic)
                self.assertEqual(spectrum.machine.sp, spectrum.stack + 2)

    def test_each_extension_in_subdirectories(self):
        for ext in ("TZX", "TAP", "MDV", "Z80", "SNA", "DSK", "TRD", "SCR"):
            with self.subTest(extension=ext):
                data = bytes(range(256)) * 3
                archive = make_zip([("folder/more/Best Game." + ext.lower(), data)])
                spectrum = Spectrum(archive)
                self.assertIn("Saved BEST_GAM." + ext, spectrum.run())
                self.assertEqual(spectrum.files[b"BEST_GAM." + ext.encode()], data)

    def test_directory_selection_and_no_supported_files(self):
        archive = make_zip([
            ("Disk/A/THE GAME.TAP", b"A" * 30),
            ("notes.txt", b"ignored"),
            ("Disk/B/THE GAME.TAP", b"B" * 42),
        ])
        spectrum = Spectrum(archive)
        menu = spectrum.run()
        self.assertIn("1 Disk/A/THE GAME.TAP", menu)
        self.assertIn("2 Disk/B/THE GAME.TAP", menu)
        self.assertEqual(len(spectrum.files), 1)
        self.assertNotIn("Saved ", spectrum.run(b"-l GAMES.ZIP"))
        self.assertIn("out of range", spectrum.run(b"GAMES.ZIP 3"))
        self.assertIn("Saved THE_GAME.TAP", spectrum.run(b"GAMES.ZIP 2"))
        self.assertEqual(spectrum.files[b"THE_GAME.TAP"], b"B" * 42)

        spectrum = Spectrum(make_zip([("note.txt", b"hi")]))
        self.assertIn("No supported files", spectrum.run())
        self.assertEqual(len(spectrum.files), 1)

    def test_store_collision_and_zip_comment(self):
        data = random.Random(2).randbytes(1001)
        archive = make_zip(
            [("dir/subdir/abcdefghijk.TaP", data)],
            zipfile.ZIP_STORED,
            b"test" * 16383 + b"end",
        )
        spectrum = Spectrum(archive, {b"ABCDEFGH.TAP": b"old", b"ABCDEFG1.TAP": b"old"})
        self.assertIn("Saved ABCDEFG2.TAP", spectrum.run())
        self.assertEqual(spectrum.files[b"ABCDEFG2.TAP"], data)
        self.assertEqual(spectrum.files[b"ABCDEFGH.TAP"], b"old")

    def test_dynamic_and_sliding_window_with_data_descriptor(self):
        prefix = random.Random(17).randbytes(23000)
        data = prefix + b"ZX Spectrum" * 600 + prefix + b"final"
        archive = make_zip([("folders/loader.tzx", data)], streaming=True)
        spectrum = Spectrum(archive)
        self.assertIn("Saved LOADER.TZX", spectrum.run())
        self.assertEqual(spectrum.files[b"LOADER.TZX"], data)

    def test_fixed_and_stored_deflate_blocks(self):
        data = b"fixed Huffman " * 155
        for level, strategy, expected_type in ((6, zlib.Z_FIXED, 1), (0, 0, 0)):
            with self.subTest(block=expected_type):
                compressor = zlib.compressobj(level, zlib.DEFLATED, -15, 8, strategy)
                compressed = compressor.compress(data) + compressor.flush()
                self.assertEqual((compressed[0] >> 1) & 3, expected_type)
                spectrum = Spectrum(zip_with_raw_deflate("DATA.SNA", data, compressed))
                self.assertIn("Saved DATA.SNA", spectrum.run())
                self.assertEqual(spectrum.files[b"DATA.SNA"], data)

    def test_maximum_deflate_distance_and_32bit_archive_offsets(self):
        prefix = random.Random(42).randbytes(32768)
        # Nonfinal stored block followed by a final fixed block. Its first
        # match copies three bytes from exactly 32 KiB back in the ring.
        fixed_bits = "110" + "0000001" + "11101" + "1" * 13 + "0000000"
        fixed_bits = fixed_bits.ljust((len(fixed_bits) + 7) // 8 * 8, "0")
        fixed = bytes(
            int(fixed_bits[i:i + 8][::-1], 2) for i in range(0, len(fixed_bits), 8)
        )
        raw = b"\x00" + struct.pack("<HH", len(prefix), 0x7FFF) + prefix + fixed
        data = prefix + prefix[:3]
        self.assertEqual(zlib.decompress(raw, -15), data)
        spectrum = Spectrum(zip_with_raw_deflate("A.TAP", data, raw))
        self.assertIn("Saved A.TAP", spectrum.run())
        self.assertEqual(spectrum.files[b"A.TAP"], data)

        archive = make_zip([("large.bin", prefix * 3), ("A.TAP", data)], zipfile.ZIP_STORED)
        spectrum = Spectrum(archive)
        self.assertIn("Saved A.TAP", spectrum.run())
        self.assertEqual(spectrum.files[b"A.TAP"], data)

    def test_break_removes_created_output(self):
        spectrum = Spectrum(make_zip([("A.TAP", b"a" * 4000)]))

        def keys(port):
            if spectrum.writes and port >> 8 in (0xFE, 0x7F):
                return 0xFE
            return 0xFF

        spectrum.machine.set_input_callback(keys)
        self.assertIn("Cancelled.", spectrum.run())
        self.assertNotIn(b"A.TAP", spectrum.files)

    def test_corruption_and_disk_failure_remove_partial_output(self):
        data = bytes(range(128)) * 20
        archive = bytearray(make_zip([("A.TAP", data)], zipfile.ZIP_STORED))
        archive[600] ^= 1
        spectrum = Spectrum(archive)
        self.assertIn("Invalid or damaged ZIP", spectrum.run())
        self.assertGreater(spectrum.writes, 0)
        self.assertNotIn(b"A.TAP", spectrum.files)

        spectrum = Spectrum(make_zip([("A.TAP", data)]))
        spectrum.short_write = True
        self.assertIn("SD read or write error", spectrum.run())
        self.assertNotIn(b"A.TAP", spectrum.files)

    def test_reject_encryption_and_truncated_archive(self):
        archive = bytearray(make_zip([("A.TAP", b"data")]))
        central = archive.index(b"PK\x01\x02")
        archive[central+8] |= 1
        spectrum = Spectrum(archive)
        self.assertIn("Unsupported ZIP", spectrum.run())
        self.assertEqual(len(spectrum.files), 1)
        self.assertIn("Invalid or damaged ZIP", Spectrum(archive[:-10]).run())


if __name__ == "__main__":
    unittest.main()
