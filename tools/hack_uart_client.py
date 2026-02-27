#!/usr/bin/env python3
"""
Hack UART bridge client.

Requires:
  pip install pyserial
"""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass

try:
    import serial
except Exception as exc:  # pragma: no cover
    print(f"[ERROR] pyserial import failed: {exc}", file=sys.stderr)
    print("Install with: pip install pyserial", file=sys.stderr)
    raise


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
    def __init__(self, port: str, baud: int, timeout: float = 1.0):
        self.ser = serial.Serial(port=port, baudrate=baud, timeout=timeout)

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


def cmd_watch(args: argparse.Namespace) -> int:
    cli = HackUartClient(args.port, args.baud, timeout=args.timeout)
    try:
        words_total = args.words_per_row * args.rows
        prev = [0] * words_total
        print("[INFO] watch mode, Ctrl+C to stop")
        while True:
            if args.run_cycles > 0:
                cli.run(args.run_cycles)

            cur = []
            for i in range(words_total):
                cur.append(cli.peek(0x4000 + i))

            changed = sum(1 for a, b in zip(prev, cur) if a != b)
            if changed > 0 or args.always_render:
                print(f"\n[frame] changed_words={changed}")
                print(render_screen_words(cur, args.words_per_row, args.rows))
            prev = cur
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print("\n[INFO] stopped")
        return 0
    finally:
        cli.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, help="Serial port, e.g. COM5")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--timeout", type=float, default=1.0)

    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("state")
    sub.add_parser("reset")
    sub.add_parser("step")
    sub.add_parser("halt")

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
    p_watch.add_argument("--always-render", action="store_true")

    args = ap.parse_args()

    if args.cmd == "watch":
        return cmd_watch(args)

    cli = HackUartClient(args.port, args.baud, timeout=args.timeout)
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
