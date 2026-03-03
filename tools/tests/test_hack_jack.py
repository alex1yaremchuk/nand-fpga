import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import hack_jack as jack  # noqa: E402


class HackJackTokenizerTests(unittest.TestCase):
    def test_frozen_fixtures_parity(self) -> None:
        fixtures = REPO_ROOT / "tools/tests/jack_fixtures"
        jack_files = sorted(fixtures.rglob("*.jack"))
        self.assertGreater(len(jack_files), 0, "No .jack fixtures found")
        for jack_path in jack_files:
            xml_path = jack_path.with_suffix(".tokens.xml")
            self.assertTrue(xml_path.exists(), f"Missing fixture pair for {jack_path.name}")
            tokens = jack.tokenize_jack(jack_path.read_text(encoding="ascii"))
            got_xml = jack.tokens_to_xml(tokens)
            exp_xml = xml_path.read_text(encoding="ascii")
            self.assertEqual(got_xml, exp_xml, f"Fixture mismatch: {jack_path.name}")

    def test_compiler_fixtures_parity(self) -> None:
        fixtures = REPO_ROOT / "tools/tests/jack_fixtures"
        jack_files = sorted(fixtures.rglob("*.jack"))
        paired = 0
        for jack_path in jack_files:
            vm_path = jack_path.with_suffix(".vm")
            if not vm_path.exists():
                continue
            paired += 1
            src = jack_path.read_text(encoding="ascii")
            got = jack.compile_jack_to_vm(src)
            exp = [ln.strip() for ln in vm_path.read_text(encoding="ascii").splitlines() if ln.strip()]
            self.assertEqual(got, exp, f"Compiler fixture mismatch: {jack_path.name}")
        self.assertGreater(paired, 0, "No .jack/.vm compiler fixtures found")

    def test_ignores_comments(self) -> None:
        src = """
            // line comment
            class /* block */ Main {
                function void main() {
                    /* multi
                       line */
                    do Output.printInt(1); // tail
                    return;
                }
            }
        """
        tokens = jack.tokenize_jack(src)
        values = [t.value for t in tokens]
        self.assertIn("class", values)
        self.assertIn("Output", values)
        self.assertIn("printInt", values)
        self.assertNotIn("comment", values)

    def test_string_constant_keeps_symbols(self) -> None:
        src = 'class S { function void f() { do Output.printString("a<b&c>"); return; } }\n'
        tokens = jack.tokenize_jack(src)
        strings = [t.value for t in tokens if t.kind == "stringConstant"]
        self.assertEqual(strings, ["a<b&c>"])
        xml = jack.tokens_to_xml(tokens)
        self.assertIn("&lt;", xml)
        self.assertIn("&amp;", xml)
        self.assertIn("&gt;", xml)

    def test_integer_out_of_range_rejected(self) -> None:
        src = "class X { function void f() { let x = 40000; return; } }\n"
        with self.assertRaisesRegex(ValueError, "out of range"):
            jack.tokenize_jack(src)

    def test_unterminated_string_rejected(self) -> None:
        src = 'class X { function void f() { do Output.printString("abc); } }\n'
        with self.assertRaisesRegex(ValueError, "unterminated string"):
            jack.tokenize_jack(src)

    def test_unterminated_block_comment_rejected(self) -> None:
        src = "class X { /* unterminated"
        with self.assertRaisesRegex(ValueError, "unterminated block comment"):
            jack.tokenize_jack(src)

    def test_invalid_character_rejected(self) -> None:
        src = "class X { function void f() { let x = @; return; } }\n"
        with self.assertRaisesRegex(ValueError, "invalid character"):
            jack.tokenize_jack(src)

    def test_undefined_identifier_rejected(self) -> None:
        src = "class U { function void f() { let x = 1; return; } }\n"
        with self.assertRaisesRegex(ValueError, "undefined identifier"):
            jack.compile_jack_to_vm(src)

    def test_compact_string_literals_mode_avoids_appendchar_calls(self) -> None:
        src = 'class T { function void f() { do Output.printString("ABC"); return; } }\n'
        vm_lines = jack.compile_jack_to_vm(src, compact_string_literals=True)
        joined = "\n".join(vm_lines)
        self.assertIn("call String.new 1", joined)
        self.assertNotIn("call String.appendChar 2", joined)
        self.assertIn("pop that 1", joined)
        self.assertIn("pop that 2", joined)
        self.assertIn("pop that 3", joined)

    def test_cli_json_and_output(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            inp = root / "T.jack"
            out = root / "T.tokens.xml"
            vm = root / "T.vm"
            inp.write_text("class T { function void f() { return; } }\n", encoding="ascii")
            import subprocess

            proc = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "tools/hack_jack.py"),
                    str(inp),
                    "--tokens-out",
                    str(out),
                    "--json",
                    "-o",
                    str(vm),
                ],
                cwd=str(REPO_ROOT),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(out.exists())
            self.assertTrue(vm.exists())
            self.assertIn('"kind": "keyword"', proc.stdout)

    def test_cli_directory_mode_outputs_files(self) -> None:
        fixtures = REPO_ROOT / "tools/tests/jack_fixtures/dir_smoke"
        self.assertTrue(fixtures.is_dir())
        with tempfile.TemporaryDirectory() as td:
            out_root = Path(td)
            out_vm = out_root / "vm"
            out_tok = out_root / "tok"

            import subprocess

            proc = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "tools/hack_jack.py"),
                    str(fixtures),
                    "--tokens-out",
                    str(out_tok),
                    "-o",
                    str(out_vm),
                ],
                cwd=str(REPO_ROOT),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue((out_vm / "Sys.vm").exists())
            self.assertTrue((out_vm / "Counter.vm").exists())
            self.assertTrue((out_vm / "Memory.vm").exists())
            self.assertTrue((out_tok / "Sys.tokens.xml").exists())

    def test_repo_corpus_directories_compile(self) -> None:
        corpus_root = REPO_ROOT / "tools/programs/JackCorpus"
        self.assertTrue(corpus_root.is_dir(), "Missing tools/programs/JackCorpus")
        case_dirs = sorted([p for p in corpus_root.iterdir() if p.is_dir()])
        self.assertGreater(len(case_dirs), 0, "No Jack corpus case directories found")

        with tempfile.TemporaryDirectory() as td:
            out_root = Path(td)
            import subprocess

            for case_dir in case_dirs:
                out_vm = out_root / case_dir.name
                proc = subprocess.run(
                    [
                        sys.executable,
                        str(REPO_ROOT / "tools/hack_jack.py"),
                        str(case_dir),
                        "-o",
                        str(out_vm),
                    ],
                    cwd=str(REPO_ROOT),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(proc.returncode, 0, f"{case_dir.name}: {proc.stderr}")
                self.assertTrue((out_vm / "Sys.vm").exists(), f"{case_dir.name}: missing Sys.vm")


if __name__ == "__main__":
    unittest.main()
