#!/usr/bin/env python3
#------------------------------------------------------------------------------
# MIT License - bp3mitloader
# ---------------------------------------------------------------------------
# Copyright (c) [2026] by David Reguera Garcia aka Dreg
# https://github.com/therealdreg/bp3mitloader
# https://www.rootkit.es
# X @therealdreg
# dreg@rootkit.es
# ---------------------------------------------------------------------------
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#------------------------------------------------------------------------------
"""buzzloader.py: loads a firmware .hex into a Bus Pirate v3 through its bootloader.

It takes the command line of buzzloader 3.0 and prints the same lines, so scripts made for
buzzloader work with it. It talks to bootloader v4.x: bp3mitloader (v4.6) and ds30 v4.5.
It needs Python 3.8 or later and pyserial.

  python3 buzzloader.py --dev=PORT --hello
  python3 buzzloader.py --dev=PORT --hex=FIRMWARE.hex [--verbose] [--enter] [--run]
  python3 buzzloader.py --simulate --hex=FIRMWARE.hex [--verbose]
  python3 buzzloader.py --list

What it does differently from buzzloader 3.0:
- Page 42 holds the bootloader and the configuration words. It is skipped, so a v7.x file
  ends with success instead of ERROR [50].
- A file with code in the bootloader page, or one that starts with GOTO 0x00A800 (firmware
  and bootloader together, for a programmer), is refused before anything is written.
- HELLO goes up to 3 times.
- --enter, --run and --list are new.
"""
import argparse
import platform
import sys
import time

VERSION = "1.0"

FLASH_END = 0x00AC00      # PC address after the last instruction
BL_BASE = 0x00A800        # page 42: the bootloader and the configuration words
APP_SLOT = 0x00A7FC       # the GOTO to the firmware, written by the loader
CW2, CW1 = 0x00ABFC, 0x00ABFE
BL_CONFIG = {CW2: 0xF9DF, CW1: 0x3F7F}   # what bootloader v4.5 and v4.6 hold there
PAGE_PC = 0x400           # 512 instructions
ROW_PC = 0x80             # 64 instructions
ERASED = 0xFFFFFF

HELLO, RUN_FW, ACK = 0xC1, 0xE4, 0x4B
ANSWERS = {
    0x4E: "N: the bootloader refused the packet",
    0x50: "P: the address is protected or past the flash",
    0x56: "V: the row does not read back as sent",
}


class HexError(Exception):
    pass


def read_hex(path):
    """{PC address: 24-bit word} from a PIC24 Intel HEX file (byte address = 2 * PC, 4 bytes per word)."""
    words, base = {}, 0
    with open(path, encoding="ascii", errors="replace") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            if not line.startswith(":"):
                raise HexError(f"Line {n} does not start with ':'")
            try:
                rec = bytes.fromhex(line[1:])
            except ValueError:
                raise HexError(f"Incorrect characters on line {n}") from None
            if len(rec) < 5 or len(rec) != rec[0] + 5:
                raise HexError(f"Incorrect number of bytes, line {n}")
            if sum(rec) & 0xFF:
                raise HexError(f"Checksum does not match, line {n}")
            length, kind, data = rec[0], rec[3], rec[4:-1]
            if kind == 0x00:
                if length % 4:
                    raise HexError(f"Misaligned data, line {n}")
                pc = (base | (rec[1] << 8) | rec[2]) // 2
                for i in range(0, length, 4):
                    if pc >= FLASH_END:
                        raise HexError(f"Address 0x{pc:06X} is past the end of the flash, line {n}")
                    words[pc] = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16)
                    pc += 2
            elif kind == 0x04 and length == 2:
                base = (data[0] << 24) | (data[1] << 16)
            elif kind == 0x01:
                break
            else:
                raise HexError(f"Unsupported record type {kind:02x}, line {n}")
    return words


def check_bootloader_page(words):
    """Refuses files that would break the bootloader. Returns a note about page 42, or None."""
    if words.get(0x000000) == 0x04A800:
        raise HexError("The file starts with GOTO 0x00A800, so it holds a bootloader too. "
                       "It is made for a programmer: use the firmware-only file.")
    code = sorted(pc for pc in words if BL_BASE <= pc < CW2)
    if code:
        raise HexError(f"The file has {len(code)} words in the bootloader page, the first at "
                       f"0x{code[0]:06X}. That firmware does not fit with the bootloader.")
    cfg = {pc: words[pc] for pc in (CW2, CW1) if pc in words}
    if not cfg:
        return None
    if all((w & 0xFFFF) == BL_CONFIG[pc] for pc, w in cfg.items()):
        return "its configuration words are the same as the bootloader's"
    return ("WARNING: its configuration words differ from the bootloader's ("
            + ", ".join(f"0x{pc:06X} = 0x{w:06X}" for pc, w in cfg.items())
            + "). Bootloader v4.5 and v4.6 keep CW2 0xF9DF and CW1 0x3F7F")


def build_image(words):
    """The flash as buzzloader writes it, and the pages to send. The file's reset GOTO moves to
    0x00A7FC and 0x000000 gets GOTO 0x00A800. Words the file does not set are written erased."""
    image = dict(words)
    image[APP_SLOT] = words.get(0x000000, ERASED)
    image[APP_SLOT + 2] = words.get(0x000002, ERASED)
    image[0x000000], image[0x000002] = 0x04A800, 0x000000
    pages = {pc // PAGE_PC for pc in words} | {APP_SLOT // PAGE_PC}
    return image, pages


def packet(pc, cmd, payload=b""):
    head = bytes([(pc >> 16) & 0xFF, (pc >> 8) & 0xFF, pc & 0xFF, cmd, len(payload) + 1]) + payload
    return head + bytes([-sum(head) & 0xFF])


def row_payload(image, row):
    """64 instructions, 3 bytes each: bits 23:16, 7:0, 15:8."""
    out = bytearray()
    for pc in range(row, row + ROW_PC, 2):
        w = image.get(pc, ERASED)
        out += bytes([(w >> 16) & 0xFF, w & 0xFF, (w >> 8) & 0xFF])
    return bytes(out)


def dump(data):
    print("".join(f"{b:02X} " for b in data))


def read_bytes(s, count, seconds):
    end = time.monotonic() + seconds
    out = bytearray()
    while len(out) < count and time.monotonic() < end:
        out += s.read(count - len(out))
    return bytes(out)


def hello(s, tries=3, wait=1.0, pause=0.6):
    """HELLO until the bootloader answers. A packet cut halfway is dropped after 500 ms of silence."""
    got = b""
    for i in range(tries):
        s.reset_input_buffer()
        s.write(bytes([HELLO]))
        got = read_bytes(s, 4, wait)
        if len(got) == 4 and got[3] == ACK:
            return got
        if i + 1 < tries:
            time.sleep(pause)
    return got


def enter_bootloader(s):
    """'$' in a running Bus Pirate firmware, 'y' at its question, then HELLO right away: bootloader
    v4.5 only waits a short time after it."""
    s.reset_input_buffer()
    s.write(b"\r")
    time.sleep(0.3)
    s.reset_input_buffer()
    s.write(b"$\r")
    if b"sure" not in read_bytes(s, 64, 1.0):
        return b""
    s.write(b"y")
    time.sleep(0.05)
    return hello(s, tries=12, wait=0.25, pause=0.0)


def command(s, pkt):
    s.write(pkt)
    got = read_bytes(s, 1, 5.0)
    if not got:
        print("ERROR")
        print("No answer from the bootloader", file=sys.stderr)
        return False
    if got[0] != ACK:
        print(f"ERROR [{got[0]:02x}]")
        print(ANSWERS.get(got[0], "unknown answer"), file=sys.stderr)
        return False
    return True


def send_firmware(s, image, pages, verbose, note):
    """Erase + 8 rows for each page, in order, as buzzloader does. s is None to simulate."""
    for page in range(FLASH_END // PAGE_PC):
        base = page * PAGE_PC
        if page not in pages:
            if verbose:
                print(f"Skipping page {page} [ {base:06x} ], not used")
            continue
        if base >= BL_BASE:
            print(f"Skipping page {page} [ {base:06x} ], the bootloader page" + (f": {note}" if note else ""))
            continue
        pkt = packet(base, 0x01)
        if verbose:
            dump(pkt)
        print(f"Erasing page {page}, {base:04x}...", end="", flush=True)
        if s is not None and not command(s, pkt):
            return False
        print("OK")
        for r in range(8):
            row = base + r * ROW_PC
            pkt = packet(row, 0x02, row_payload(image, row))
            print(f"Writing page {page} row {page * 8 + r}, {row:04x}...", end="", flush=True)
            if s is not None and not command(s, pkt):
                return False
            print("OK")
            if verbose:
                dump(pkt)
    return True


def list_ports():
    from serial.tools import list_ports as lp
    ports = sorted(lp.comports(), key=lambda p: p.device)
    if not ports:
        print("No serial ports found")
    for p in ports:
        ids = f"{p.vid:04x}:{p.pid:04x}" if p.vid is not None else "         "
        mark = "   FTDI FT232R, maybe a Bus Pirate v3" if (p.vid, p.pid) == (0x0403, 0x6001) else ""
        print(f"{p.device:28s} {ids}  {p.description}{mark}")


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)   # keeps the order of the lines and the errors in a pipe
    os_name = {"Darwin": "macOS"}.get(platform.system(), platform.system() or "UNKNOWN")
    print("+++++++++++++++++++++++++++++++++++++++++++")
    print("  buzzloader.py  ")
    print(f"  Loader version: {VERSION}  OS: {os_name}")
    print("+++++++++++++++++++++++++++++++++++++++++++\n")

    ap = argparse.ArgumentParser(prog="buzzloader.py",
                                 description="Loads a firmware .hex into a Bus Pirate v3 through bootloader v4.x.")
    ap.add_argument("--dev", help="serial port of the Bus Pirate v3 (COM5, /dev/ttyUSB0, /dev/cu.usbserial-...)")
    ap.add_argument("--hex", help="firmware .hex file")
    ap.add_argument("--hello", action="store_true", help="only ask the bootloader who it is")
    ap.add_argument("--simulate", action="store_true", help="parse the file and print what would be sent, no port")
    ap.add_argument("--verbose", action="store_true", help="also print every packet and the pages not used")
    ap.add_argument("--enter", action="store_true",
                    help="if the bootloader does not answer, ask a running Bus Pirate firmware for it ($ and y)")
    ap.add_argument("--run", action="store_true", help="start the firmware (E4) at the end")
    ap.add_argument("--list", action="store_true", help="list the serial ports")
    if not argv:
        ap.print_usage()
        return 0
    a = ap.parse_args(argv)

    if a.list:
        list_ports()
        return 0

    image = pages = note = None
    if not a.hello and (a.hex or not a.run):
        if not a.hex:
            print("Please specify hexfile path --hex=/path/to/hexfile.hex", file=sys.stderr)
            return 1
        print(f"Parsing HEX file [{a.hex}]")
        try:
            words = read_hex(a.hex)
            if not words:
                raise HexError("No data in the file")
            note = check_bootloader_page(words)
        except (OSError, HexError) as e:
            print(f"Could not load HEX file: {e}", file=sys.stderr)
            return 1
        print(f"Found {len(words)} words ({len(words) * 3} bytes)")
        print("Fixing bootloader/userprogram jumps")
        image, pages = build_image(words)

    if a.simulate:
        if image is None:
            print("--simulate needs --hex", file=sys.stderr)
            return 1
        send_firmware(None, image, pages, a.verbose, note)
        return 0

    if not a.dev:
        print("Please specify serial device path --dev=/dev/...", file=sys.stderr)
        return 1
    try:
        import serial
    except ImportError:
        print("pyserial is missing: python3 -m pip install pyserial", file=sys.stderr)
        return 1

    print(f"Opening serial device {a.dev}...", end="", flush=True)
    try:
        s = serial.Serial(a.dev, 115200, bytesize=8, parity="N", stopbits=1, timeout=0.05, write_timeout=5)
    except (serial.SerialException, OSError, ValueError) as e:
        print("ERROR")
        print(f"Could not open {a.dev}: {e}", file=sys.stderr)
        return 1
    print("OK")
    print("Configuring serial port settings...OK")
    try:
        return session(s, a, image, pages, note)
    except KeyboardInterrupt:
        print("\nStopped. The bootloader keeps waiting: run the loader again.")
        return 1
    except serial.SerialException as e:
        print(f"\nSerial port error: {e}")
        return 1
    finally:
        s.close()


def session(s, a, image, pages, note):
    print("Sending Hello to the Bootloader...", end="", flush=True)
    got = hello(s, tries=1) if a.enter else hello(s)
    if a.enter and not (len(got) == 4 and got[3] == ACK):
        print("no answer")
        print("Asking the firmware for its bootloader ($ and y)...", end="", flush=True)
        got = enter_bootloader(s)
    if not (len(got) == 4 and got[3] == ACK):
        print("ERROR")
        print(f"No reply from the bootloader, or invalid reply received: {len(got)}", file=sys.stderr)
        print("Hold PGC low (a jumper between PGC and PGD, JP2 pins 1 and 2) and reset the Bus Pirate v3,"
              " or use --enter while its firmware runs.", file=sys.stderr)
        return 1
    print("OK\n")
    print(f"Device ID: {'PIC24FJ64GA002' if got[0] == 0xD4 else 'UNKNOWN'} [{got[0]:02x}]")
    print(f"Bootloader version: {got[1]},{got[2]:02d}")
    if got[0] != 0xD4:
        print(f"Unsupported device ({got[0]:02x}:UNKNOWN), only 0xD4 PIC24FJ64GA002 is supported", file=sys.stderr)
        return 1

    if image is not None:
        if not send_firmware(s, image, pages, a.verbose, note):
            print("\nError updating firmware :(")
            return 1
        print("\nFirmware updated successfully :)!")
        if platform.system() == "Windows":
            print(f"Use a terminal on {a.dev} at 115200 baud to verify")
        else:
            print(f"Use screen {a.dev} 115200 to verify")
    if a.run:
        print("Starting the firmware...", end="", flush=True)
        # Bootloader v4.5 takes E4 only while it waits for HELLO, so it goes after the 500 ms
        # receive timeout. A HELLO then tells whether the bootloader is still there.
        time.sleep(0.6)
        s.reset_input_buffer()
        s.write(bytes([RUN_FW]))
        time.sleep(0.5)
        s.reset_input_buffer()
        s.write(bytes([HELLO]))
        back = read_bytes(s, 4, 0.5)
        if len(back) == 4 and back[3] == ACK:
            print("ERROR")
            print("The bootloader still answers: is there a firmware?", file=sys.stderr)
            return 1
        print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
