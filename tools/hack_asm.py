#!/usr/bin/env python3
"""
Minimal nand2tetris Hack assembler.

Usage:
  python tools/hack_asm.py input.asm [-o output.hack]
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


DEST_TABLE = {
    "": "000",
    "M": "001",
    "D": "010",
    "MD": "011",
    "A": "100",
    "AM": "101",
    "AD": "110",
    "AMD": "111",
}

JUMP_TABLE = {
    "": "000",
    "JGT": "001",
    "JEQ": "010",
    "JGE": "011",
    "JLT": "100",
    "JNE": "101",
    "JLE": "110",
    "JMP": "111",
}

COMP_TABLE = {
    "0": "0101010",
    "1": "0111111",
    "-1": "0111010",
    "D": "0001100",
    "A": "0110000",
    "!D": "0001101",
    "!A": "0110001",
    "-D": "0001111",
    "-A": "0110011",
    "D+1": "0011111",
    "A+1": "0110111",
    "D-1": "0001110",
    "A-1": "0110010",
    "D+A": "0000010",
    "D-A": "0010011",
    "A-D": "0000111",
    "D&A": "0000000",
    "D|A": "0010101",
    "M": "1110000",
    "!M": "1110001",
    "-M": "1110011",
    "M+1": "1110111",
    "M-1": "1110010",
    "D+M": "1000010",
    "D-M": "1010011",
    "M-D": "1000111",
    "D&M": "1000000",
    "D|M": "1010101",
}

# Commutative aliases accepted by reference-style assemblers.
COMP_TABLE.update(
    {
        "A+D": COMP_TABLE["D+A"],
        "M+D": COMP_TABLE["D+M"],
        "A&D": COMP_TABLE["D&A"],
        "M&D": COMP_TABLE["D&M"],
        "A|D": COMP_TABLE["D|A"],
        "M|D": COMP_TABLE["D|M"],
    }
)

BASE_SYMBOLS = {
    "SP": 0,
    "LCL": 1,
    "ARG": 2,
    "THIS": 3,
    "THAT": 4,
    "SCREEN": 16384,
    "KBD": 24576,
}
for i in range(16):
    BASE_SYMBOLS[f"R{i}"] = i

SYMBOL_RE = re.compile(r"^[A-Za-z_.$:][A-Za-z0-9_.$:]*$")


def _validate_symbol(symbol: str) -> None:
    if not SYMBOL_RE.fullmatch(symbol):
        raise ValueError(f"Invalid symbol name: {symbol!r}")


def _dest_bits(dest: str) -> str:
    # Accept any permutation of A/D/M without duplicates (e.g. DM, MA, AMD).
    if not dest:
        return DEST_TABLE[""]
    bits = {"A": "0", "D": "0", "M": "0"}
    for ch in dest:
        if ch not in bits:
            raise ValueError(f"Unknown dest field: {dest!r}")
        if bits[ch] == "1":
            raise ValueError(f"Duplicate register in dest field: {dest!r}")
        bits[ch] = "1"
    return bits["A"] + bits["D"] + bits["M"]


def clean_lines(src: str) -> list[str]:
    out: list[str] = []
    for raw in src.splitlines():
        line = raw.split("//", 1)[0].strip()
        if line:
            out.append(line)
    return out


def first_pass(lines: list[str]) -> dict[str, int]:
    symbols = dict(BASE_SYMBOLS)
    rom_addr = 0
    for line in lines:
        if line.startswith("(") and line.endswith(")"):
            label = line[1:-1].strip()
            if not label:
                raise ValueError("Empty label declaration")
            _validate_symbol(label)
            if label in symbols:
                raise ValueError(f"Duplicate label declaration: {label!r}")
            symbols[label] = rom_addr
            continue
        rom_addr += 1
    return symbols


def parse_c(line: str) -> str:
    if "=" in line:
        dest, rest = line.split("=", 1)
    else:
        dest, rest = "", line

    if ";" in rest:
        comp, jump = rest.split(";", 1)
    else:
        comp, jump = rest, ""

    dest = "".join(dest.split())
    comp = "".join(comp.split())
    jump = "".join(jump.split())

    if comp not in COMP_TABLE:
        raise ValueError(f"Unknown comp field: {comp!r}")
    if jump not in JUMP_TABLE:
        raise ValueError(f"Unknown jump field: {jump!r}")

    return "111" + COMP_TABLE[comp] + _dest_bits(dest) + JUMP_TABLE[jump]


def second_pass(lines: list[str], symbols: dict[str, int]) -> list[str]:
    next_var = 16
    out: list[str] = []
    for line in lines:
        if line.startswith("(") and line.endswith(")"):
            continue

        if line.startswith("@"):
            sym = line[1:].strip()
            if sym.isdigit():
                value = int(sym, 10)
            else:
                _validate_symbol(sym)
                if sym not in symbols:
                    symbols[sym] = next_var
                    next_var += 1
                value = symbols[sym]

            if value < 0 or value > 0x7FFF:
                if sym.isdigit():
                    raise ValueError(
                        f"A-instruction out of range: {line!r} (value={value}, allowed 0..32767)"
                    )
                raise ValueError(
                    f"A-instruction out of range: {line!r} "
                    f"(resolved {sym!r}={value}, allowed 0..32767)"
                )
            out.append(format(value, "016b"))
            continue

        out.append(parse_c(line))

    return out


def assemble(text: str) -> list[str]:
    lines = clean_lines(text)
    symbols = first_pass(lines)
    return second_pass(lines, symbols)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="Input .asm file")
    ap.add_argument("-o", "--output", type=Path, default=None, help="Output .hack file")
    args = ap.parse_args()

    src = args.input.read_text(encoding="ascii")
    machine = assemble(src)

    out_path = args.output or args.input.with_suffix(".hack")
    out_path.write_text("\n".join(machine) + "\n", encoding="ascii")
    print(f"[OK] Wrote {out_path} ({len(machine)} words)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
