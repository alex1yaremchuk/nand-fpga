import sys
import tempfile
import unittest
from pathlib import Path
import re

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import hack_vm as vm  # noqa: E402


class HackVmTranslatorTests(unittest.TestCase):
    def test_frozen_fixtures_parity(self) -> None:
        fixtures_dir = REPO_ROOT / "tools/tests/vm_fixtures"
        vm_files = sorted(fixtures_dir.glob("*.vm"))
        self.assertGreater(len(vm_files), 0, "No .vm fixtures found")

        for vm_path in vm_files:
            asm_path = vm_path.with_suffix(".asm")
            self.assertTrue(asm_path.exists(), f"Missing fixture pair for {vm_path.name}")
            src = vm_path.read_text(encoding="ascii")
            expected = [
                line.strip()
                for line in asm_path.read_text(encoding="ascii").splitlines()
                if line.strip()
            ]
            actual = vm.translate_vm(src, vm_path.stem)
            self.assertEqual(actual, expected, f"Fixture mismatch: {vm_path.name}")

    def test_arithmetic_compare_generates_unique_labels(self) -> None:
        src = """
            push constant 7
            push constant 7
            eq
            push constant 8
            push constant 3
            gt
            push constant 1
            push constant 2
            lt
        """
        out = vm.translate_vm(src, "Simple")
        labels = [line for line in out if line.startswith("(Simple$CMP_")]
        self.assertEqual(len(labels), 6)
        self.assertEqual(len(set(labels)), 6)

    def test_push_pop_local(self) -> None:
        src = """
            push constant 21
            pop local 2
            push local 2
        """
        out = vm.translate_vm(src, "Mem")
        joined = "\n".join(out)
        self.assertIn("@21\nD=A", joined)
        self.assertRegex(joined, r"@LCL\n(?:D=D\n)+D=M\n@2\nD=D\+A\n@R13\nM=D")
        self.assertRegex(joined, r"@LCL\n(?:D=D\n)+D=M\n@2\nA=D\+A\n(?:D=D\n)+D=M")

    def test_branching_scoped_by_function(self) -> None:
        src = """
            function Branch.Main 0
            label LOOP
            if-goto LOOP
            goto LOOP
        """
        out = vm.translate_vm(src, "Branch")
        self.assertIn("(Branch.Main$LOOP)", out)
        self.assertIn("@Branch.Main$LOOP", out)

    def test_static_segment_uses_module_symbol(self) -> None:
        src = """
            push static 3
            pop static 3
        """
        out = vm.translate_vm(src, "Foo")
        self.assertIn("@Foo.3", out)

    def test_pointer_index_range(self) -> None:
        with self.assertRaisesRegex(ValueError, "pointer index"):
            vm.translate_vm("push pointer 2\n", "Ptr")

    def test_pop_constant_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "pop constant"):
            vm.translate_vm("pop constant 7\n", "Bad")

    def test_function_call_return_supported(self) -> None:
        src = """
            function Main.id 0
            push argument 0
            return
            function Main.start 0
            push constant 7
            call Main.id 1
            pop temp 0
        """
        out = vm.translate_vm(src, "Main")
        joined = "\n".join(out)
        self.assertIn("(Main.id)", out)
        self.assertIn("(Main.start)", out)
        self.assertIn("@Main.id", out)
        self.assertRegex(joined, r"@R14\n(?:D=D\n)+A=M\n0;JMP")
        self.assertIn("@Main$RET$", joined)

    def test_bootstrap_emits_sys_init_call(self) -> None:
        sources = [("Sys", "function Sys.init 0\nreturn\n")]
        out = vm.translate_vm_sources(sources, include_bootstrap=True)
        self.assertGreaterEqual(len(out), 4)
        self.assertEqual(out[0:4], ["@256", "D=A", "@SP", "M=D"])
        self.assertIn("@Sys.init", out)
        self.assertIn("(BOOTSTRAP$RET$0)", out)
        self.assertIn("(BOOTSTRAP$END)", out)

    def test_directory_loader_orders_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "B.vm").write_text("push constant 2\n", encoding="ascii")
            (root / "A.vm").write_text("push constant 1\n", encoding="ascii")
            sources = vm._load_sources(root)  # pylint: disable=protected-access
            self.assertEqual([name for name, _ in sources], ["A", "B"])

    def test_no_vm_files_in_directory_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(ValueError, "No .vm files"):
                vm._load_sources(Path(td))  # pylint: disable=protected-access

    def test_unknown_command_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unsupported VM command"):
            vm.translate_vm("foo\n", "Main")


if __name__ == "__main__":
    unittest.main()
