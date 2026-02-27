#!/usr/bin/env python3
"""
Render Hack screen_dump.txt to PBM image (no external dependencies).

Input format per line:
  <addr_hex> <word_hex>
Example:
  00000000 ffff
"""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_dump(path: Path) -> dict[int, int]:
    data: dict[int, int] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        s = line.strip()
        if not s:
            continue
        parts = s.split()
        if len(parts) < 2:
            continue
        addr = int(parts[0], 16)
        word = int(parts[1], 16) & 0xFFFF
        data[addr] = word
    return data


def write_pbm(data: dict[int, int], out: Path, words_per_row: int, rows: int) -> None:
    width = words_per_row * 16
    height = rows
    with out.open("w", encoding="ascii", newline="\n") as f:
        f.write("P1\n")
        f.write(f"{width} {height}\n")
        for y in range(height):
            row_bits: list[str] = []
            base = y * words_per_row
            for w in range(words_per_row):
                word = data.get(base + w, 0)
                for b in range(16):
                    # Hack screen: bit0 is left-most pixel in a word.
                    bit = (word >> b) & 1
                    row_bits.append("1" if bit else "0")
            f.write(" ".join(row_bits))
            f.write("\n")


def preview_ascii(data: dict[int, int], words_per_row: int, rows: int, max_rows: int) -> str:
    lines: list[str] = []
    shown = min(rows, max_rows)
    for y in range(shown):
        base = y * words_per_row
        chars: list[str] = []
        for w in range(words_per_row):
            word = data.get(base + w, 0)
            for b in range(16):
                chars.append("#" if ((word >> b) & 1) else ".")
        lines.append("".join(chars))
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="screen_dump.txt path")
    ap.add_argument("-o", "--output", type=Path, default=Path("screen.pbm"))
    ap.add_argument("--words-per-row", type=int, default=32, help="Hack full width = 32")
    ap.add_argument("--rows", type=int, default=256, help="Hack full height = 256")
    ap.add_argument("--preview", action="store_true", help="Print ASCII preview")
    ap.add_argument("--preview-rows", type=int, default=16)
    args = ap.parse_args()

    data = parse_dump(args.input)
    write_pbm(data, args.output, args.words_per_row, args.rows)
    print(f"[OK] Wrote PBM: {args.output} ({args.words_per_row * 16}x{args.rows})")

    if args.preview:
        print(preview_ascii(data, args.words_per_row, args.rows, args.preview_rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
