#!/usr/bin/env python3
"""
Hack VM translator (Phase 7C scope):
- Stack arithmetic/logical commands
- push/pop for memory segments
- label/goto/if-goto branching
- function/call/return
- optional bootstrap + directory mode

Usage:
  python tools/hack_vm.py input.vm [-o output.asm] [--bootstrap|--no-bootstrap]
  python tools/hack_vm.py input_dir [-o output.asm] [--bootstrap|--no-bootstrap]
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path


SYMBOL_RE = re.compile(r"^[A-Za-z_.$:][A-Za-z0-9_.$:]*$")
SEGMENT_BASE = {
    "local": "LCL",
    "argument": "ARG",
    "this": "THIS",
    "that": "THAT",
}
ARITHMETIC_CMDS = {
    "add",
    "sub",
    "neg",
    "eq",
    "gt",
    "lt",
    "and",
    "or",
    "not",
}


def clean_lines(src: str) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    for lineno, raw in enumerate(src.splitlines(), start=1):
        line = raw.split("//", 1)[0].strip()
        if line:
            out.append((lineno, line))
    return out


@dataclass
class TranslationState:
    label_id: int = 0
    current_function: str = ""
    sync_waits: int = 2


class VmTranslator:
    def __init__(self, module_name: str, state: TranslationState) -> None:
        if not SYMBOL_RE.fullmatch(module_name):
            raise ValueError(f"Invalid module name: {module_name!r}")
        if state.sync_waits < 0:
            raise ValueError(f"sync_waits must be >= 0, got {state.sync_waits}")
        self.module_name = module_name
        self.state = state

    def _unique_label(self, prefix: str) -> str:
        label = f"{self.module_name}${prefix}{self.state.label_id}"
        self.state.label_id += 1
        return label

    def _scoped_label(self, symbol: str) -> str:
        if not SYMBOL_RE.fullmatch(symbol):
            raise ValueError(f"Invalid VM label: {symbol!r}")
        if self.state.current_function:
            return f"{self.state.current_function}${symbol}"
        return f"{self.module_name}${symbol}"

    def _validate_function_name(self, symbol: str) -> None:
        if not SYMBOL_RE.fullmatch(symbol):
            raise ValueError(f"Invalid VM function name: {symbol!r}")

    def _push_d(self) -> list[str]:
        return [
            "@SP",
            *self._sync_wait(),
            "A=M",
            "M=D",
            "@SP",
            *self._sync_wait(),
            "M=M+1",
        ]

    def _sync_wait(self) -> list[str]:
        # Two-cycle hold for synchronous BRAM read after address selection changes.
        return ["D=D"] * self.state.sync_waits

    def _pop_to_d(self) -> list[str]:
        return [
            "@SP",
            *self._sync_wait(),
            "AM=M-1",
            *self._sync_wait(),
            "D=M",
        ]

    def _translate_arithmetic(self, cmd: str) -> list[str]:
        if cmd == "add":
            return [*self._pop_to_d(), "A=A-1", *self._sync_wait(), "M=M+D"]
        if cmd == "sub":
            return [*self._pop_to_d(), "A=A-1", *self._sync_wait(), "M=M-D"]
        if cmd == "and":
            return [*self._pop_to_d(), "A=A-1", *self._sync_wait(), "M=M&D"]
        if cmd == "or":
            return [*self._pop_to_d(), "A=A-1", *self._sync_wait(), "M=M|D"]
        if cmd == "neg":
            return [
                "@SP",
                *self._sync_wait(),
                "D=M",
                "D=D-1",
                "A=D",
                *self._sync_wait(),
                "M=-M",
            ]
        if cmd == "not":
            return [
                "@SP",
                *self._sync_wait(),
                "D=M",
                "D=D-1",
                "A=D",
                *self._sync_wait(),
                "M=!M",
            ]

        jump = {"eq": "JEQ", "gt": "JGT", "lt": "JLT"}[cmd]
        true_label = self._unique_label("CMP_TRUE_")
        end_label = self._unique_label("CMP_END_")
        return [
            *self._pop_to_d(),
            "A=A-1",
            *self._sync_wait(),
            "D=M-D",
            f"@{true_label}",
            f"D;{jump}",
            "@SP",
            *self._sync_wait(),
            "D=M",
            "D=D-1",
            "A=D",
            "M=0",
            f"@{end_label}",
            "0;JMP",
            f"({true_label})",
            "@SP",
            *self._sync_wait(),
            "D=M",
            "D=D-1",
            "A=D",
            "M=-1",
            f"({end_label})",
        ]

    def _translate_push(self, segment: str, index: int) -> list[str]:
        if segment == "constant":
            return [f"@{index}", "D=A", *self._push_d()]

        if segment in SEGMENT_BASE:
            base = SEGMENT_BASE[segment]
            return [
                f"@{base}",
                *self._sync_wait(),
                "D=M",
                f"@{index}",
                "A=D+A",
                *self._sync_wait(),
                "D=M",
                *self._push_d(),
            ]

        if segment == "temp":
            if index < 0 or index > 7:
                raise ValueError("temp index out of range (0..7)")
            return [f"@{5 + index}", *self._sync_wait(), "D=M", *self._push_d()]

        if segment == "pointer":
            if index not in (0, 1):
                raise ValueError("pointer index must be 0 or 1")
            reg = "THIS" if index == 0 else "THAT"
            return [f"@{reg}", *self._sync_wait(), "D=M", *self._push_d()]

        if segment == "static":
            return [f"@{self.module_name}.{index}", *self._sync_wait(), "D=M", *self._push_d()]

        raise ValueError(f"Unknown segment for push: {segment!r}")

    def _translate_pop(self, segment: str, index: int) -> list[str]:
        if segment == "constant":
            raise ValueError("pop constant is invalid")

        if segment in SEGMENT_BASE:
            base = SEGMENT_BASE[segment]
            return [
                f"@{base}",
                *self._sync_wait(),
                "D=M",
                f"@{index}",
                "D=D+A",
                "@R13",
                "M=D",
                *self._pop_to_d(),
                "@R13",
                *self._sync_wait(),
                "A=M",
                "M=D",
            ]

        if segment == "temp":
            if index < 0 or index > 7:
                raise ValueError("temp index out of range (0..7)")
            return [*self._pop_to_d(), f"@{5 + index}", "M=D"]

        if segment == "pointer":
            if index not in (0, 1):
                raise ValueError("pointer index must be 0 or 1")
            reg = "THIS" if index == 0 else "THAT"
            return [*self._pop_to_d(), f"@{reg}", "M=D"]

        if segment == "static":
            return [*self._pop_to_d(), f"@{self.module_name}.{index}", "M=D"]

        raise ValueError(f"Unknown segment for pop: {segment!r}")

    def _translate_function(self, function_name: str, n_locals: int) -> list[str]:
        self._validate_function_name(function_name)
        self.state.current_function = function_name
        out = [f"({function_name})"]
        for _ in range(n_locals):
            out.extend(["@0", "D=A", *self._push_d()])
        return out

    def _translate_call(self, function_name: str, n_args: int) -> list[str]:
        self._validate_function_name(function_name)
        ret_label = self._unique_label("RET$")
        return [
            f"@{ret_label}",
            "D=A",
            *self._push_d(),
            "@LCL",
            *self._sync_wait(),
            "D=M",
            *self._push_d(),
            "@ARG",
            *self._sync_wait(),
            "D=M",
            *self._push_d(),
            "@THIS",
            *self._sync_wait(),
            "D=M",
            *self._push_d(),
            "@THAT",
            *self._sync_wait(),
            "D=M",
            *self._push_d(),
            "@SP",
            *self._sync_wait(),
            "D=M",
            f"@{n_args + 5}",
            "D=D-A",
            "@ARG",
            "M=D",
            "@SP",
            *self._sync_wait(),
            "D=M",
            "@LCL",
            "M=D",
            f"@{function_name}",
            "0;JMP",
            f"({ret_label})",
        ]

    def _translate_return(self) -> list[str]:
        return [
            "@LCL",
            *self._sync_wait(),
            "D=M",
            "@R13",
            "M=D",
            "@5",
            "A=D-A",
            *self._sync_wait(),
            "D=M",
            "@R14",
            "M=D",
            *self._pop_to_d(),
            "@ARG",
            *self._sync_wait(),
            "A=M",
            "M=D",
            "@ARG",
            *self._sync_wait(),
            "D=M+1",
            "@SP",
            "M=D",
            "@R13",
            *self._sync_wait(),
            "AM=M-1",
            *self._sync_wait(),
            "D=M",
            "@THAT",
            "M=D",
            "@R13",
            *self._sync_wait(),
            "AM=M-1",
            *self._sync_wait(),
            "D=M",
            "@THIS",
            "M=D",
            "@R13",
            *self._sync_wait(),
            "AM=M-1",
            *self._sync_wait(),
            "D=M",
            "@ARG",
            "M=D",
            "@R13",
            *self._sync_wait(),
            "AM=M-1",
            *self._sync_wait(),
            "D=M",
            "@LCL",
            "M=D",
            "@R14",
            *self._sync_wait(),
            "A=M",
            "0;JMP",
        ]

    def translate_command(self, line: str) -> list[str]:
        parts = line.split()
        cmd = parts[0]

        if cmd in ARITHMETIC_CMDS:
            if len(parts) != 1:
                raise ValueError(f"{cmd} does not take arguments")
            return self._translate_arithmetic(cmd)

        if cmd in ("push", "pop"):
            if len(parts) != 3:
                raise ValueError(f"{cmd} requires exactly 2 arguments")
            segment = parts[1]
            try:
                index = int(parts[2], 10)
            except ValueError as exc:
                raise ValueError(f"Invalid index: {parts[2]!r}") from exc
            if index < 0:
                raise ValueError("index must be >= 0")
            if cmd == "push":
                return self._translate_push(segment, index)
            return self._translate_pop(segment, index)

        if cmd == "label":
            if len(parts) != 2:
                raise ValueError("label requires exactly 1 argument")
            return [f"({self._scoped_label(parts[1])})"]

        if cmd == "goto":
            if len(parts) != 2:
                raise ValueError("goto requires exactly 1 argument")
            target = self._scoped_label(parts[1])
            return [f"@{target}", "0;JMP"]

        if cmd == "if-goto":
            if len(parts) != 2:
                raise ValueError("if-goto requires exactly 1 argument")
            target = self._scoped_label(parts[1])
            return [
                *self._pop_to_d(),
                f"@{target}",
                "D;JNE",
            ]

        if cmd in ("function", "call"):
            if len(parts) != 3:
                raise ValueError(f"{cmd} requires exactly 2 arguments")
            try:
                n = int(parts[2], 10)
            except ValueError as exc:
                raise ValueError(f"Invalid integer argument: {parts[2]!r}") from exc
            if n < 0:
                raise ValueError("count argument must be >= 0")
            if cmd == "function":
                return self._translate_function(parts[1], n)
            return self._translate_call(parts[1], n)

        if cmd == "return":
            if len(parts) != 1:
                raise ValueError("return does not take arguments")
            return self._translate_return()

        raise ValueError(f"Unsupported VM command: {cmd!r}")


def translate_vm(text: str, module_name: str, *, sync_waits: int = 2) -> list[str]:
    translator = VmTranslator(module_name, TranslationState(sync_waits=sync_waits))
    out: list[str] = []
    for lineno, line in clean_lines(text):
        try:
            out.extend(translator.translate_command(line))
        except ValueError as exc:
            raise ValueError(f"line {lineno}: {exc}") from exc
    return out


def _bootstrap_lines(state: TranslationState) -> list[str]:
    translator = VmTranslator("BOOTSTRAP", state)
    return [
        "@256",
        "D=A",
        "@SP",
        "M=D",
        *translator._translate_call("Sys.init", 0),
        "(BOOTSTRAP$END)",
        "@BOOTSTRAP$END",
        "0;JMP",
    ]


def translate_vm_sources(
    sources: list[tuple[str, str]], *, include_bootstrap: bool = False, sync_waits: int = 2
) -> list[str]:
    state = TranslationState(sync_waits=sync_waits)
    out: list[str] = []
    if include_bootstrap:
        out.extend(_bootstrap_lines(state))

    for module_name, text in sources:
        state.current_function = ""
        translator = VmTranslator(module_name, state)
        for lineno, line in clean_lines(text):
            try:
                out.extend(translator.translate_command(line))
            except ValueError as exc:
                raise ValueError(f"{module_name}.vm:{lineno}: {exc}") from exc
    return out


def _load_sources(input_path: Path) -> list[tuple[str, str]]:
    if input_path.is_file():
        if input_path.suffix.lower() != ".vm":
            raise ValueError(f"Expected .vm input file, got: {input_path}")
        return [(input_path.stem, input_path.read_text(encoding="ascii"))]

    if input_path.is_dir():
        vm_files = sorted(input_path.glob("*.vm"))
        if not vm_files:
            raise ValueError(f"No .vm files found in directory: {input_path}")
        return [(f.stem, f.read_text(encoding="ascii")) for f in vm_files]

    raise ValueError(f"Input path does not exist: {input_path}")


def _default_output_path(input_path: Path) -> Path:
    if input_path.is_file():
        return input_path.with_suffix(".asm")
    return input_path / f"{input_path.name}.asm"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="Input .vm file or directory with .vm files")
    ap.add_argument(
        "-o", "--output", type=Path, default=None, help="Output .asm file (single file)"
    )
    mgroup = ap.add_mutually_exclusive_group()
    mgroup.add_argument("--bootstrap", action="store_true", help="Emit SP init + call Sys.init")
    mgroup.add_argument(
        "--no-bootstrap", action="store_true", help="Do not emit bootstrap sequence"
    )
    ap.add_argument(
        "--sync-waits",
        type=int,
        default=2,
        help="No-op wait cycles inserted around M accesses for sync BRAM timing (default: 2)",
    )
    args = ap.parse_args()

    input_path = args.input.resolve()
    sources = _load_sources(input_path)

    if args.bootstrap:
        include_bootstrap = True
    elif args.no_bootstrap:
        include_bootstrap = False
    else:
        include_bootstrap = input_path.is_dir()

    asm = translate_vm_sources(
        sources,
        include_bootstrap=include_bootstrap,
        sync_waits=args.sync_waits,
    )

    out_path = args.output or _default_output_path(input_path)
    out_path.write_text("\n".join(asm) + "\n", encoding="ascii")
    print(f"[OK] Wrote {out_path} ({len(asm)} asm lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
    if args.sync_waits < 0:
        raise ValueError(f"--sync-waits must be >= 0, got {args.sync_waits}")
