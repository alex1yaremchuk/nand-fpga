#!/usr/bin/env python3
"""
Unified TUI launcher for hack-fpga workflows.

Usage:
  python tools/hack_cli.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = REPO_ROOT / ".hack_cli.json"

DEFAULT_CONFIG = {
    "port": "COM7",
    "baud": 115200,
    "rect_height": 16,
    "viewer_words_per_row": 8,
    "viewer_rows": 32,
    "cable_index": "4",
    "device": "GW2A-18C",
    "preset": "bram_final",
}


def _enable_windows_ansi() -> None:
    if os.name == "nt":
        # Enables ANSI escape processing on modern Windows consoles.
        os.system("")


def _fmt_cmd(cmd: Sequence[str]) -> str:
    if os.name == "nt":
        return subprocess.list2cmdline(list(cmd))
    return " ".join(cmd)


def _read_key() -> str:
    if os.name == "nt":
        import msvcrt

        ch = msvcrt.getwch()
        if ch in ("\x00", "\xe0"):
            ch2 = msvcrt.getwch()
            if ch2 == "H":
                return "UP"
            if ch2 == "P":
                return "DOWN"
            return "OTHER"
        if ch == "\r":
            return "ENTER"
        if ch == "\x1b":
            return "ESC"
        if ch in ("q", "Q"):
            return "QUIT"
        if ch in ("\x08",):
            return "BACK"
        return ch

    # Minimal POSIX fallback.
    import termios
    import tty

    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        ch = sys.stdin.read(1)
        if ch == "\x1b":
            seq = sys.stdin.read(2)
            if seq == "[A":
                return "UP"
            if seq == "[B":
                return "DOWN"
            return "ESC"
        if ch in ("\n", "\r"):
            return "ENTER"
        if ch in ("q", "Q"):
            return "QUIT"
        if ch == "\x7f":
            return "BACK"
        return ch
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


@dataclass
class MenuItem:
    label: str
    action: Callable[[], None]
    hint: str = ""


class HackCli:
    def __init__(self) -> None:
        self.config = self._load_config()
        _enable_windows_ansi()

    def _load_config(self) -> dict:
        cfg = dict(DEFAULT_CONFIG)
        if CONFIG_PATH.exists():
            try:
                raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
                if isinstance(raw, dict):
                    cfg.update(raw)
            except Exception:
                pass
        return cfg

    def _save_config(self) -> None:
        CONFIG_PATH.write_text(json.dumps(self.config, indent=2), encoding="utf-8")

    def _clear(self) -> None:
        print("\x1b[2J\x1b[H", end="")

    def _pause(self, message: str = "Press Enter to return...") -> None:
        try:
            input(f"\n{message}")
        except EOFError:
            pass

    def _prompt(self, label: str, default: str) -> str:
        value = input(f"{label} [{default}]: ").strip()
        return value if value else default

    def _run(self, title: str, cmd: Sequence[str], *, cwd: Path | None = None) -> int:
        if cwd is None:
            cwd = REPO_ROOT
        self._clear()
        print(title)
        print("=" * len(title))
        print(f"[cwd] {cwd}")
        print(f"[cmd] {_fmt_cmd(cmd)}\n")
        rc = subprocess.call(list(cmd), cwd=str(cwd))
        print(f"\n[exit] {rc}")
        self._pause()
        return rc

    def _show_text(self, title: str, body: str) -> None:
        self._clear()
        print(title)
        print("=" * len(title))
        print(body)
        self._pause()

    def _select(self, title: str, items: list[MenuItem]) -> int | None:
        idx = 0
        while True:
            self._clear()
            print("hack-fpga CLI")
            print("============")
            print(
                f"Port={self.config['port']}  Baud={self.config['baud']}  "
                f"RectHeight={self.config['rect_height']}"
            )
            print(f"Preset={self.config.get('preset', 'sim_only')}")
            print(f"Config: {CONFIG_PATH}")
            print("")
            print(title)
            print("-" * len(title))
            for i, item in enumerate(items):
                prefix = ">" if i == idx else " "
                hint = f" - {item.hint}" if item.hint else ""
                print(f"{prefix} {item.label}{hint}")
            print("\nKeys: Up/Down, Enter select, Esc/Backspace back, q quit")

            key = _read_key()
            if key == "UP":
                idx = (idx - 1) % len(items)
            elif key == "DOWN":
                idx = (idx + 1) % len(items)
            elif key == "ENTER":
                return idx
            elif key in ("ESC", "BACK", "QUIT"):
                return None

    def _ps(self, script_rel: str, *extra: str) -> list[str]:
        return [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(REPO_ROOT / script_rel),
            *extra,
        ]

    def _py(self, script_rel: str, *extra: str) -> list[str]:
        return [sys.executable, str(REPO_ROOT / script_rel), *extra]

    def _set_port(self) -> None:
        self._clear()
        value = self._prompt("COM port", str(self.config["port"]))
        self.config["port"] = value
        self._save_config()
        self._show_text("Settings", f"Saved port={value}")

    def _set_baud(self) -> None:
        self._clear()
        cur = str(self.config["baud"])
        value = self._prompt("Baud", cur)
        try:
            baud = int(value)
            if baud <= 0:
                raise ValueError("baud must be > 0")
        except Exception as exc:
            self._show_text("Settings error", f"Invalid baud '{value}': {exc}")
            return
        self.config["baud"] = baud
        self._save_config()
        self._show_text("Settings", f"Saved baud={baud}")

    def _set_rect_height(self) -> None:
        self._clear()
        cur = str(self.config["rect_height"])
        value = self._prompt("Rect height (1..256)", cur)
        try:
            h = int(value)
            if h < 1 or h > 256:
                raise ValueError("height out of range")
        except Exception as exc:
            self._show_text("Settings error", f"Invalid height '{value}': {exc}")
            return
        self.config["rect_height"] = h
        self._save_config()
        self._show_text("Settings", f"Saved rect_height={h}")

    def _set_cable(self) -> None:
        self._clear()
        value = self._prompt("Cable index", str(self.config["cable_index"]))
        self.config["cable_index"] = value
        self._save_config()
        self._show_text("Settings", f"Saved cable_index={value}")

    def _set_device(self) -> None:
        self._clear()
        value = self._prompt("FPGA device", str(self.config["device"]))
        self.config["device"] = value
        self._save_config()
        self._show_text("Settings", f"Saved device={value}")

    def _detect_ports(self) -> None:
        self._run(
            "Detect COM Ports",
            [
                "powershell",
                "-NoProfile",
                "-Command",
                "[System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object",
            ],
        )

    def menu_settings(self) -> None:
        items = [
            MenuItem("Set COM port", self._set_port),
            MenuItem("Set baud", self._set_baud),
            MenuItem("Set Rect height", self._set_rect_height),
            MenuItem("Set cable index", self._set_cable),
            MenuItem("Set FPGA device", self._set_device),
            MenuItem("Detect COM ports", self._detect_ports),
            MenuItem("Back", lambda: None),
        ]
        while True:
            idx = self._select("Settings", items)
            if idx is None or idx == len(items) - 1:
                return
            items[idx].action()

    def menu_build_flash(self) -> None:
        def flash_defaults() -> None:
            self._run(
                "Build + Flash FPGA (configured cable/device)",
                [
                    "cmd",
                    "/c",
                    str(REPO_ROOT / "flash_blink_sram.cmd"),
                    str(self.config["cable_index"]),
                    str(self.config["device"]),
                ],
                cwd=REPO_ROOT,
            )

        def flash_script_defaults() -> None:
            self._run(
                "Build + Flash FPGA (script defaults)",
                ["cmd", "/c", str(REPO_ROOT / "flash_blink_sram.cmd")],
                cwd=REPO_ROOT,
            )

        items = [
            MenuItem("Build + Flash (configured cable/device)", flash_defaults),
            MenuItem("Build + Flash (script defaults)", flash_script_defaults),
            MenuItem("Back", lambda: None),
        ]
        while True:
            idx = self._select("Build / Flash", items)
            if idx is None or idx == len(items) - 1:
                return
            items[idx].action()

    def menu_demos(self) -> None:
        port = str(self.config["port"])
        baud = str(self.config["baud"])
        rect_height = str(self.config["rect_height"])
        wpr = str(self.config["viewer_words_per_row"])
        rows = str(self.config["viewer_rows"])

        items = [
            MenuItem(
                "Rect demo (viewer)",
                lambda: self._run(
                    "Rect Demo (viewer)",
                    self._ps(
                        "tools/run_rect_uart_viewer_demo.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-WordsPerRow",
                        wpr,
                        "-Rows",
                        rows,
                        "-RectHeight",
                        rect_height,
                    ),
                ),
            ),
            MenuItem(
                "Rect demo (load only)",
                lambda: self._run(
                    "Rect Demo (load only)",
                    self._ps(
                        "tools/run_rect_uart_viewer_demo.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-WordsPerRow",
                        wpr,
                        "-Rows",
                        rows,
                        "-RectHeight",
                        rect_height,
                        "-NoViewer",
                    ),
                ),
            ),
            MenuItem(
                "Keyboard interactive demo",
                lambda: self._run(
                    "Keyboard Interactive Demo",
                    self._ps(
                        "tools/run_keyboard_interactive_demo.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-WordsPerRow",
                        wpr,
                        "-Rows",
                        rows,
                    ),
                ),
            ),
            MenuItem(
                "Keyboard demo (load only)",
                lambda: self._run(
                    "Keyboard Demo (load only)",
                    self._ps(
                        "tools/run_keyboard_interactive_demo.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-WordsPerRow",
                        wpr,
                        "-Rows",
                        rows,
                        "-NoViewer",
                    ),
                ),
            ),
            MenuItem(
                "Snake demo (viewer)",
                lambda: self._run(
                    "Snake Demo (viewer)",
                    self._ps(
                        "tools/run_snake_demo.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-WordsPerRow",
                        wpr,
                        "-Rows",
                        rows,
                    ),
                ),
            ),
            MenuItem(
                "Snake demo (load only)",
                lambda: self._run(
                    "Snake Demo (load only)",
                    self._ps(
                        "tools/run_snake_demo.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-WordsPerRow",
                        wpr,
                        "-Rows",
                        rows,
                        "-NoViewer",
                    ),
                ),
            ),
            MenuItem("Back", lambda: None),
        ]
        while True:
            idx = self._select("Demos", items)
            if idx is None or idx == len(items) - 1:
                return
            items[idx].action()

    def _run_named_preset(self, preset: str) -> None:
        port = str(self.config["port"])
        baud = str(self.config["baud"])

        if preset == "bram_final":
            self._run(
                "Preset bram_final",
                self._ps(
                    "tools/run_bram_final_regression.ps1",
                    "-Fetch",
                    "-Port",
                    port,
                    "-Baud",
                    baud,
                    "-OutDir",
                    str(REPO_ROOT / "build/presets/bram_final"),
                ),
            )
            return

        if preset == "sim_only":
            self._run(
                "Preset sim_only",
                self._ps(
                    "tools/run_daily_regression_bundle.ps1",
                    "-Fetch",
                    "-OutDir",
                    str(REPO_ROOT / "build/presets/sim_only"),
                ),
            )
            return

        if preset == "fpga_fast":
            self._run(
                "Preset fpga_fast",
                self._ps(
                    "tools/run_jack_official_runtime_fpga_subset_hw.ps1",
                    "-Fetch",
                    "-Port",
                    port,
                    "-Baud",
                    baud,
                    "-Case",
                    "Seven,ConvertToBin,Average,Square",
                    "-OutDir",
                    str(REPO_ROOT / "build/presets/fpga_fast_runtime_subset"),
                ),
            )
            return

        if preset == "fpga_full":
            self._run(
                "Preset fpga_full",
                self._ps(
                    "tools/run_daily_regression_bundle.ps1",
                    "-Fetch",
                    "-Port",
                    port,
                    "-Baud",
                    baud,
                    "-Project12Extended",
                    "-FailOnFpgaFitBudgetOverflow",
                    "-FailFast",
                    "-OutDir",
                    str(REPO_ROOT / "build/presets/fpga_full"),
                ),
            )
            return

        self._show_text("Preset error", f"Unknown preset: {preset}")

    def _set_default_preset(self) -> None:
        preset_items = [
            MenuItem("bram_final", lambda: None),
            MenuItem("sim_only", lambda: None),
            MenuItem("fpga_fast", lambda: None),
            MenuItem("fpga_full", lambda: None),
            MenuItem("Back", lambda: None),
        ]
        idx = self._select("Default Preset", preset_items)
        if idx is None or idx == len(preset_items) - 1:
            return
        selected = preset_items[idx].label
        self.config["preset"] = selected
        self._save_config()
        self._show_text("Settings", f"Saved preset={selected}")

    def menu_presets(self) -> None:
        items = [
            MenuItem(
                "Run preset: bram_final",
                lambda: self._run_named_preset("bram_final"),
                "Recommended: BRAM ship gate (sim + hw subset + core os_jack strict)",
            ),
            MenuItem(
                "Run preset: sim_only",
                lambda: self._run_named_preset("sim_only"),
                "Daily regression (sim)",
            ),
            MenuItem(
                "Run preset: fpga_fast",
                lambda: self._run_named_preset("fpga_fast"),
                "Pinned 4-case runtime subset on hardware",
            ),
            MenuItem(
                "Run preset: fpga_full",
                lambda: self._run_named_preset("fpga_full"),
                "Legacy strict: expected fail until extended os_jack fits fpga_fit ROM16K",
            ),
            MenuItem(
                "Run default preset",
                lambda: self._run_named_preset(str(self.config.get("preset", "sim_only"))),
                "Uses preset from .hack_cli.json",
            ),
            MenuItem("Set default preset", self._set_default_preset),
            MenuItem("Back", lambda: None),
        ]
        while True:
            idx = self._select("Presets", items)
            if idx is None or idx == len(items) - 1:
                return
            items[idx].action()

    def menu_tests(self) -> None:
        port = str(self.config["port"])
        baud = str(self.config["baud"])
        items = [
            MenuItem(
                "Assembler unit tests",
                lambda: self._run(
                    "Assembler Unit Tests",
                    self._ps("tools/run_hack_asm_tests.ps1"),
                ),
            ),
            MenuItem(
                "VM translator unit tests",
                lambda: self._run(
                    "VM Translator Unit Tests",
                    self._ps("tools/run_hack_vm_tests.ps1"),
                ),
            ),
            MenuItem(
                "Jack tokenizer unit tests",
                lambda: self._run(
                    "Jack Tokenizer Unit Tests",
                    self._ps("tools/run_hack_jack_tests.ps1"),
                ),
            ),
            MenuItem(
                "Jack pipeline smoke (sim_full)",
                lambda: self._run(
                    "Jack Pipeline Smoke",
                    self._ps(
                        "tools/run_jack_pipeline_smoke.ps1",
                        "-JackInput",
                        str(REPO_ROOT / "tools/programs/JackSmokeSys.jack"),
                        "-Profile",
                        "sim_full",
                        "-Cycles",
                        "200",
                        "-ExpectAddr",
                        "16",
                        "-ExpectValue",
                        "5",
                        "-Bootstrap",
                    ),
                ),
            ),
            MenuItem(
                "Jack dir pipeline smoke (sim_full)",
                lambda: self._run(
                    "Jack Dir Pipeline Smoke",
                    self._ps(
                        "tools/run_jack_pipeline_smoke.ps1",
                        "-JackInput",
                        str(REPO_ROOT / "tools/programs/JackDirSmoke"),
                        "-Profile",
                        "sim_full",
                        "-Cycles",
                        "300",
                        "-ExpectAddr",
                        "16",
                        "-ExpectValue",
                        "4",
                        "-Bootstrap",
                    ),
                ),
            ),
            MenuItem(
                "Jack corpus (sim_full)",
                lambda: self._run(
                    "Jack Corpus (sim_full)",
                    self._ps(
                        "tools/run_jack_corpus_sim.ps1",
                        "-Profile",
                        "sim_full",
                    ),
                ),
            ),
            MenuItem(
                "Official Jack corpus (sim_full)",
                lambda: self._run(
                    "Official Jack Corpus (sim_full)",
                    self._ps(
                        "tools/run_jack_official_corpus_sim.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Official Jack runtime (sim_full)",
                lambda: self._run(
                    "Official Jack Runtime (sim_full)",
                    self._ps(
                        "tools/run_jack_official_runtime_sim.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Official Jack runtime OS compile smoke",
                lambda: self._run(
                    "Official Jack Runtime OS Compile Smoke",
                    self._ps(
                        "tools/run_jack_official_runtime_os_compile_smoke.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Official Jack runtime fpga_fit subset (sim)",
                lambda: self._run(
                    "Official Jack Runtime fpga_fit Subset (sim)",
                    self._ps(
                        "tools/run_jack_official_runtime_fpga_subset_sim.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Official Jack runtime fpga_fit subset (hardware)",
                lambda: self._run(
                    "Official Jack Runtime fpga_fit Subset (hardware)",
                    self._ps(
                        "tools/run_jack_official_runtime_fpga_subset_hw.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 API smoke (sim_full)",
                lambda: self._run(
                    "Project 12 API Smoke (sim_full)",
                    self._ps(
                        "tools/run_jack_project12_api_smoke.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 OS compile smoke",
                lambda: self._run(
                    "Project 12 OS Compile Smoke",
                    self._ps(
                        "tools/run_jack_project12_os_compile_smoke.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 OS strict smoke",
                lambda: self._run(
                    "Project 12 OS Strict Smoke",
                    self._ps(
                        "tools/run_jack_project12_os_strict_smoke.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 OS strict all + extended",
                lambda: self._run(
                    "Project 12 OS Strict All + Extended",
                    self._ps(
                        "tools/run_jack_project12_os_strict_smoke.ps1",
                        "-Fetch",
                        "-IncludeStringTest",
                        "-IncludeExtendedTests",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 API + extended (sim_full)",
                lambda: self._run(
                    "Project 12 API + extended (sim_full)",
                    self._ps(
                        "tools/run_jack_project12_api_smoke.ps1",
                        "-Fetch",
                        "-IncludeExtendedTests",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 KeyboardTest (sim_full)",
                lambda: self._run(
                    "Project 12 KeyboardTest (sim_full)",
                    self._ps(
                        "tools/run_jack_project12_api_smoke.ps1",
                        "-Fetch",
                        "-IncludeExtendedTests",
                        "-Case",
                        "KeyboardTest",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 API + StringTest (sim_full)",
                lambda: self._run(
                    "Project 12 API + StringTest (sim_full)",
                    self._ps(
                        "tools/run_jack_project12_api_smoke.ps1",
                        "-Fetch",
                        "-IncludeStringTest",
                    ),
                ),
            ),
            MenuItem(
                "Project 12 API all + extended (sim_full)",
                lambda: self._run(
                    "Project 12 API all + extended (sim_full)",
                    self._ps(
                        "tools/run_jack_project12_api_smoke.ps1",
                        "-Fetch",
                        "-IncludeStringTest",
                        "-IncludeExtendedTests",
                    ),
                ),
            ),
            MenuItem(
                "Jack String runtime smoke (sim_full)",
                lambda: self._run(
                    "Jack String Runtime Smoke (sim_full)",
                    self._ps(
                        "tools/run_jack_string_runtime_smoke.ps1",
                    ),
                ),
            ),
            MenuItem(
                "Jack Keyboard runtime smoke (sim_full)",
                lambda: self._run(
                    "Jack Keyboard Runtime Smoke (sim_full)",
                    self._ps(
                        "tools/run_jack_keyboard_runtime_smoke.ps1",
                    ),
                ),
            ),
            MenuItem(
                "Jack Keyboard char runtime smoke (sim_full)",
                lambda: self._run(
                    "Jack Keyboard Char Runtime Smoke (sim_full)",
                    self._ps(
                        "tools/run_jack_keyboard_char_runtime_smoke.ps1",
                    ),
                ),
            ),
            MenuItem(
                "Jack runtime extended smoke (sim_full)",
                lambda: self._run(
                    "Jack Runtime Extended Smoke (sim_full)",
                    self._ps(
                        "tools/run_jack_runtime_extended_smoke.ps1",
                    ),
                ),
            ),
            MenuItem(
                "Jack FPGA smoke (hardware)",
                lambda: self._run(
                    "Jack FPGA Smoke",
                    self._ps(
                        "tools/run_jack_fpga_smoke.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-JackInput",
                        str(REPO_ROOT / "tools/programs/JackSmokeSys.jack"),
                        "-Cycles",
                        "200",
                        "-ExpectAddr",
                        "16",
                        "-ExpectValue",
                        "5",
                        "-Bootstrap",
                    ),
                ),
            ),
            MenuItem(
                "Jack dir FPGA smoke (hardware)",
                lambda: self._run(
                    "Jack Dir FPGA Smoke",
                    self._ps(
                        "tools/run_jack_fpga_smoke.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-JackInput",
                        str(REPO_ROOT / "tools/programs/JackDirSmoke"),
                        "-Cycles",
                        "300",
                        "-ExpectAddr",
                        "16",
                        "-ExpectValue",
                        "4",
                        "-Bootstrap",
                    ),
                ),
            ),
            MenuItem(
                "Jack corpus FPGA (hardware)",
                lambda: self._run(
                    "Jack Corpus FPGA",
                    self._ps(
                        "tools/run_jack_corpus_fpga.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                    ),
                ),
            ),
            MenuItem(
                "VM pipeline smoke (sim_full)",
                lambda: self._run(
                    "VM Pipeline Smoke",
                    self._ps(
                        "tools/run_vm_pipeline_smoke.ps1",
                        "-VmInput",
                        str(REPO_ROOT / "tools/programs/VmSmokeSys.vm"),
                        "-Profile",
                        "sim_full",
                        "-Cycles",
                        "200",
                        "-ExpectAddr",
                        "5",
                        "-ExpectValue",
                        "5",
                        "-Bootstrap",
                    ),
                ),
            ),
            MenuItem(
                "VM FPGA smoke (hardware)",
                lambda: self._run(
                    "VM FPGA Smoke",
                    self._ps(
                        "tools/run_vm_fpga_smoke.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-VmInput",
                        str(REPO_ROOT / "tools/programs/VmSmokeSys.vm"),
                        "-Cycles",
                        "200",
                        "-Bootstrap",
                    ),
                ),
            ),
            MenuItem(
                "fpga_fit resource budget checks",
                lambda: self._run(
                    "fpga_fit Resource Budget Checks",
                    self._ps("tools/check_fpga_fit_resource_budgets.ps1"),
                ),
            ),
            MenuItem(
                "BRAM final regression (+hardware)",
                lambda: self._run(
                    "BRAM Final Regression (+hardware)",
                    self._ps(
                        "tools/run_bram_final_regression.ps1",
                        "-Fetch",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                    ),
                ),
            ),
            MenuItem(
                "Daily regression bundle (sim, quick)",
                lambda: self._run(
                    "Daily Regression Bundle (sim, quick)",
                    self._ps(
                        "tools/run_daily_regression_bundle.ps1",
                        "-Fetch",
                    ),
                ),
            ),
            MenuItem(
                "Daily regression bundle (+hardware, pinned 4-case)",
                lambda: self._run(
                    "Daily Regression Bundle (+hardware, pinned 4-case)",
                    self._ps(
                        "tools/run_daily_regression_bundle.ps1",
                        "-Fetch",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                    ),
                ),
            ),
            MenuItem(
                "Daily regression bundle (+hardware + project12 extended)",
                lambda: self._run(
                    "Daily Regression Bundle (+hardware + project12 extended)",
                    self._ps(
                        "tools/run_daily_regression_bundle.ps1",
                        "-Fetch",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Project12Extended",
                    ),
                ),
            ),
            MenuItem(
                "UART bridge TB (simulation)",
                lambda: self._run(
                    "UART Bridge TB",
                    self._ps("tools/run_uart_bridge_tb.ps1"),
                ),
            ),
            MenuItem(
                "Keyboard smoke + soak (hardware)",
                lambda: self._run(
                    "Keyboard Smoke + Soak",
                    self._ps(
                        "tools/run_keyboard_uart_smoke.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                    ),
                ),
            ),
            MenuItem(
                "Keyboard latency probe (hardware)",
                lambda: self._run(
                    "Keyboard Latency Probe",
                    self._ps(
                        "tools/run_keyboard_uart_latency.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                    ),
                ),
            ),
            MenuItem(
                "Golden compare strict (hardware)",
                lambda: self._run(
                    "Golden Compare Strict",
                    self._ps(
                        "tools/compare_fpga_uart_against_golden.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                        "-StrictPcDump",
                    ),
                ),
            ),
            MenuItem(
                "Golden compare normal (hardware)",
                lambda: self._run(
                    "Golden Compare Normal",
                    self._ps(
                        "tools/compare_fpga_uart_against_golden.ps1",
                        "-Port",
                        port,
                        "-Baud",
                        baud,
                        "-Profile",
                        "fpga_fit",
                    ),
                ),
            ),
            MenuItem("Back", lambda: None),
        ]
        while True:
            idx = self._select("Tests", items)
            if idx is None or idx == len(items) - 1:
                return
            items[idx].action()

    def _uart_prompt_peek(self) -> None:
        self._clear()
        addr = self._prompt("Address (hex or dec)", "0x4000")
        self._run(
            "UART Peek",
            self._py(
                "tools/hack_uart_client.py",
                "--port",
                str(self.config["port"]),
                "--baud",
                str(self.config["baud"]),
                "peek",
                addr,
            ),
        )

    def _uart_prompt_poke(self) -> None:
        self._clear()
        addr = self._prompt("Address (hex or dec)", "0x0002")
        data = self._prompt("Data (hex or dec)", "0x1234")
        self._run(
            "UART Poke",
            self._py(
                "tools/hack_uart_client.py",
                "--port",
                str(self.config["port"]),
                "--baud",
                str(self.config["baud"]),
                "poke",
                addr,
                data,
            ),
        )

    def menu_uart(self) -> None:
        port = str(self.config["port"])
        baud = str(self.config["baud"])
        wpr = str(self.config["viewer_words_per_row"])
        rows = str(self.config["viewer_rows"])

        items = [
            MenuItem(
                "State",
                lambda: self._run(
                    "UART State",
                    self._py(
                        "tools/hack_uart_client.py",
                        "--port",
                        port,
                        "--baud",
                        baud,
                        "state",
                    ),
                ),
            ),
            MenuItem(
                "Protocol diag",
                lambda: self._run(
                    "UART Protocol Diag",
                    self._py(
                        "tools/hack_uart_client.py",
                        "--port",
                        port,
                        "--baud",
                        baud,
                        "diag",
                    ),
                ),
            ),
            MenuItem(
                "Viewer (auto-run)",
                lambda: self._run(
                    "UART Viewer",
                    self._py(
                        "tools/hack_uart_client.py",
                        "--port",
                        port,
                        "--baud",
                        baud,
                        "viewer",
                        "--words-per-row",
                        wpr,
                        "--rows",
                        rows,
                        "--auto-run",
                        "--hard-clear-per-frame",
                    ),
                ),
            ),
            MenuItem("Peek word", self._uart_prompt_peek),
            MenuItem("Poke word", self._uart_prompt_poke),
            MenuItem(
                "Reset CPU",
                lambda: self._run(
                    "UART Reset",
                    self._py(
                        "tools/hack_uart_client.py",
                        "--port",
                        port,
                        "--baud",
                        baud,
                        "reset",
                    ),
                ),
            ),
            MenuItem(
                "Halt CPU",
                lambda: self._run(
                    "UART Halt",
                    self._py(
                        "tools/hack_uart_client.py",
                        "--port",
                        port,
                        "--baud",
                        baud,
                        "halt",
                    ),
                ),
            ),
            MenuItem(
                "Keyboard key-up (kbd 0)",
                lambda: self._run(
                    "UART KBD 0",
                    self._py(
                        "tools/hack_uart_client.py",
                        "--port",
                        port,
                        "--baud",
                        baud,
                        "kbd",
                        "0x0000",
                    ),
                ),
            ),
            MenuItem("Back", lambda: None),
        ]
        while True:
            idx = self._select("UART Tools", items)
            if idx is None or idx == len(items) - 1:
                return
            items[idx].action()

    def run(self) -> int:
        main_items = [
            MenuItem("Build / Flash FPGA", self.menu_build_flash),
            MenuItem("Demos", self.menu_demos),
            MenuItem("Tests", self.menu_tests),
            MenuItem("Presets", self.menu_presets),
            MenuItem("UART Tools", self.menu_uart),
            MenuItem("Settings", self.menu_settings),
            MenuItem("Quit", lambda: None),
        ]

        while True:
            idx = self._select("Main Menu", main_items)
            if idx is None or idx == len(main_items) - 1:
                self._clear()
                print("Bye.")
                return 0
            main_items[idx].action()


def main() -> int:
    app = HackCli()
    return app.run()


if __name__ == "__main__":
    raise SystemExit(main())
