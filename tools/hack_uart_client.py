#!/usr/bin/env python3
"""
Hack UART bridge client.

Requires:
  pip install pyserial
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    import serial
except Exception as exc:  # pragma: no cover
    print(f"[ERROR] pyserial import failed: {exc}", file=sys.stderr)
    print("Install with: pip install pyserial", file=sys.stderr)
    raise

if os.name == "nt":
    import msvcrt
else:  # pragma: no cover
    msvcrt = None


CMD_PEEK = 0x01
CMD_POKE = 0x02
CMD_STEP = 0x03
CMD_RUN = 0x04
CMD_RESET = 0x05
CMD_STATE = 0x06
CMD_KBD = 0x07
CMD_ROMW = 0x08
CMD_ROMR = 0x09
CMD_HALT = 0x0A
CMD_SCRDELTA = 0x0B

RSP_PEEK = 0x81
RSP_POKE = 0x82
RSP_STEP = 0x83
RSP_RUN = 0x84
RSP_RESET = 0x85
RSP_STATE = 0x86
RSP_KBD = 0x87
RSP_ROMW = 0x88
RSP_ROMR = 0x89
RSP_HALT = 0x8A
RSP_SCRDELTA = 0x8B
RSP_ERR = 0xFF


def parse_int(s: str) -> int:
    s = s.strip().lower()
    if s.startswith("0x"):
        return int(s, 16)
    if s.endswith("h"):
        return int(s[:-1], 16)
    return int(s, 10)


def u16_hi(x: int) -> int:
    return (x >> 8) & 0xFF


def u16_lo(x: int) -> int:
    return x & 0xFF


@dataclass
class CpuState:
    pc: int
    a: int
    d: int
    run: int


class HackUartClient:
    def __init__(
        self,
        port: str,
        baud: int,
        timeout: float = 1.0,
        open_retries: int = 0,
        open_retry_delay: float = 0.25,
    ):
        last_exc: Exception | None = None
        retries = max(0, int(open_retries))
        delay = max(0.0, float(open_retry_delay))

        for attempt in range(retries + 1):
            try:
                self.ser = serial.Serial(port=port, baudrate=baud, timeout=timeout)
                break
            except Exception as exc:
                last_exc = exc
                if attempt >= retries:
                    msg = str(exc)
                    if "Access is denied" in msg or "PermissionError" in msg:
                        raise RuntimeError(
                            f"could not open port '{port}': access denied (port is busy, close other UART tools first)"
                        ) from exc
                    raise
                time.sleep(delay)
        if not hasattr(self, "ser"):
            raise RuntimeError(f"could not open port '{port}': {last_exc}")

    def close(self) -> None:
        self.ser.close()

    def _read_exact(self, n: int) -> bytes:
        data = self.ser.read(n)
        if len(data) != n:
            raise RuntimeError(f"short read: expected {n}, got {len(data)}")
        return data

    def _xfer(self, payload: bytes, resp_len: int, expected_rsp: int) -> bytes:
        self.ser.write(payload)
        rsp = self._read_exact(resp_len)
        if rsp[0] == RSP_ERR:
            bad = rsp[1] if len(rsp) > 1 else 0
            raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")
        if rsp[0] != expected_rsp:
            raise RuntimeError(f"unexpected rsp: 0x{rsp[0]:02x}, expected 0x{expected_rsp:02x}")
        return rsp

    def peek(self, addr: int) -> int:
        rsp = self._xfer(bytes([CMD_PEEK, u16_hi(addr), u16_lo(addr)]), 3, RSP_PEEK)
        return (rsp[1] << 8) | rsp[2]

    def poke(self, addr: int, data: int) -> None:
        self._xfer(bytes([CMD_POKE, u16_hi(addr), u16_lo(addr), u16_hi(data), u16_lo(data)]), 1, RSP_POKE)

    def step(self) -> CpuState:
        rsp = self._xfer(bytes([CMD_STEP]), 8, RSP_STEP)
        return CpuState(
            pc=(rsp[1] << 8) | rsp[2],
            a=(rsp[3] << 8) | rsp[4],
            d=(rsp[5] << 8) | rsp[6],
            run=rsp[7] & 1,
        )

    def run(self, cycles: int) -> CpuState:
        payload = bytes([CMD_RUN, (cycles >> 24) & 0xFF, (cycles >> 16) & 0xFF, (cycles >> 8) & 0xFF, cycles & 0xFF])
        rsp = self._xfer(payload, 8, RSP_RUN)
        return CpuState(
            pc=(rsp[1] << 8) | rsp[2],
            a=(rsp[3] << 8) | rsp[4],
            d=(rsp[5] << 8) | rsp[6],
            run=rsp[7] & 1,
        )

    def reset(self) -> None:
        self._xfer(bytes([CMD_RESET]), 1, RSP_RESET)

    def state(self) -> CpuState:
        rsp = self._xfer(bytes([CMD_STATE]), 8, RSP_STATE)
        return CpuState(
            pc=(rsp[1] << 8) | rsp[2],
            a=(rsp[3] << 8) | rsp[4],
            d=(rsp[5] << 8) | rsp[6],
            run=rsp[7] & 1,
        )

    def kbd(self, data: int) -> None:
        self._xfer(bytes([CMD_KBD, u16_hi(data), u16_lo(data)]), 1, RSP_KBD)

    def romw(self, addr: int, data: int) -> None:
        self._xfer(bytes([CMD_ROMW, u16_hi(addr), u16_lo(addr), u16_hi(data), u16_lo(data)]), 1, RSP_ROMW)

    def romr(self, addr: int) -> int:
        rsp = self._xfer(bytes([CMD_ROMR, u16_hi(addr), u16_lo(addr)]), 3, RSP_ROMR)
        return (rsp[1] << 8) | rsp[2]

    def halt(self) -> None:
        self._xfer(bytes([CMD_HALT]), 1, RSP_HALT)

    def screen_delta(self, max_entries: int = 8, sync: bool = False) -> tuple[list[tuple[int, int]], bool, bool]:
        max_entries = max(1, min(max_entries, 15))
        flags = 0x01 if sync else 0x00
        self.ser.write(bytes([CMD_SCRDELTA, flags, max_entries]))
        hdr = self._read_exact(3)
        if hdr[0] == RSP_ERR:
            bad = hdr[1] if len(hdr) > 1 else 0
            raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")
        if hdr[0] != RSP_SCRDELTA:
            raise RuntimeError(f"unexpected rsp: 0x{hdr[0]:02x}, expected 0x{RSP_SCRDELTA:02x}")

        rsp_flags = hdr[1]
        count = hdr[2]
        body = self._read_exact(count * 4)
        deltas: list[tuple[int, int]] = []
        for i in range(count):
            off = i * 4
            addr = (body[off] << 8) | body[off + 1]
            data = (body[off + 2] << 8) | body[off + 3]
            deltas.append((addr, data))

        more_pending = bool(rsp_flags & 0x02)
        wrapped = bool(rsp_flags & 0x01)
        return deltas, more_pending, wrapped


def render_screen_words(words: list[int], words_per_row: int, rows: int) -> str:
    out: list[str] = []
    for y in range(rows):
        row = []
        base = y * words_per_row
        for wi in range(words_per_row):
            w = words[base + wi] if (base + wi) < len(words) else 0
            for b in range(16):
                row.append("#" if ((w >> b) & 1) else ".")
        out.append("".join(row))
    return "\n".join(out)


def clear_console() -> None:
    print("\x1b[2J\x1b[H", end="")


def home_cursor() -> None:
    print("\x1b[H", end="")


def decode_hack_key_win(ch0: str) -> int | None:
    # Hack keyboard codes:
    # ascii 32..126, enter=128, backspace=129, arrows 130..133, esc=140.
    if ch0 == "\r":
        return 128
    if ch0 == "\b":
        return 129
    if ch0 == "\x1b":
        return 140

    if ch0 in ("\x00", "\xe0"):
        ch1 = msvcrt.getwch()
        ext = {
            "K": 130,  # left
            "H": 131,  # up
            "M": 132,  # right
            "P": 133,  # down
            "G": 134,  # home
            "O": 135,  # end
            "I": 136,  # page up
            "Q": 137,  # page down
            "R": 138,  # insert
            "S": 139,  # delete
        }
        return ext.get(ch1)

    if len(ch0) == 1:
        code = ord(ch0)
        if 32 <= code <= 126:
            return code
    return None


def parse_hack_words(path: str) -> list[int]:
    words: list[int] = []
    with open(path, "r", encoding="ascii") as f:
        for line_no, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("//"):
                continue
            if not re.fullmatch(r"[01]{16}", s):
                raise RuntimeError(f"invalid .hack line {line_no}: '{s}'")
            words.append(int(s, 2))
    return words


def parse_ram_init_lines(path: str) -> list[tuple[int, int]]:
    out: list[tuple[int, int]] = []
    with open(path, "r", encoding="ascii") as f:
        for line_no, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("//"):
                continue
            parts = s.split()
            if len(parts) != 2:
                raise RuntimeError(f"invalid RAM init line {line_no}: '{s}'")
            try:
                addr = int(parts[0], 16) & 0x7FFF
                data = int(parts[1], 16) & 0xFFFF
            except ValueError as exc:
                raise RuntimeError(f"invalid RAM init line {line_no}: '{s}' ({exc})") from exc
            out.append((addr, data))
    return out


def write_pc_dump(path: Path, st: CpuState) -> None:
    text = (
        f"PC {st.pc} 0x{st.pc:04x}\n"
        f"A  {st.a} 0x{st.a:04x}\n"
        f"D  {st.d} 0x{st.d:04x}\n"
    )
    path.write_text(text, encoding="ascii")


def write_word_dump(path: Path, values: list[int], addr_base: int = 0) -> None:
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for i, v in enumerate(values):
            f.write(f"{addr_base + i:08d} {v:04x}\n")


def cmd_watch(args: argparse.Namespace) -> int:
    cli = HackUartClient(
        args.port,
        args.baud,
        timeout=args.timeout,
        open_retries=args.open_retries,
        open_retry_delay=args.open_retry_delay,
    )
    try:
        words_total = args.words_per_row * args.rows
        screen_base = 0x4000
        cur = [cli.peek(screen_base + i) for i in range(words_total)]
        delta_mode = True
        try:
            cli.screen_delta(max_entries=args.delta_limit, sync=True)
        except RuntimeError as exc:
            if "unknown cmd 0x0b" in str(exc).lower():
                delta_mode = False
                print("[WARN] SCRDELTA unsupported by device, fallback to PEEK polling")
            else:
                raise

        print("[INFO] watch mode, Ctrl+C to stop")
        print(f"[INFO] mode={'delta' if delta_mode else 'peek'}")
        while True:
            if args.run_cycles > 0:
                cli.run(args.run_cycles)

            changed = 0
            packets = 0
            if delta_mode:
                while True:
                    deltas, more_pending, _wrapped = cli.screen_delta(max_entries=args.delta_limit, sync=False)
                    packets += 1
                    for addr, data in deltas:
                        idx = addr - screen_base
                        if 0 <= idx < words_total and cur[idx] != data:
                            cur[idx] = data
                            changed += 1
                    if not more_pending or packets >= args.max_delta_packets:
                        break
            else:
                nxt = [cli.peek(screen_base + i) for i in range(words_total)]
                changed = sum(1 for a, b in zip(cur, nxt) if a != b)
                cur = nxt

            if changed > 0 or args.always_render:
                suffix = f" packets={packets}" if delta_mode else ""
                print(f"\n[frame] changed_words={changed}{suffix}")
                print(render_screen_words(cur, args.words_per_row, args.rows))
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n[INFO] stopped")
        return 0
    finally:
        cli.close()


def cmd_viewer(args: argparse.Namespace) -> int:
    if msvcrt is None:
        raise RuntimeError("viewer mode is supported only on Windows console")

    cli = HackUartClient(
        args.port,
        args.baud,
        timeout=args.timeout,
        open_retries=args.open_retries,
        open_retry_delay=args.open_retry_delay,
    )
    try:
        words_total = args.words_per_row * args.rows
        screen_base = 0x4000
        cur = [cli.peek(screen_base + i) for i in range(words_total)]

        delta_mode = True
        try:
            cli.screen_delta(max_entries=args.delta_limit, sync=True)
        except RuntimeError as exc:
            if "unknown cmd 0x0b" in str(exc).lower():
                delta_mode = False
            else:
                raise

        run_enabled = args.auto_run
        run_cycles = max(1, args.run_cycles)
        key_release_at = 0.0
        last_key = "none"
        if not args.no_clear:
            clear_console()

        print("[INFO] viewer mode: q=quit, space=run/pause, r=reset, s=state, x=key up")
        print("[INFO] key press sends KBD code; release is sent automatically")
        while True:
            now = time.monotonic()

            while msvcrt.kbhit():
                ch = msvcrt.getwch()
                if ch == "\x03":  # Ctrl+C
                    return 0
                if ch in ("q", "Q"):
                    return 0
                if ch == " ":
                    run_enabled = not run_enabled
                    continue
                if ch in ("r", "R"):
                    cli.reset()
                    run_enabled = False
                    cli.kbd(0)
                    key_release_at = 0.0
                    last_key = "reset"
                    continue
                if ch in ("s", "S"):
                    st = cli.state()
                    print(f"\n[state] pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")
                    continue
                if ch in ("x", "X"):
                    cli.kbd(0)
                    key_release_at = 0.0
                    last_key = "up"
                    continue

                key_code = decode_hack_key_win(ch)
                if key_code is not None:
                    cli.kbd(key_code)
                    key_release_at = time.monotonic() + (args.key_hold_ms / 1000.0)
                    if 32 <= key_code <= 126:
                        last_key = f"{chr(key_code)} (0x{key_code:02x})"
                    else:
                        last_key = f"0x{key_code:04x}"

            if key_release_at > 0.0 and now >= key_release_at:
                cli.kbd(0)
                key_release_at = 0.0

            if run_enabled:
                cli.run(run_cycles)

            changed = 0
            packets = 0
            if delta_mode:
                while True:
                    deltas, more_pending, _wrapped = cli.screen_delta(max_entries=args.delta_limit, sync=False)
                    packets += 1
                    for addr, data in deltas:
                        idx = addr - screen_base
                        if 0 <= idx < words_total and cur[idx] != data:
                            cur[idx] = data
                            changed += 1
                    if not more_pending or packets >= args.max_delta_packets:
                        break
            else:
                nxt = [cli.peek(screen_base + i) for i in range(words_total)]
                changed = sum(1 for a, b in zip(cur, nxt) if a != b)
                cur = nxt

            if changed > 0 or args.always_render:
                if not args.no_clear:
                    home_cursor()
                mode = "delta" if delta_mode else "peek"
                run_text = "RUN" if run_enabled else "PAUSE"
                suffix = f", packets={packets}" if delta_mode else ""
                print(
                    f"[viewer] mode={mode} {run_text} changed_words={changed}{suffix} last_key={last_key}\n"
                )
                print(render_screen_words(cur, args.words_per_row, args.rows))
                sys.stdout.flush()

            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        try:
            cli.kbd(0)
        except Exception:
            pass
        cli.close()


def cmd_scrdelta(args: argparse.Namespace) -> int:
    cli = HackUartClient(
        args.port,
        args.baud,
        timeout=args.timeout,
        open_retries=args.open_retries,
        open_retry_delay=args.open_retry_delay,
    )
    try:
        deltas, more_pending, wrapped = cli.screen_delta(max_entries=args.max_entries, sync=args.sync)
        print(f"count={len(deltas)} more={int(more_pending)} wrapped={int(wrapped)}")
        for addr, data in deltas:
            print(f"0x{addr:04x}:0x{data:04x}")
        return 0
    finally:
        cli.close()


def cmd_runhack(args: argparse.Namespace) -> int:
    if args.rom_addr_w < 1 or args.rom_addr_w > 15:
        raise RuntimeError(f"rom_addr_w must be in [1..15], got {args.rom_addr_w}")

    hack_words = parse_hack_words(args.hack_file)
    rom_words = 1 << args.rom_addr_w
    if len(hack_words) > rom_words:
        raise RuntimeError(f"program does not fit ROM: {len(hack_words)} > {rom_words}")

    ram_init: list[tuple[int, int]] = []
    if args.ram_init_file:
        ram_init = parse_ram_init_lines(args.ram_init_file)

    out_dir = Path(args.out_dir)
    if not out_dir.is_absolute():
        out_dir = Path.cwd() / out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    pc_dump = out_dir / "pc_dump.txt"
    ram_dump = out_dir / "ram_dump.txt"
    screen_dump = out_dir / "screen_dump.txt"

    cli = HackUartClient(
        args.port,
        args.baud,
        timeout=args.timeout,
        open_retries=args.open_retries,
        open_retry_delay=args.open_retry_delay,
    )
    try:
        print(f"[INFO] Programming ROM words: {len(hack_words)}")
        cli.halt()
        cli.reset()
        for i, w in enumerate(hack_words):
            cli.romw(i, w)
            if args.rom_verify:
                ok = False
                for attempt in range(args.rom_write_retries + 1):
                    got = cli.romr(i)
                    if got == w:
                        ok = True
                        break
                    cli.romw(i, w)
                if not ok:
                    raise RuntimeError(
                        f"ROM verify mismatch at {i:04x}: got {got:04x}, expected {w:04x}"
                    )
            if ((i + 1) % 256) == 0:
                print(f"[INFO] ROM loaded: {i + 1}/{len(hack_words)}")

        if args.rom_verify:
            print("[INFO] Verifying ROM...")
            for i, expected in enumerate(hack_words):
                got = cli.romr(i)
                if got != expected:
                    raise RuntimeError(f"ROM verify mismatch at {i:04x}: got {got:04x}, expected {expected:04x}")

        if args.clear_ram_words > 0:
            print(f"[INFO] Clearing RAM words: base=0x{args.clear_ram_base:04x}, count={args.clear_ram_words}")
            for i in range(args.clear_ram_words):
                cli.poke(args.clear_ram_base + i, 0)

        if args.clear_screen_words > 0:
            print(f"[INFO] Clearing SCREEN words: count={args.clear_screen_words}")
            for i in range(args.clear_screen_words):
                cli.poke(0x4000 + i, 0)

        if ram_init:
            print(f"[INFO] Applying RAM init entries: {len(ram_init)}")
            for addr, data in ram_init:
                cli.poke(addr, data)

        cli.halt()
        cli.reset()

        cycles_total = max(0, args.cycles)
        cycles_left = cycles_total
        run_chunk = max(1, args.run_chunk)
        st: CpuState | None = None
        if args.exec_mode == "run":
            while cycles_left > 0:
                step = min(run_chunk, cycles_left)
                st = cli.run(step)
                cycles_left -= step
        else:
            if cycles_total > 0:
                print(f"[INFO] Executing with STEP mode: cycles={cycles_total}")
            for i in range(cycles_total):
                st = cli.step()
                if ((i + 1) % 1000) == 0:
                    print(f"[INFO] Step progress: {i + 1}/{cycles_total}")

        if st is None:
            st = cli.state()
        cli.halt()
        print(f"[INFO] Final state: pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")

        ram_vals = [cli.peek(args.ram_base + i) for i in range(max(0, args.ram_words))]
        screen_vals = [cli.peek(0x4000 + i) for i in range(max(0, args.screen_words))]

        write_pc_dump(pc_dump, st)
        write_word_dump(ram_dump, ram_vals, addr_base=args.ram_base)
        write_word_dump(screen_dump, screen_vals, addr_base=0)

        print("[OK] FPGA UART run completed.")
        print(f"  PC dump    : {pc_dump}")
        print(f"  RAM dump   : {ram_dump}")
        print(f"  SCREEN dump: {screen_dump}")
        return 0
    finally:
        cli.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="Serial port, e.g. COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=1.0)
    ap.add_argument("--open-retries", type=int, default=8)
    ap.add_argument("--open-retry-delay", type=float, default=0.25)

    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("state")
    sub.add_parser("reset")
    sub.add_parser("step")
    sub.add_parser("halt")
    p_scrdelta = sub.add_parser("scrdelta")
    p_scrdelta.add_argument("--max-entries", type=int, default=8)
    p_scrdelta.add_argument("--sync", action="store_true")

    p_run = sub.add_parser("run")
    p_run.add_argument("cycles", type=parse_int)

    p_peek = sub.add_parser("peek")
    p_peek.add_argument("addr", type=parse_int)

    p_poke = sub.add_parser("poke")
    p_poke.add_argument("addr", type=parse_int)
    p_poke.add_argument("data", type=parse_int)

    p_romr = sub.add_parser("romr")
    p_romr.add_argument("addr", type=parse_int)

    p_romw = sub.add_parser("romw")
    p_romw.add_argument("addr", type=parse_int)
    p_romw.add_argument("data", type=parse_int)

    p_kbd = sub.add_parser("kbd")
    p_kbd.add_argument("data", type=parse_int)

    p_watch = sub.add_parser("watch")
    p_watch.add_argument("--words-per-row", type=int, default=8)
    p_watch.add_argument("--rows", type=int, default=8)
    p_watch.add_argument("--interval", type=float, default=0.2)
    p_watch.add_argument("--run-cycles", type=int, default=0)
    p_watch.add_argument("--delta-limit", type=int, default=12)
    p_watch.add_argument("--max-delta-packets", type=int, default=8)
    p_watch.add_argument("--always-render", action="store_true")

    p_view = sub.add_parser("viewer")
    p_view.add_argument("--words-per-row", type=int, default=8)
    p_view.add_argument("--rows", type=int, default=8)
    p_view.add_argument("--interval", type=float, default=0.1)
    p_view.add_argument("--run-cycles", type=int, default=500)
    p_view.add_argument("--auto-run", action="store_true")
    p_view.add_argument("--delta-limit", type=int, default=12)
    p_view.add_argument("--max-delta-packets", type=int, default=8)
    p_view.add_argument("--key-hold-ms", type=int, default=80)
    p_view.add_argument("--always-render", action="store_true")
    p_view.add_argument("--no-clear", action="store_true")

    p_runhack = sub.add_parser("runhack")
    p_runhack.add_argument("--hack-file", required=True)
    p_runhack.add_argument("--cycles", type=int, default=20000)
    p_runhack.add_argument("--rom-addr-w", type=int, default=13)
    p_runhack.add_argument("--ram-base", type=parse_int, default=0)
    p_runhack.add_argument("--ram-words", type=int, default=256)
    p_runhack.add_argument("--screen-words", type=int, default=256)
    p_runhack.add_argument("--ram-init-file", default="")
    p_runhack.add_argument("--clear-ram-base", type=parse_int, default=0)
    p_runhack.add_argument("--clear-ram-words", type=int, default=0)
    p_runhack.add_argument("--clear-screen-words", type=int, default=0)
    p_runhack.add_argument("--run-chunk", type=int, default=50000)
    p_runhack.add_argument("--rom-verify", action="store_true")
    p_runhack.add_argument("--rom-write-retries", type=int, default=2)
    p_runhack.add_argument("--out-dir", default="build/fpga_uart_run")
    p_runhack.add_argument("--exec-mode", choices=("run", "step"), default="run")

    args = ap.parse_args()

    if args.cmd == "watch":
        return cmd_watch(args)
    if args.cmd == "viewer":
        return cmd_viewer(args)
    if args.cmd == "scrdelta":
        return cmd_scrdelta(args)
    if args.cmd == "runhack":
        return cmd_runhack(args)

    cli = HackUartClient(
        args.port,
        args.baud,
        timeout=args.timeout,
        open_retries=args.open_retries,
        open_retry_delay=args.open_retry_delay,
    )
    try:
        if args.cmd == "state":
            st = cli.state()
            print(f"pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")
        elif args.cmd == "reset":
            cli.reset()
            print("ok")
        elif args.cmd == "step":
            st = cli.step()
            print(f"pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")
        elif args.cmd == "run":
            st = cli.run(args.cycles)
            print(f"pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")
        elif args.cmd == "peek":
            data = cli.peek(args.addr)
            print(f"0x{data:04x}")
        elif args.cmd == "poke":
            cli.poke(args.addr, args.data)
            print("ok")
        elif args.cmd == "romr":
            data = cli.romr(args.addr)
            print(f"0x{data:04x}")
        elif args.cmd == "romw":
            cli.romw(args.addr, args.data)
            print("ok")
        elif args.cmd == "kbd":
            cli.kbd(args.data)
            print("ok")
        elif args.cmd == "halt":
            cli.halt()
            print("ok")
        else:
            raise RuntimeError(f"unsupported command: {args.cmd}")
    finally:
        cli.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
