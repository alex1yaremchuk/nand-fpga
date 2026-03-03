import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import hack_asm as asm  # noqa: E402


class HackAsmPositiveTests(unittest.TestCase):
    def test_frozen_fixtures_parity(self) -> None:
        fixtures_dir = REPO_ROOT / "tools/tests/asm_fixtures"
        asm_files = sorted(fixtures_dir.glob("*.asm"))
        self.assertGreater(len(asm_files), 0, "No .asm fixtures found")

        for asm_path in asm_files:
            hack_path = asm_path.with_suffix(".hack")
            self.assertTrue(hack_path.exists(), f"Missing fixture pair for {asm_path.name}")

            src = asm_path.read_text(encoding="ascii")
            expected = [
                line.strip()
                for line in hack_path.read_text(encoding="ascii").splitlines()
                if line.strip()
            ]
            actual = asm.assemble(src)
            self.assertEqual(actual, expected, f"Fixture mismatch: {asm_path.name}")

    def test_add_fixture_compat(self) -> None:
        src = (REPO_ROOT / "tools/programs/Add.asm").read_text(encoding="ascii")
        out = asm.assemble(src)
        self.assertEqual(
            out,
            [
                "0000000000000000",
                "1111110000010000",
                "0000000000000001",
                "1110001100010000",
                "1111000010010000",
                "0000000000000010",
                "1110001100001000",
                "0000000000000111",
                "1110101010000111",
            ],
        )

    def test_label_and_variable_resolution(self) -> None:
        src = """
            @i
            M=1
            (LOOP)
            @i
            M=M+1
            @LOOP
            0;JMP
        """
        self.assertEqual(
            asm.assemble(src),
            [
                "0000000000010000",
                "1110111111001000",
                "0000000000010000",
                "1111110111001000",
                "0000000000000010",
                "1110101010000111",
            ],
        )

    def test_predefined_symbols(self) -> None:
        src = """
            @SCREEN
            D=A
            @KBD
            D=D-A
            @R15
            M=D
        """
        self.assertEqual(
            asm.assemble(src),
            [
                "0100000000000000",
                "1110110000010000",
                "0110000000000000",
                "1110010011010000",
                "0000000000001111",
                "1110001100001000",
            ],
        )

    def test_dest_permutations(self) -> None:
        self.assertEqual(asm.parse_c("DM=1"), asm.parse_c("MD=1"))
        self.assertEqual(asm.parse_c("DA=0"), asm.parse_c("AD=0"))
        self.assertEqual(asm.parse_c("MDA=D"), asm.parse_c("AMD=D"))

    def test_commutative_comp_aliases(self) -> None:
        self.assertEqual(asm.parse_c("D=A+D"), asm.parse_c("D=D+A"))
        self.assertEqual(asm.parse_c("D=A&D"), asm.parse_c("D=D&A"))
        self.assertEqual(asm.parse_c("D=M|D"), asm.parse_c("D=D|M"))

    def test_all_official_comp_mnemonics(self) -> None:
        official = [
            "0",
            "1",
            "-1",
            "D",
            "A",
            "!D",
            "!A",
            "-D",
            "-A",
            "D+1",
            "A+1",
            "D-1",
            "A-1",
            "D+A",
            "D-A",
            "A-D",
            "D&A",
            "D|A",
            "M",
            "!M",
            "-M",
            "M+1",
            "M-1",
            "D+M",
            "D-M",
            "M-D",
            "D&M",
            "D|M",
        ]
        for comp in official:
            word = asm.parse_c(f"D={comp}")
            self.assertEqual(len(word), 16)
            self.assertTrue(word.startswith("111"))


class HackAsmNegativeTests(unittest.TestCase):
    def test_duplicate_label(self) -> None:
        with self.assertRaisesRegex(ValueError, "Duplicate label"):
            asm.assemble("(LOOP)\n@0\n(LOOP)\n@1\n")

    def test_duplicate_label_with_predefined_symbol(self) -> None:
        with self.assertRaisesRegex(ValueError, "Duplicate label"):
            asm.assemble("(R0)\n@0\n")

    def test_invalid_symbol(self) -> None:
        with self.assertRaisesRegex(ValueError, "Invalid symbol"):
            asm.assemble("@1foo\nD=A\n")

    def test_invalid_symbol_characters(self) -> None:
        with self.assertRaisesRegex(ValueError, "Invalid symbol"):
            asm.assemble("@BAD-CHAR\nD=A\n")

    def test_out_of_range_a_instruction(self) -> None:
        with self.assertRaisesRegex(ValueError, "out of range"):
            asm.assemble("@32768\nD=A\n")

    def test_out_of_range_symbolic_a_instruction(self) -> None:
        with self.assertRaisesRegex(ValueError, "resolved 'BIG'=32768"):
            asm.second_pass(["@BIG"], {"BIG": 32768})

    def test_unknown_comp(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unknown comp"):
            asm.parse_c("D=Q")

    def test_unknown_jump(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unknown jump"):
            asm.parse_c("D;JNOPE")

    def test_unknown_dest(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unknown dest"):
            asm.parse_c("X=1")

    def test_duplicate_dest_register(self) -> None:
        with self.assertRaisesRegex(ValueError, "Duplicate register"):
            asm.parse_c("DD=1")


if __name__ == "__main__":
    unittest.main()
