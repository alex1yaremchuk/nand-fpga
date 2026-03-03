#!/usr/bin/env python3
"""
Keyboard latency probe over Hack UART bridge.

Measures time from host key event (CMD_KBD) to visible screen reaction
at SCREEN[0], and from key-up to clear back to SCREEN[0] == 0.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import time
from pathlib import Path

from hack_uart_client import HackUartClient, parse_hack_words


def quantile_ms(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = max(0, min(len(s) - 1, math.ceil(q * len(s)) - 1))
    return s[idx]


def summarize(values: list[float]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "p50": 0.0, "p95": 0.0, "max": 0.0, "mean": 0.0}
    return {
        "min": min(values),
        "p50": quantile_ms(values, 0.50),
        "p95": quantile_ms(values, 0.95),
        "max": max(values),
        "mean": statistics.mean(values),
    }


def wait_for_state(
    cli: HackUartClient,
    *,
    expected_screen0: int,
    expected_ram0: int,
    timeout_ms: int,
    run_cycles_per_poll: int,
) -> tuple[float, int] | None:
    start = time.perf_counter()
    deadline = start + (timeout_ms / 1000.0)
    polls = 0

    while time.perf_counter() < deadline:
        if run_cycles_per_poll > 0:
            cli.run(run_cycles_per_poll)
        screen0 = cli.peek(0x4000)
        ram0 = cli.peek(0x0000)
        polls += 1
        if screen0 == expected_screen0 and ram0 == expected_ram0:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            return elapsed_ms, polls

    return None


def build_report_text(
    iterations: int,
    run_cycles_per_poll: int,
    press_summary: dict[str, float],
    release_summary: dict[str, float],
) -> str:
    return "\n".join(
        [
            "Keyboard UART Latency Report",
            "",
            f"Iterations: {iterations}",
            f"Run cycles per poll: {run_cycles_per_poll}",
            "",
            "Press latency (kbd down -> SCREEN[0]=FFFF, RAM[0]=key) [ms]:",
            f"  min={press_summary['min']:.2f}",
            f"  p50={press_summary['p50']:.2f}",
            f"  p95={press_summary['p95']:.2f}",
            f"  mean={press_summary['mean']:.2f}",
            f"  max={press_summary['max']:.2f}",
            "",
            "Release latency (kbd up -> SCREEN[0]=0000, RAM[0]=0000) [ms]:",
            f"  min={release_summary['min']:.2f}",
            f"  p50={release_summary['p50']:.2f}",
            f"  p95={release_summary['p95']:.2f}",
            f"  mean={release_summary['mean']:.2f}",
            f"  max={release_summary['max']:.2f}",
            "",
        ]
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--hack-file", required=True)
    ap.add_argument("--rom-addr-w", type=int, default=14)
    ap.add_argument("--iterations", type=int, default=40)
    ap.add_argument("--press-timeout-ms", type=int, default=1500)
    ap.add_argument("--release-timeout-ms", type=int, default=1500)
    ap.add_argument("--run-cycles-per-poll", type=int, default=1)
    ap.add_argument("--clear-ram-words", type=int, default=16)
    ap.add_argument("--clear-screen-words", type=int, default=16)
    ap.add_argument("--rom-verify", action="store_true")
    ap.add_argument("--rom-write-retries", type=int, default=2)
    ap.add_argument("--p95-threshold-ms", type=float, default=150.0)
    ap.add_argument("--enforce-threshold", action="store_true")
    ap.add_argument("--out-json", default="")
    ap.add_argument("--out-report", default="")
    ap.add_argument("--open-retries", type=int, default=8)
    ap.add_argument("--open-retry-delay", type=float, default=0.25)
    args = ap.parse_args()

    if args.iterations < 1:
        raise RuntimeError(f"iterations must be >=1, got {args.iterations}")
    if args.rom_addr_w < 1 or args.rom_addr_w > 15:
        raise RuntimeError(f"rom_addr_w must be in [1..15], got {args.rom_addr_w}")

    words = parse_hack_words(args.hack_file)
    rom_words = 1 << args.rom_addr_w
    if len(words) > rom_words:
        raise RuntimeError(f"program does not fit ROM: {len(words)} > {rom_words}")

    key_seq = [0x0041, 0x005A, 0x0031, 0x0080, 0x0082]
    press_ms: list[float] = []
    release_ms: list[float] = []

    cli = HackUartClient(
        args.port,
        args.baud,
        timeout=1.0,
        open_retries=args.open_retries,
        open_retry_delay=args.open_retry_delay,
    )
    try:
        print(f"[INFO] Programming ROM words: {len(words)}")
        cli.kbd(0)
        cli.halt()
        cli.reset()

        for i, w in enumerate(words):
            cli.romw(i, w)
            if args.rom_verify:
                ok = False
                got = 0
                for _ in range(args.rom_write_retries + 1):
                    got = cli.romr(i)
                    if got == w:
                        ok = True
                        break
                    cli.romw(i, w)
                if not ok:
                    raise RuntimeError(
                        f"ROM verify mismatch at {i:04x}: got {got:04x}, expected {w:04x}"
                    )

        if args.rom_verify:
            print("[INFO] Verifying ROM...")
            for i, expected in enumerate(words):
                got = cli.romr(i)
                if got != expected:
                    raise RuntimeError(
                        f"ROM verify mismatch at {i:04x}: got {got:04x}, expected {expected:04x}"
                    )

        if args.clear_ram_words > 0:
            print(f"[INFO] Clearing RAM words: count={args.clear_ram_words}")
            for i in range(args.clear_ram_words):
                cli.poke(i, 0)
        if args.clear_screen_words > 0:
            print(f"[INFO] Clearing SCREEN words: count={args.clear_screen_words}")
            for i in range(args.clear_screen_words):
                cli.poke(0x4000 + i, 0)

        cli.kbd(0)
        cli.halt()
        cli.reset()

        print(
            "[INFO] Measuring latency: "
            f"iterations={args.iterations}, run_cycles_per_poll={args.run_cycles_per_poll}"
        )

        for i in range(args.iterations):
            key = key_seq[i % len(key_seq)]
            key_hex = f"0x{key:04x}"

            cli.kbd(key)
            down = wait_for_state(
                cli,
                expected_screen0=0xFFFF,
                expected_ram0=key,
                timeout_ms=args.press_timeout_ms,
                run_cycles_per_poll=args.run_cycles_per_poll,
            )
            if down is None:
                raise RuntimeError(
                    f"Iteration {i + 1}: timeout waiting key-down reaction for key={key_hex}"
                )
            press_ms.append(down[0])

            cli.kbd(0)
            up = wait_for_state(
                cli,
                expected_screen0=0x0000,
                expected_ram0=0x0000,
                timeout_ms=args.release_timeout_ms,
                run_cycles_per_poll=args.run_cycles_per_poll,
            )
            if up is None:
                raise RuntimeError(
                    f"Iteration {i + 1}: timeout waiting key-up reaction for key={key_hex}"
                )
            release_ms.append(up[0])

            if ((i + 1) % 10) == 0:
                print(f"[INFO] Latency progress: {i + 1}/{args.iterations}")

        press_summary = summarize(press_ms)
        release_summary = summarize(release_ms)

        report = {
            "port": args.port,
            "baud": args.baud,
            "iterations": args.iterations,
            "run_cycles_per_poll": args.run_cycles_per_poll,
            "press_ms": press_ms,
            "release_ms": release_ms,
            "press_summary_ms": press_summary,
            "release_summary_ms": release_summary,
            "threshold_ms": args.p95_threshold_ms,
            "threshold_ok": press_summary["p95"] <= args.p95_threshold_ms,
        }

        text = build_report_text(
            args.iterations,
            args.run_cycles_per_poll,
            press_summary,
            release_summary,
        )
        print("[OK] Keyboard latency probe completed.")
        print(text)
        print(
            f"[INFO] Threshold check: p95_press={press_summary['p95']:.2f} ms "
            f"(limit={args.p95_threshold_ms:.2f} ms) => "
            f"{'OK' if report['threshold_ok'] else 'FAIL'}"
        )

        if args.out_json:
            out_json = Path(args.out_json)
            out_json.parent.mkdir(parents=True, exist_ok=True)
            out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(f"[INFO] Wrote JSON: {out_json}")
        if args.out_report:
            out_report = Path(args.out_report)
            out_report.parent.mkdir(parents=True, exist_ok=True)
            out_report.write_text(text, encoding="utf-8")
            print(f"[INFO] Wrote report: {out_report}")

        if args.enforce_threshold and not report["threshold_ok"]:
            print("[ERROR] Keyboard latency threshold failed.")
            return 1
        return 0
    finally:
        try:
            cli.kbd(0)
        except Exception:
            pass
        try:
            cli.halt()
        except Exception:
            pass
        cli.close()


if __name__ == "__main__":
    raise SystemExit(main())
