#!/usr/bin/env python3
"""
Hack Jack frontend:
- Jack tokenizer
- Jack parser + symbol table + VM codegen
- Token XML output (nand2tetris-compatible)

Usage:
  python tools/hack_jack.py input.jack [--tokens-out out.xml]
  python tools/hack_jack.py input.jack -o output.vm
  python tools/hack_jack.py input.jack --json
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path


KEYWORDS = {
    "class",
    "constructor",
    "function",
    "method",
    "field",
    "static",
    "var",
    "int",
    "char",
    "boolean",
    "void",
    "true",
    "false",
    "null",
    "this",
    "let",
    "do",
    "if",
    "else",
    "while",
    "return",
}

SYMBOLS = set("{}()[].,;+-*/&|<>=~")
OPS = {"+", "-", "*", "/", "&", "|", "<", ">", "="}
UNARY_OPS = {"-", "~"}
KEYWORD_CONSTANTS = {"true", "false", "null", "this"}


@dataclass(frozen=True)
class JackToken:
    kind: str
    value: str
    line: int
    col: int


def _is_ident_start(ch: str) -> bool:
    return ch == "_" or ch.isalpha()


def _is_ident_part(ch: str) -> bool:
    return ch == "_" or ch.isalnum()


def _xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def tokenize_jack(text: str) -> list[JackToken]:
    out: list[JackToken] = []

    i = 0
    n = len(text)
    line = 1
    col = 1
    in_block_comment = False
    in_line_comment = False

    while i < n:
        ch = text[i]

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            i += 1
            if ch == "\n":
                line += 1
                col = 1
            else:
                col += 1
            continue

        if in_block_comment:
            if ch == "*" and i + 1 < n and text[i + 1] == "/":
                i += 2
                col += 2
                in_block_comment = False
                continue
            i += 1
            if ch == "\n":
                line += 1
                col = 1
            else:
                col += 1
            continue

        if ch in (" ", "\t", "\r", "\n"):
            i += 1
            if ch == "\n":
                line += 1
                col = 1
            else:
                col += 1
            continue

        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            in_line_comment = True
            i += 2
            col += 2
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            in_block_comment = True
            i += 2
            col += 2
            continue

        tok_line = line
        tok_col = col

        if ch == '"':
            i += 1
            col += 1
            start = i
            while i < n and text[i] != '"':
                if text[i] == "\n":
                    raise ValueError(f"line {tok_line}:{tok_col}: unterminated string constant")
                i += 1
                col += 1
            if i >= n:
                raise ValueError(f"line {tok_line}:{tok_col}: unterminated string constant")
            value = text[start:i]
            out.append(JackToken("stringConstant", value, tok_line, tok_col))
            i += 1
            col += 1
            continue

        if ch in SYMBOLS:
            out.append(JackToken("symbol", ch, tok_line, tok_col))
            i += 1
            col += 1
            continue

        if ch.isdigit():
            start = i
            while i < n and text[i].isdigit():
                i += 1
                col += 1
            value = text[start:i]
            as_int = int(value, 10)
            if as_int < 0 or as_int > 32767:
                raise ValueError(
                    f"line {tok_line}:{tok_col}: integer constant out of range: {value}"
                )
            out.append(JackToken("integerConstant", value, tok_line, tok_col))
            continue

        if _is_ident_start(ch):
            start = i
            while i < n and _is_ident_part(text[i]):
                i += 1
                col += 1
            value = text[start:i]
            kind = "keyword" if value in KEYWORDS else "identifier"
            out.append(JackToken(kind, value, tok_line, tok_col))
            continue

        raise ValueError(f"line {tok_line}:{tok_col}: invalid character: {ch!r}")

    if in_block_comment:
        raise ValueError("unterminated block comment")
    return out


def tokens_to_xml(tokens: list[JackToken]) -> str:
    lines = ["<tokens>"]
    for t in tokens:
        lines.append(f"  <{t.kind}> {_xml_escape(t.value)} </{t.kind}>")
    lines.append("</tokens>")
    return "\n".join(lines) + "\n"


def _default_tokens_path(input_path: Path) -> Path:
    return input_path.with_suffix(".tokens.xml")


def _default_vm_path(input_path: Path) -> Path:
    return input_path.with_suffix(".vm")


@dataclass(frozen=True)
class SymbolInfo:
    typ: str
    kind: str
    index: int


class SymbolTable:
    def __init__(self) -> None:
        self.class_scope: dict[str, SymbolInfo] = {}
        self.sub_scope: dict[str, SymbolInfo] = {}
        self.counts: dict[str, int] = {"static": 0, "field": 0, "arg": 0, "var": 0}

    def start_subroutine(self) -> None:
        self.sub_scope = {}
        self.counts["arg"] = 0
        self.counts["var"] = 0

    def define(self, name: str, typ: str, kind: str) -> None:
        if kind not in ("static", "field", "arg", "var"):
            raise ValueError(f"invalid symbol kind: {kind!r}")
        target = self.class_scope if kind in ("static", "field") else self.sub_scope
        if name in target:
            raise ValueError(f"duplicate identifier in scope: {name!r}")
        idx = self.counts[kind]
        target[name] = SymbolInfo(typ=typ, kind=kind, index=idx)
        self.counts[kind] += 1

    def var_count(self, kind: str) -> int:
        return self.counts.get(kind, 0)

    def lookup(self, name: str) -> SymbolInfo | None:
        if name in self.sub_scope:
            return self.sub_scope[name]
        return self.class_scope.get(name)


class VmWriter:
    def __init__(self) -> None:
        self.lines: list[str] = []

    def write(self, line: str) -> None:
        self.lines.append(line)

    def push(self, segment: str, index: int) -> None:
        self.write(f"push {segment} {index}")

    def pop(self, segment: str, index: int) -> None:
        self.write(f"pop {segment} {index}")

    def arithmetic(self, cmd: str) -> None:
        self.write(cmd)

    def label(self, name: str) -> None:
        self.write(f"label {name}")

    def goto(self, name: str) -> None:
        self.write(f"goto {name}")

    def if_goto(self, name: str) -> None:
        self.write(f"if-goto {name}")

    def call(self, name: str, n_args: int) -> None:
        self.write(f"call {name} {n_args}")

    def function(self, name: str, n_locals: int) -> None:
        self.write(f"function {name} {n_locals}")

    def return_(self) -> None:
        self.write("return")


class TokenStream:
    def __init__(self, tokens: list[JackToken]) -> None:
        self.tokens = tokens
        self.i = 0

    def at_end(self) -> bool:
        return self.i >= len(self.tokens)

    def peek(self, offset: int = 0) -> JackToken | None:
        j = self.i + offset
        if j < 0 or j >= len(self.tokens):
            return None
        return self.tokens[j]

    def advance(self) -> JackToken:
        t = self.peek(0)
        if t is None:
            raise ValueError("unexpected end of input")
        self.i += 1
        return t

    def error(self, msg: str) -> ValueError:
        t = self.peek(0)
        if t is None:
            return ValueError(f"end of input: {msg}")
        return ValueError(f"line {t.line}:{t.col}: {msg} (got {t.kind} {t.value!r})")

    def expect(self, *, kind: str | None = None, value: str | None = None) -> JackToken:
        t = self.peek(0)
        if t is None:
            raise ValueError(f"end of input: expected {kind or value or 'token'}")
        if kind is not None and t.kind != kind:
            raise self.error(f"expected token kind {kind!r}")
        if value is not None and t.value != value:
            raise self.error(f"expected token value {value!r}")
        self.i += 1
        return t

    def match_value(self, value: str) -> bool:
        t = self.peek(0)
        if t is not None and t.value == value:
            self.i += 1
            return True
        return False

    def match_kind(self, kind: str) -> JackToken | None:
        t = self.peek(0)
        if t is not None and t.kind == kind:
            self.i += 1
            return t
        return None


def _kind_to_segment(kind: str) -> str:
    return {
        "static": "static",
        "field": "this",
        "arg": "argument",
        "var": "local",
    }[kind]


class CompilationEngine:
    def __init__(self, tokens: list[JackToken], *, compact_string_literals: bool = False) -> None:
        self.ts = TokenStream(tokens)
        self.vm = VmWriter()
        self.symbols = SymbolTable()
        self.class_name = ""
        self.label_id = 0
        self.compact_string_literals = compact_string_literals

    def _new_label(self, prefix: str) -> str:
        out = f"{prefix}{self.label_id}"
        self.label_id += 1
        return out

    def _expect_identifier(self) -> str:
        t = self.ts.expect(kind="identifier")
        return t.value

    def _expect_type(self, allow_void: bool = False) -> str:
        t = self.ts.peek(0)
        if t is None:
            raise ValueError("end of input: expected type")
        if t.kind == "keyword" and t.value in {"int", "char", "boolean"}:
            self.ts.advance()
            return t.value
        if allow_void and t.kind == "keyword" and t.value == "void":
            self.ts.advance()
            return t.value
        if t.kind == "identifier":
            self.ts.advance()
            return t.value
        raise self.ts.error("expected type")

    def _require_symbol(self, symbol: str) -> None:
        self.ts.expect(kind="symbol", value=symbol)

    def _define(self, name: str, typ: str, kind: str) -> None:
        try:
            self.symbols.define(name, typ, kind)
        except ValueError as exc:
            raise self.ts.error(str(exc)) from exc

    def _lookup_symbol(self, name: str) -> SymbolInfo:
        sym = self.symbols.lookup(name)
        if sym is None:
            raise self.ts.error(f"undefined identifier: {name!r}")
        return sym

    def compile(self) -> list[str]:
        self._compile_class()
        if not self.ts.at_end():
            raise self.ts.error("trailing tokens after class")
        return self.vm.lines

    def _compile_class(self) -> None:
        self.ts.expect(kind="keyword", value="class")
        self.class_name = self._expect_identifier()
        self._require_symbol("{")

        while True:
            t = self.ts.peek(0)
            if t is None:
                raise ValueError("end of input: expected class member or '}'")
            if t.kind == "keyword" and t.value in {"static", "field"}:
                self._compile_class_var_dec()
                continue
            if t.kind == "keyword" and t.value in {"constructor", "function", "method"}:
                self._compile_subroutine()
                continue
            break

        self._require_symbol("}")

    def _compile_class_var_dec(self) -> None:
        kind = self.ts.expect(kind="keyword").value  # static | field
        typ = self._expect_type(allow_void=False)
        name = self._expect_identifier()
        self._define(name, typ, kind)
        while self.ts.match_value(","):
            name = self._expect_identifier()
            self._define(name, typ, kind)
        self._require_symbol(";")

    def _compile_subroutine(self) -> None:
        sub_kind = self.ts.expect(kind="keyword").value  # constructor|function|method
        self._expect_type(allow_void=True)  # return type
        sub_name = self._expect_identifier()
        full_name = f"{self.class_name}.{sub_name}"

        self.symbols.start_subroutine()
        if sub_kind == "method":
            # argument 0 = this
            self._define("this", self.class_name, "arg")

        self._require_symbol("(")
        self._compile_parameter_list()
        self._require_symbol(")")

        self._require_symbol("{")
        while True:
            t = self.ts.peek(0)
            if t is not None and t.kind == "keyword" and t.value == "var":
                self._compile_var_dec()
            else:
                break

        n_locals = self.symbols.var_count("var")
        self.vm.function(full_name, n_locals)

        if sub_kind == "constructor":
            n_fields = self.symbols.var_count("field")
            self.vm.push("constant", n_fields)
            self.vm.call("Memory.alloc", 1)
            self.vm.pop("pointer", 0)
        elif sub_kind == "method":
            self.vm.push("argument", 0)
            self.vm.pop("pointer", 0)

        self._compile_statements()
        self._require_symbol("}")

    def _compile_parameter_list(self) -> None:
        t = self.ts.peek(0)
        if t is not None and not (t.kind == "symbol" and t.value == ")"):
            while True:
                typ = self._expect_type(allow_void=False)
                name = self._expect_identifier()
                self._define(name, typ, "arg")
                if not self.ts.match_value(","):
                    break

    def _compile_var_dec(self) -> None:
        self.ts.expect(kind="keyword", value="var")
        typ = self._expect_type(allow_void=False)
        name = self._expect_identifier()
        self._define(name, typ, "var")
        while self.ts.match_value(","):
            name = self._expect_identifier()
            self._define(name, typ, "var")
        self._require_symbol(";")

    def _compile_statements(self) -> None:
        while True:
            t = self.ts.peek(0)
            if t is None or t.kind != "keyword":
                return
            if t.value == "let":
                self._compile_let()
            elif t.value == "if":
                self._compile_if()
            elif t.value == "while":
                self._compile_while()
            elif t.value == "do":
                self._compile_do()
            elif t.value == "return":
                self._compile_return()
            else:
                return

    def _compile_let(self) -> None:
        self.ts.expect(kind="keyword", value="let")
        name = self._expect_identifier()
        sym = self._lookup_symbol(name)
        seg = _kind_to_segment(sym.kind)

        is_array = self.ts.match_value("[")
        if is_array:
            self.vm.push(seg, sym.index)
            self._compile_expression()
            self._require_symbol("]")
            self.vm.arithmetic("add")

        self._require_symbol("=")
        self._compile_expression()
        self._require_symbol(";")

        if is_array:
            self.vm.pop("temp", 0)
            self.vm.pop("pointer", 1)
            self.vm.push("temp", 0)
            self.vm.pop("that", 0)
        else:
            self.vm.pop(seg, sym.index)

    def _compile_if(self) -> None:
        self.ts.expect(kind="keyword", value="if")
        self._require_symbol("(")
        self._compile_expression()
        self._require_symbol(")")

        l_true = self._new_label("IF_TRUE_")
        l_false = self._new_label("IF_FALSE_")
        l_end = self._new_label("IF_END_")

        self.vm.if_goto(l_true)
        self.vm.goto(l_false)
        self.vm.label(l_true)

        self._require_symbol("{")
        self._compile_statements()
        self._require_symbol("}")

        if self.ts.match_value("else"):
            self.vm.goto(l_end)
            self.vm.label(l_false)
            self._require_symbol("{")
            self._compile_statements()
            self._require_symbol("}")
            self.vm.label(l_end)
        else:
            self.vm.label(l_false)

    def _compile_while(self) -> None:
        self.ts.expect(kind="keyword", value="while")
        l_exp = self._new_label("WHILE_EXP_")
        l_end = self._new_label("WHILE_END_")

        self.vm.label(l_exp)
        self._require_symbol("(")
        self._compile_expression()
        self._require_symbol(")")
        self.vm.arithmetic("not")
        self.vm.if_goto(l_end)

        self._require_symbol("{")
        self._compile_statements()
        self._require_symbol("}")

        self.vm.goto(l_exp)
        self.vm.label(l_end)

    def _compile_do(self) -> None:
        self.ts.expect(kind="keyword", value="do")
        self._compile_subroutine_call()
        self._require_symbol(";")
        self.vm.pop("temp", 0)  # discard return value

    def _compile_return(self) -> None:
        self.ts.expect(kind="keyword", value="return")
        t = self.ts.peek(0)
        if t is not None and not (t.kind == "symbol" and t.value == ";"):
            self._compile_expression()
        else:
            self.vm.push("constant", 0)
        self._require_symbol(";")
        self.vm.return_()

    def _compile_expression(self) -> None:
        self._compile_term()
        while True:
            t = self.ts.peek(0)
            if t is None or t.kind != "symbol" or t.value not in OPS:
                return
            op = self.ts.advance().value
            self._compile_term()
            if op == "+":
                self.vm.arithmetic("add")
            elif op == "-":
                self.vm.arithmetic("sub")
            elif op == "*":
                self.vm.call("Math.multiply", 2)
            elif op == "/":
                self.vm.call("Math.divide", 2)
            elif op == "&":
                self.vm.arithmetic("and")
            elif op == "|":
                self.vm.arithmetic("or")
            elif op == "<":
                self.vm.arithmetic("lt")
            elif op == ">":
                self.vm.arithmetic("gt")
            elif op == "=":
                self.vm.arithmetic("eq")
            else:
                raise self.ts.error(f"unsupported operator: {op!r}")

    def _compile_term(self) -> None:
        t = self.ts.peek(0)
        if t is None:
            raise ValueError("end of input: expected term")

        if t.kind == "integerConstant":
            self.ts.advance()
            self.vm.push("constant", int(t.value, 10))
            return

        if t.kind == "stringConstant":
            self.ts.advance()
            s = t.value
            self.vm.push("constant", len(s))
            self.vm.call("String.new", 1)
            if self.compact_string_literals and len(s) > 0:
                # Optional compact mode: initialize String backing storage directly,
                # avoiding per-character call overhead of String.appendChar.
                self.vm.pop("temp", 0)
                self.vm.push("temp", 0)
                self.vm.pop("pointer", 1)
                self.vm.push("constant", len(s))
                self.vm.pop("that", 0)
                for i, ch in enumerate(s, start=1):
                    self.vm.push("constant", ord(ch))
                    self.vm.pop("that", i)
                self.vm.push("temp", 0)
                return
            for ch in s:
                self.vm.push("constant", ord(ch))
                self.vm.call("String.appendChar", 2)
            return

        if t.kind == "keyword" and t.value in KEYWORD_CONSTANTS:
            self.ts.advance()
            if t.value == "true":
                self.vm.push("constant", 0)
                self.vm.arithmetic("not")
            elif t.value in ("false", "null"):
                self.vm.push("constant", 0)
            elif t.value == "this":
                self.vm.push("pointer", 0)
            return

        if t.kind == "symbol" and t.value == "(":
            self.ts.advance()
            self._compile_expression()
            self._require_symbol(")")
            return

        if t.kind == "symbol" and t.value in UNARY_OPS:
            op = self.ts.advance().value
            self._compile_term()
            self.vm.arithmetic("neg" if op == "-" else "not")
            return

        if t.kind == "identifier":
            ident = self.ts.advance().value
            nxt = self.ts.peek(0)
            if nxt is not None and nxt.kind == "symbol" and nxt.value == "[":
                sym = self._lookup_symbol(ident)
                seg = _kind_to_segment(sym.kind)
                self.vm.push(seg, sym.index)
                self.ts.advance()  # [
                self._compile_expression()
                self._require_symbol("]")
                self.vm.arithmetic("add")
                self.vm.pop("pointer", 1)
                self.vm.push("that", 0)
                return
            if nxt is not None and nxt.kind == "symbol" and nxt.value in {"(", "."}:
                self._compile_subroutine_call(first_ident=ident)
                return
            sym = self._lookup_symbol(ident)
            self.vm.push(_kind_to_segment(sym.kind), sym.index)
            return

        raise self.ts.error("expected term")

    def _compile_subroutine_call(self, first_ident: str | None = None) -> None:
        if first_ident is None:
            first_ident = self._expect_identifier()

        n_args = 0
        t = self.ts.peek(0)
        if t is None or t.kind != "symbol":
            raise self.ts.error("expected '(' or '.' in subroutine call")

        if t.value == "(":
            # method on this
            self.ts.advance()
            self.vm.push("pointer", 0)
            n_args = 1 + self._compile_expression_list()
            self._require_symbol(")")
            self.vm.call(f"{self.class_name}.{first_ident}", n_args)
            return

        if t.value == ".":
            self.ts.advance()
            second = self._expect_identifier()
            self._require_symbol("(")

            sym = self.symbols.lookup(first_ident)
            if sym is None:
                # class function/constructor call
                target = f"{first_ident}.{second}"
            else:
                # method call on object variable
                self.vm.push(_kind_to_segment(sym.kind), sym.index)
                n_args += 1
                target = f"{sym.typ}.{second}"

            n_args += self._compile_expression_list()
            self._require_symbol(")")
            self.vm.call(target, n_args)
            return

        raise self.ts.error("expected '(' or '.' in subroutine call")

    def _compile_expression_list(self) -> int:
        n = 0
        t = self.ts.peek(0)
        if t is not None and not (t.kind == "symbol" and t.value == ")"):
            while True:
                self._compile_expression()
                n += 1
                if not self.ts.match_value(","):
                    break
        return n


def compile_jack_to_vm(text: str, *, compact_string_literals: bool = False) -> list[str]:
    tokens = tokenize_jack(text)
    engine = CompilationEngine(tokens, compact_string_literals=compact_string_literals)
    return engine.compile()


def _collect_jack_files(input_path: Path) -> list[Path]:
    if input_path.is_file():
        if input_path.suffix.lower() != ".jack":
            raise ValueError(f"Expected .jack input, got: {input_path}")
        return [input_path]
    if input_path.is_dir():
        files = sorted(input_path.glob("*.jack"))
        if not files:
            raise ValueError(f"No .jack files found in directory: {input_path}")
        return files
    raise ValueError(f"Input path does not exist: {input_path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="Input .jack file or directory with .jack files")
    ap.add_argument(
        "--tokens-out",
        type=Path,
        default=None,
        help="Token XML output path (file mode) or directory (directory mode)",
    )
    ap.add_argument("--json", action="store_true", help="Print tokens as JSON (file mode only)")
    ap.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output .vm file (file mode) or output directory (directory mode)",
    )
    ap.add_argument(
        "--compact-string-literals",
        action="store_true",
        help="Emit compact VM for string constants (smaller code, relies on current String object layout)",
    )
    args = ap.parse_args()

    input_path = args.input.resolve()
    try:
        jack_files = _collect_jack_files(input_path)
    except ValueError as exc:
        raise SystemExit(f"[ERROR] {exc}") from exc

    is_dir_mode = input_path.is_dir()
    if is_dir_mode and args.json:
        raise SystemExit("[ERROR] --json is supported only for single-file input.")

    compile_vm = args.output is not None or (args.tokens_out is None and not args.json)

    if is_dir_mode:
        if args.output is None:
            vm_out_dir = input_path
        else:
            vm_out_dir = args.output
            if vm_out_dir.suffix.lower() == ".vm":
                raise SystemExit("[ERROR] In directory mode, --output must be a directory.")
        vm_out_dir.mkdir(parents=True, exist_ok=True)
    else:
        vm_out_dir = None

    if args.tokens_out is not None:
        if is_dir_mode:
            tok_out_dir = args.tokens_out
            tok_out_dir.mkdir(parents=True, exist_ok=True)
            tok_out_path: Path | None = None
        else:
            tok_out_dir = None
            tok_out_path = args.tokens_out
    else:
        tok_out_dir = None
        tok_out_path = None

    for jack_path in jack_files:
        src = jack_path.read_text(encoding="ascii")
        tokens = tokenize_jack(src)

        if args.json:
            print(
                json.dumps(
                    [
                        {"kind": t.kind, "value": t.value, "line": t.line, "col": t.col}
                        for t in tokens
                    ],
                    indent=2,
                )
            )

        if tok_out_dir is not None:
            tpath = tok_out_dir / f"{jack_path.stem}.tokens.xml"
            tpath.write_text(tokens_to_xml(tokens), encoding="ascii")
            print(f"[OK] Wrote {tpath} ({len(tokens)} tokens)")
        elif tok_out_path is not None:
            tok_out_path.write_text(tokens_to_xml(tokens), encoding="ascii")
            print(f"[OK] Wrote {tok_out_path} ({len(tokens)} tokens)")

        if compile_vm:
            vm_lines = compile_jack_to_vm(
                src,
                compact_string_literals=args.compact_string_literals,
            )
            if is_dir_mode:
                assert vm_out_dir is not None
                vpath = vm_out_dir / f"{jack_path.stem}.vm"
            else:
                vpath = args.output or _default_vm_path(jack_path)
            vpath.write_text("\n".join(vm_lines) + "\n", encoding="ascii")
            print(f"[OK] Wrote {vpath} ({len(vm_lines)} vm lines)")

        if (not is_dir_mode) and args.tokens_out is None and not compile_vm:
            # Preserve a deterministic artifact for tokenizer-only calls.
            tpath = _default_tokens_path(jack_path)
            tpath.write_text(tokens_to_xml(tokens), encoding="ascii")
            print(f"[OK] Wrote {tpath} ({len(tokens)} tokens)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
