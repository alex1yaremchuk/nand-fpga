#!/usr/bin/env python3
"""
Hack UART bridge client.

Requires:
  pip install pyserial
"""

from __future__ import annotations

import argparse
import json
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
CMD_DIAG = 0x0C
CMD_SEQ = 0x0D

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
RSP_DIAG = 0x8C
RSP_SEQ = 0x8D
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


@dataclass
class UartDiag:
    rx_err: int
    desync: int
    unknown_cmd: int
    retry_count: int
    seq_capable: bool


class HackUartClient:
    def __init__(
        self,
        port: str,
        baud: int,
        timeout: float = 1.0,
        open_retries: int = 0,
        open_retry_delay: float = 0.25,
        xfer_retries: int = 2,
        xfer_retry_delay: float = 0.02,
        seq_mode: str = "auto",
    ):
        last_exc: Exception | None = None
        retries = max(0, int(open_retries))
        delay = max(0.0, float(open_retry_delay))
        self.open_retry_count = 0

        for attempt in range(retries + 1):
            try:
                self.ser = serial.Serial(port=port, baudrate=baud, timeout=timeout)
                self.open_retry_count = attempt
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
        self.xfer_retries = max(0, int(xfer_retries))
        self.xfer_retry_delay = max(0.0, float(xfer_retry_delay))
        mode = str(seq_mode).strip().lower()
        if mode not in ("auto", "on", "off"):
            raise ValueError(f"invalid seq_mode '{seq_mode}', expected auto|on|off")
        self.seq_mode = mode
        self.seq_supported: bool | None = True if mode == "on" else (False if mode == "off" else None)
        self.seq_id = 0

    def close(self) -> None:
        self.ser.close()

    def _read_timeout_window(self) -> float:
        t = getattr(self.ser, "timeout", None)
        if isinstance(t, (int, float)) and t > 0:
            return float(t)
        return 0.25

    def _best_effort_drain_input(self) -> None:
        try:
            self.ser.reset_input_buffer()
        except Exception:
            try:
                waiting = int(getattr(self.ser, "in_waiting", 0) or 0)
                if waiting > 0:
                    self.ser.read(waiting)
            except Exception:
                pass

    def _read_exact(self, n: int) -> bytes:
        out = bytearray()
        timeout_window = self._read_timeout_window()
        deadline = time.monotonic() + timeout_window
        while len(out) < n:
            chunk = self.ser.read(n - len(out))
            if chunk:
                out.extend(chunk)
                deadline = time.monotonic() + timeout_window
                continue
            if time.monotonic() >= deadline:
                raise RuntimeError(f"short read: expected {n}, got {len(out)}")
        return bytes(out)

    def _next_seq_id(self) -> int:
        self.seq_id = (self.seq_id + 1) & 0xFF
        return self.seq_id

    def _supports_seq(self, cmd: int) -> bool:
        if cmd == CMD_SEQ:
            return False
        if cmd == CMD_DIAG:
            return False
        if self.seq_supported is True:
            return True
        if self.seq_supported is False:
            return False
        if self.seq_mode != "auto":
            return False
        try:
            self.seq_supported = self._probe_seq_support()
        except RuntimeError:
            self.seq_supported = False
        return bool(self.seq_supported)

    def _probe_seq_support(self) -> bool:
        rsp = self._xfer_legacy(bytes([CMD_DIAG]), 8, RSP_DIAG, allow_retry=True)
        return bool(rsp[7] & 0x01)

    def _xfer_legacy(self, payload: bytes, resp_len: int, expected_rsp: int, allow_retry: bool = True) -> bytes:
        attempts = (self.xfer_retries + 1) if allow_retry else 1
        last_exc: RuntimeError | None = None
        for attempt in range(attempts):
            if attempt > 0:
                self._best_effort_drain_input()
                if self.xfer_retry_delay > 0.0:
                    time.sleep(self.xfer_retry_delay)
            try:
                self.ser.write(payload)
                try:
                    self.ser.flush()
                except Exception:
                    pass
                rsp = self._read_exact(resp_len)
                if rsp[0] == RSP_ERR:
                    bad = rsp[1] if len(rsp) > 1 else 0
                    raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")
                if rsp[0] != expected_rsp:
                    raise RuntimeError(f"unexpected rsp: 0x{rsp[0]:02x}, expected 0x{expected_rsp:02x}")
                return rsp
            except RuntimeError as exc:
                last_exc = exc
                msg = str(exc).lower()
                is_retryable = ("short read" in msg) or ("unexpected rsp" in msg)
                if not allow_retry or not is_retryable or attempt >= (attempts - 1):
                    raise
        if last_exc is not None:
            raise last_exc
        raise RuntimeError("UART transfer failed")

    def _xfer_seq(self, payload: bytes, resp_len: int, expected_rsp: int, allow_retry: bool = True) -> bytes:
        cmd = payload[0] if payload else 0
        args = list(payload[1:])[:4]
        while len(args) < 4:
            args.append(0)
        seq = self._next_seq_id()
        frame = bytes([CMD_SEQ, seq, cmd, args[0], args[1], args[2], args[3]])

        attempts = (self.xfer_retries + 1) if allow_retry else 1
        last_exc: RuntimeError | None = None
        for attempt in range(attempts):
            if attempt > 0:
                self._best_effort_drain_input()
                if self.xfer_retry_delay > 0.0:
                    time.sleep(self.xfer_retry_delay)
            try:
                self.ser.write(frame)
                try:
                    self.ser.flush()
                except Exception:
                    pass

                b0 = self._read_exact(1)[0]
                if b0 == RSP_ERR:
                    bad = self._read_exact(1)[0]
                    if bad == CMD_SEQ:
                        raise RuntimeError("seq unsupported by device")
                    raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")

                if b0 != RSP_SEQ:
                    raise RuntimeError(f"unexpected rsp: 0x{b0:02x}, expected 0x{RSP_SEQ:02x}")

                hdr = self._read_exact(2)
                rsp_seq = hdr[0]
                inner_len = hdr[1]
                if rsp_seq != seq:
                    raise RuntimeError(f"seq mismatch: got 0x{rsp_seq:02x}, expected 0x{seq:02x}")

                inner = self._read_exact(inner_len)
                if len(inner) != resp_len:
                    raise RuntimeError(f"seq inner len mismatch: got {len(inner)}, expected {resp_len}")
                if inner and inner[0] == RSP_ERR:
                    bad = inner[1] if len(inner) > 1 else 0
                    raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")
                if not inner or inner[0] != expected_rsp:
                    got = inner[0] if inner else -1
                    raise RuntimeError(f"unexpected rsp: 0x{got:02x}, expected 0x{expected_rsp:02x}")

                self.seq_supported = True
                return inner
            except RuntimeError as exc:
                last_exc = exc
                msg = str(exc).lower()
                if "seq unsupported by device" in msg and self.seq_mode == "auto":
                    self.seq_supported = False
                    self._best_effort_drain_input()
                    if self.xfer_retry_delay > 0.0:
                        time.sleep(self.xfer_retry_delay)
                    return self._xfer_legacy(payload, resp_len, expected_rsp, allow_retry=allow_retry)
                is_retryable = ("short read" in msg) or ("unexpected rsp" in msg)
                if not allow_retry or not is_retryable or attempt >= (attempts - 1):
                    raise
        if last_exc is not None:
            raise last_exc
        raise RuntimeError("UART transfer failed")

    def _xfer(self, payload: bytes, resp_len: int, expected_rsp: int, allow_retry: bool = True) -> bytes:
        cmd = payload[0] if payload else 0
        if self._supports_seq(cmd):
            return self._xfer_seq(payload, resp_len, expected_rsp, allow_retry=allow_retry)
        return self._xfer_legacy(payload, resp_len, expected_rsp, allow_retry=allow_retry)

    def peek(self, addr: int) -> int:
        rsp = self._xfer(bytes([CMD_PEEK, u16_hi(addr), u16_lo(addr)]), 3, RSP_PEEK)
        return (rsp[1] << 8) | rsp[2]

    def poke(self, addr: int, data: int) -> None:
        self._xfer(bytes([CMD_POKE, u16_hi(addr), u16_lo(addr), u16_hi(data), u16_lo(data)]), 1, RSP_POKE)

    def step(self) -> CpuState:
        rsp = self._xfer(bytes([CMD_STEP]), 8, RSP_STEP, allow_retry=False)
        return CpuState(
            pc=(rsp[1] << 8) | rsp[2],
            a=(rsp[3] << 8) | rsp[4],
            d=(rsp[5] << 8) | rsp[6],
            run=rsp[7] & 1,
        )

    def run(self, cycles: int) -> CpuState:
        payload = bytes([CMD_RUN, (cycles >> 24) & 0xFF, (cycles >> 16) & 0xFF, (cycles >> 8) & 0xFF, cycles & 0xFF])
        rsp = self._xfer(payload, 8, RSP_RUN, allow_retry=False)
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

    def _parse_screen_delta_payload(self, payload: bytes) -> tuple[list[tuple[int, int]], bool, bool]:
        if len(payload) < 3:
            raise RuntimeError(f"scrdelta payload too short: {len(payload)}")
        if payload[0] == RSP_ERR:
            bad = payload[1] if len(payload) > 1 else 0
            raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")
        if payload[0] != RSP_SCRDELTA:
            raise RuntimeError(f"unexpected rsp: 0x{payload[0]:02x}, expected 0x{RSP_SCRDELTA:02x}")

        rsp_flags = payload[1]
        count = payload[2]
        expected = 3 + (count * 4)
        if len(payload) != expected:
            raise RuntimeError(f"scrdelta payload len mismatch: got {len(payload)}, expected {expected}")

        deltas: list[tuple[int, int]] = []
        off = 3
        for _ in range(count):
            addr = (payload[off] << 8) | payload[off + 1]
            data = (payload[off + 2] << 8) | payload[off + 3]
            deltas.append((addr, data))
            off += 4

        more_pending = bool(rsp_flags & 0x02)
        wrapped = bool(rsp_flags & 0x01)
        return deltas, more_pending, wrapped

    def _screen_delta_legacy(self, flags: int, max_entries: int) -> tuple[list[tuple[int, int]], bool, bool]:
        self.ser.write(bytes([CMD_SCRDELTA, flags, max_entries]))
        hdr = self._read_exact(3)
        count = hdr[2]
        body = self._read_exact(count * 4)
        return self._parse_screen_delta_payload(hdr + body)

    def _screen_delta_seq(self, flags: int, max_entries: int) -> tuple[list[tuple[int, int]], bool, bool]:
        seq = self._next_seq_id()
        frame = bytes([CMD_SEQ, seq, CMD_SCRDELTA, flags, max_entries, 0x00, 0x00])
        attempts = self.xfer_retries + 1
        last_exc: RuntimeError | None = None
        for attempt in range(attempts):
            if attempt > 0:
                self._best_effort_drain_input()
                if self.xfer_retry_delay > 0.0:
                    time.sleep(self.xfer_retry_delay)
            try:
                self.ser.write(frame)
                try:
                    self.ser.flush()
                except Exception:
                    pass

                b0 = self._read_exact(1)[0]
                if b0 == RSP_ERR:
                    bad = self._read_exact(1)[0]
                    if bad == CMD_SEQ and self.seq_mode == "auto":
                        self.seq_supported = False
                        self._best_effort_drain_input()
                        return self._screen_delta_legacy(flags, max_entries)
                    raise RuntimeError(f"device error, unknown cmd 0x{bad:02x}")
                if b0 != RSP_SEQ:
                    raise RuntimeError(f"unexpected rsp: 0x{b0:02x}, expected 0x{RSP_SEQ:02x}")

                seq_rsp = self._read_exact(1)[0]
                inner_len = self._read_exact(1)[0]
                if seq_rsp != seq:
                    raise RuntimeError(f"seq mismatch: got 0x{seq_rsp:02x}, expected 0x{seq:02x}")
                inner = self._read_exact(inner_len)
                self.seq_supported = True
                return self._parse_screen_delta_payload(inner)
            except RuntimeError as exc:
                last_exc = exc
                msg = str(exc).lower()
                is_retryable = ("short read" in msg) or ("unexpected rsp" in msg)
                if not is_retryable or attempt >= (attempts - 1):
                    raise
        if last_exc is not None:
            raise last_exc
        raise RuntimeError("UART transfer failed")

    def screen_delta(self, max_entries: int = 8, sync: bool = False) -> tuple[list[tuple[int, int]], bool, bool]:
        max_entries = max(1, min(max_entries, 15))
        flags = 0x01 if sync else 0x00
        if self._supports_seq(CMD_SCRDELTA):
            return self._screen_delta_seq(flags, max_entries)
        return self._screen_delta_legacy(flags, max_entries)

    def diag(self) -> UartDiag:
        rsp = self._xfer(bytes([CMD_DIAG]), 8, RSP_DIAG)
        rx_err = (rsp[1] << 8) | rsp[2]
        desync = (rsp[3] << 8) | rsp[4]
        unknown_cmd = (rsp[5] << 8) | rsp[6]
        seq_capable = bool(rsp[7] & 0x01)
        if self.seq_mode == "auto" and self.seq_supported is None:
            self.seq_supported = seq_capable
        return UartDiag(
            rx_err=rx_err,
            desync=desync,
            unknown_cmd=unknown_cmd,
            retry_count=self.open_retry_count,
            seq_capable=seq_capable,
        )


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


def fit_words_per_row(requested: int) -> tuple[int, int]:
    req = max(1, int(requested))
    try:
        cols = os.get_terminal_size().columns
    except OSError:
        return req, 0
    max_words = max(1, cols // 16)
    return min(req, max_words), cols


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
        # Extended keys arrive as a two-character sequence in Windows console.
        # Give the second byte a short time to arrive to avoid dropped arrows.
        if msvcrt is None:
            return None
        if not msvcrt.kbhit():
            time.sleep(0.001)
        if not msvcrt.kbhit():
            return None
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
        xfer_retries=args.xfer_retries,
        xfer_retry_delay=args.xfer_retry_delay,
        seq_mode=args.seq_mode,
    )
    try:
        words_per_row, term_cols = fit_words_per_row(args.words_per_row)
        if words_per_row != args.words_per_row and term_cols > 0:
            print(
                f"[WARN] words-per-row clamped {args.words_per_row}->{words_per_row} "
                f"to fit terminal width ({term_cols} cols)"
            )
        words_total = words_per_row * args.rows
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
                print(render_screen_words(cur, words_per_row, args.rows))
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
        xfer_retries=args.xfer_retries,
        xfer_retry_delay=args.xfer_retry_delay,
        seq_mode=args.seq_mode,
    )
    try:
        words_per_row, term_cols = fit_words_per_row(args.words_per_row)
        if words_per_row != args.words_per_row and term_cols > 0:
            print(
                f"[WARN] words-per-row clamped {args.words_per_row}->{words_per_row} "
                f"to fit terminal width ({term_cols} cols)"
            )
        words_total = words_per_row * args.rows
        screen_base = 0x4000
        cur = [cli.peek(screen_base + i) for i in range(words_total)]

        delta_mode = not args.no_delta
        if delta_mode:
            try:
                cli.screen_delta(max_entries=args.delta_limit, sync=True)
            except RuntimeError as exc:
                if "unknown cmd 0x0b" in str(exc).lower():
                    delta_mode = False
                else:
                    raise

        run_enabled = args.auto_run
        run_cycles = max(1, args.run_cycles)
        sticky_keys = bool(args.sticky_keys)
        max_key_events_per_frame = max(1, args.max_key_events_per_frame)
        key_hold_s = max(0.0, args.key_hold_ms / 1000.0)
        key_press_gap_s = max(0.0, args.key_press_gap_ms / 1000.0)
        key_release_at = 0.0
        kbd_clear_interval = max(0.0, args.kbd_clear_heartbeat_ms / 1000.0)
        next_kbd_clear_at = 0.0
        active_key_code: int | None = None
        last_key = "none"
        force_render = True

        # Start from a known key-up state before entering run loop.
        cli.kbd(0)
        if kbd_clear_interval > 0.0 and not sticky_keys:
            next_kbd_clear_at = time.monotonic() + kbd_clear_interval
        if not args.no_clear:
            clear_console()

        print("[INFO] viewer mode: q=quit, space=run/pause, r=reset, s=state, x=key up")
        print("[INFO] key press sends KBD code; release is sent automatically")
        while True:
            now = time.monotonic()
            key_events_processed = 0

            while msvcrt.kbhit() and key_events_processed < max_key_events_per_frame:
                ch = msvcrt.getwch()
                if ch == "\x03":  # Ctrl+C
                    return 0
                if ch in ("q", "Q"):
                    return 0
                if ch == " ":
                    run_enabled = not run_enabled
                    force_render = True
                    continue
                if ch in ("r", "R"):
                    cli.reset()
                    run_enabled = False
                    cli.kbd(0)
                    active_key_code = None
                    key_release_at = 0.0
                    if kbd_clear_interval > 0.0:
                        next_kbd_clear_at = time.monotonic() + kbd_clear_interval
                    last_key = "reset"
                    force_render = True
                    continue
                if ch in ("s", "S"):
                    st = cli.state()
                    print(f"\n[state] pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")
                    force_render = True
                    continue
                if ch in ("x", "X"):
                    cli.kbd(0)
                    active_key_code = None
                    key_release_at = 0.0
                    if kbd_clear_interval > 0.0:
                        next_kbd_clear_at = time.monotonic() + kbd_clear_interval
                    last_key = "up"
                    force_render = True
                    continue

                key_code = decode_hack_key_win(ch)
                if key_code is not None:
                    if sticky_keys:
                        if active_key_code != key_code:
                            cli.kbd(key_code)
                            active_key_code = key_code
                            if 32 <= key_code <= 126:
                                last_key = f"{chr(key_code)} (0x{key_code:02x})"
                            else:
                                last_key = f"0x{key_code:04x}"
                            force_render = True
                        key_events_processed += 1
                        continue

                    if active_key_code == key_code and key_release_at > 0.0:
                        key_release_at = max(key_release_at, time.monotonic() + key_hold_s)
                        key_events_processed += 1
                        continue
                    # Force a key-up edge before a new key press to avoid stale-key behavior.
                    if active_key_code is not None:
                        cli.kbd(0)
                        active_key_code = None
                        if key_press_gap_s > 0.0:
                            time.sleep(key_press_gap_s)
                    cli.kbd(key_code)
                    active_key_code = key_code
                    key_release_at = time.monotonic() + key_hold_s
                    if kbd_clear_interval > 0.0:
                        next_kbd_clear_at = key_release_at + kbd_clear_interval
                    if 32 <= key_code <= 126:
                        last_key = f"{chr(key_code)} (0x{key_code:02x})"
                    else:
                        last_key = f"0x{key_code:04x}"
                    force_render = True
                    key_events_processed += 1

            if not sticky_keys and key_release_at > 0.0 and now >= key_release_at:
                cli.kbd(0)
                active_key_code = None
                key_release_at = 0.0
                if kbd_clear_interval > 0.0:
                    next_kbd_clear_at = now + kbd_clear_interval
                last_key = "up(auto)"
                force_render = True
            elif (
                not sticky_keys
                and kbd_clear_interval > 0.0
                and active_key_code is None
                and now >= next_kbd_clear_at
            ):
                # Periodic key-up heartbeat prevents stale host-side key override
                # if a release frame is dropped during long UART sessions.
                cli.kbd(0)
                next_kbd_clear_at = now + kbd_clear_interval

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

            if changed > 0 or args.always_render or force_render:
                if not args.no_clear:
                    if args.hard_clear_per_frame:
                        clear_console()
                    else:
                        home_cursor()
                mode = "delta" if delta_mode else "peek"
                run_text = "RUN" if run_enabled else "PAUSE"
                suffix = f", packets={packets}" if delta_mode else ""
                last_key_fixed = last_key[:20].ljust(20)
                print(
                    f"[viewer] mode={mode} {run_text} changed_words={changed}{suffix} last_key={last_key_fixed}\n"
                )
                print(render_screen_words(cur, words_per_row, args.rows))
                sys.stdout.flush()
                force_render = False

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
        xfer_retries=args.xfer_retries,
        xfer_retry_delay=args.xfer_retry_delay,
        seq_mode=args.seq_mode,
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
        xfer_retries=args.xfer_retries,
        xfer_retry_delay=args.xfer_retry_delay,
        seq_mode=args.seq_mode,
    )
    try:
        print(f"[INFO] Programming ROM words: {len(hack_words)}")
        # Keep host-driven keyboard override deterministic across sessions.
        # top.v does not clear UART keyboard override on CPU reset alone.
        cli.kbd(0)
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
    ap.add_argument("--xfer-retries", type=int, default=2)
    ap.add_argument("--xfer-retry-delay", type=float, default=0.02)
    ap.add_argument("--seq-mode", choices=("auto", "on", "off"), default="auto")

    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("state")
    p_diag = sub.add_parser("diag")
    p_diag.add_argument("--json", action="store_true")
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
    p_view.add_argument("--interval", type=float, default=0.08)
    p_view.add_argument("--run-cycles", type=int, default=8)
    p_view.add_argument("--auto-run", action="store_true")
    p_view.add_argument("--delta-limit", type=int, default=12)
    p_view.add_argument("--max-delta-packets", type=int, default=8)
    p_view.add_argument("--key-hold-ms", type=int, default=60)
    p_view.add_argument("--key-press-gap-ms", type=int, default=2)
    p_view.add_argument("--max-key-events-per-frame", type=int, default=8)
    p_view.add_argument("--kbd-clear-heartbeat-ms", type=int, default=250)
    p_view.add_argument("--sticky-keys", action="store_true")
    p_view.add_argument("--no-delta", action="store_true")
    p_view.add_argument("--always-render", action="store_true")
    p_view.add_argument("--no-clear", action="store_true")
    p_view.add_argument("--hard-clear-per-frame", action="store_true")

    p_runhack = sub.add_parser("runhack")
    p_runhack.add_argument("--hack-file", required=True)
    p_runhack.add_argument("--cycles", type=int, default=20000)
    p_runhack.add_argument("--rom-addr-w", type=int, default=14)
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
        xfer_retries=args.xfer_retries,
        xfer_retry_delay=args.xfer_retry_delay,
        seq_mode=args.seq_mode,
    )
    try:
        if args.cmd == "state":
            st = cli.state()
            print(f"pc=0x{st.pc:04x} a=0x{st.a:04x} d=0x{st.d:04x} run={st.run}")
        elif args.cmd == "diag":
            d = cli.diag()
            if args.json:
                print(
                    json.dumps(
                        {
                            "rx_err": d.rx_err,
                            "desync": d.desync,
                            "unknown_cmd": d.unknown_cmd,
                            "retry_count": d.retry_count,
                            "seq_capable": d.seq_capable,
                        }
                    )
                )
            else:
                print(
                    f"rx_err={d.rx_err} desync={d.desync} "
                    f"unknown_cmd={d.unknown_cmd} retry_count={d.retry_count} "
                    f"seq_capable={int(d.seq_capable)}"
                )
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
