import sys
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLS_DIR = REPO_ROOT / "tools"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import hack_uart_client as huc  # noqa: E402


class _ScriptedSerial:
    def __init__(self, *_, timeout=0.001, script=None, **__):
        self.timeout = timeout
        self._script = [list(seq) for seq in (script or [])]
        self._active_reads = []
        self.writes = []

    def write(self, payload: bytes) -> None:
        self.writes.append(bytes(payload))
        idx = len(self.writes) - 1
        if idx < len(self._script):
            self._active_reads = list(self._script[idx])
        else:
            self._active_reads = []

    def read(self, n: int) -> bytes:
        if not self._active_reads:
            return b""
        chunk = self._active_reads.pop(0)
        if len(chunk) <= n:
            return chunk
        self._active_reads.insert(0, chunk[n:])
        return chunk[:n]

    def flush(self) -> None:
        return None

    def reset_input_buffer(self) -> None:
        self._active_reads = []

    def close(self) -> None:
        return None


class HackUartClientRetryTests(unittest.TestCase):
    def test_read_exact_collects_partial_bytes(self) -> None:
        ser = _ScriptedSerial(script=[[bytes([huc.RSP_PEEK]), bytes([0x12]), bytes([0x34])]])
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient("COMX", 115200, timeout=0.001, xfer_retries=0, seq_mode="off")
            try:
                got = cli.peek(0x4000)
            finally:
                cli.close()
        self.assertEqual(got, 0x1234)
        self.assertEqual(len(ser.writes), 1)

    def test_retry_on_short_read_for_retryable_commands(self) -> None:
        # First transfer times out (no response), second transfer succeeds.
        ser = _ScriptedSerial(
            script=[
                [b"", b"", b"", b""],
                [bytes([huc.RSP_PEEK, 0xAB, 0xCD])],
            ]
        )
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient(
                "COMX", 115200, timeout=0.001, xfer_retries=1, xfer_retry_delay=0.0, seq_mode="off"
            )
            try:
                got = cli.peek(0x0002)
            finally:
                cli.close()
        self.assertEqual(got, 0xABCD)
        self.assertEqual(len(ser.writes), 2, "peek should retry once on short read")

    def test_run_is_not_retried_on_short_read(self) -> None:
        ser = _ScriptedSerial(script=[[b"", b"", b""]])
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient(
                "COMX", 115200, timeout=0.001, xfer_retries=3, xfer_retry_delay=0.0, seq_mode="off"
            )
            try:
                with self.assertRaisesRegex(RuntimeError, "short read"):
                    cli.run(1)
            finally:
                cli.close()
        self.assertEqual(len(ser.writes), 1, "run must not retry to avoid double execution")

    def test_seq_auto_uses_diag_probe_and_falls_back_to_legacy(self) -> None:
        ser = _ScriptedSerial(
            script=[
                [bytes([huc.RSP_DIAG, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])],
                [bytes([huc.RSP_PEEK, 0xCA, 0xFE])],
            ]
        )
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient("COMX", 115200, timeout=0.001, xfer_retries=0, seq_mode="auto")
            try:
                got = cli.peek(0x0000)
            finally:
                cli.close()
        self.assertEqual(got, 0xCAFE)
        self.assertEqual(len(ser.writes), 2)
        self.assertEqual(ser.writes[0][0], huc.CMD_DIAG)
        self.assertEqual(ser.writes[1][0], huc.CMD_PEEK)

    def test_seq_wrapper_response_is_parsed(self) -> None:
        # seq starts from 1 on first sequenced command.
        ser = _ScriptedSerial(
            script=[
                [
                    bytes([huc.RSP_SEQ]),
                    bytes([0x01, 0x03]),
                    bytes([huc.RSP_PEEK, 0x56, 0x78]),
                ]
            ]
        )
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient("COMX", 115200, timeout=0.001, xfer_retries=0, seq_mode="on")
            try:
                got = cli.peek(0x4000)
            finally:
                cli.close()
        self.assertEqual(got, 0x5678)
        self.assertEqual(len(ser.writes), 1)
        self.assertEqual(ser.writes[0][0], huc.CMD_SEQ)

    def test_seq_auto_uses_seq_after_capability_probe(self) -> None:
        ser = _ScriptedSerial(
            script=[
                [bytes([huc.RSP_DIAG, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])],
                [bytes([huc.RSP_SEQ, 0x01, 0x03, huc.RSP_PEEK, 0x12, 0x34])],
            ]
        )
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient("COMX", 115200, timeout=0.001, xfer_retries=0, seq_mode="auto")
            try:
                got = cli.peek(0x0001)
            finally:
                cli.close()
        self.assertEqual(got, 0x1234)
        self.assertEqual(len(ser.writes), 2)
        self.assertEqual(ser.writes[0][0], huc.CMD_DIAG)
        self.assertEqual(ser.writes[1][0], huc.CMD_SEQ)

    def test_screen_delta_seq_parsed(self) -> None:
        # auto probe says seq capable, then SCRDELTA wrapped response.
        ser = _ScriptedSerial(
            script=[
                [bytes([huc.RSP_DIAG, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])],
                [
                    bytes([huc.RSP_SEQ]),
                    bytes([0x01]),
                    bytes([0x07]),
                    bytes([huc.RSP_SCRDELTA, 0x03, 0x01, 0x40, 0x00, 0x12, 0x34]),
                ],
            ]
        )
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient("COMX", 115200, timeout=0.001, xfer_retries=0, seq_mode="auto")
            try:
                deltas, more, wrapped = cli.screen_delta(max_entries=4, sync=False)
            finally:
                cli.close()
        self.assertEqual(deltas, [(0x4000, 0x1234)])
        self.assertTrue(more)
        self.assertTrue(wrapped)
        self.assertEqual(len(ser.writes), 2)
        self.assertEqual(ser.writes[1][0], huc.CMD_SEQ)

    def test_screen_delta_auto_falls_back_to_legacy_when_not_capable(self) -> None:
        ser = _ScriptedSerial(
            script=[
                [bytes([huc.RSP_DIAG, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])],
                [bytes([huc.RSP_SCRDELTA, 0x00, 0x00])],
            ]
        )
        with patch.object(huc.serial, "Serial", return_value=ser):
            cli = huc.HackUartClient("COMX", 115200, timeout=0.001, xfer_retries=0, seq_mode="auto")
            try:
                deltas, more, wrapped = cli.screen_delta(max_entries=1, sync=True)
            finally:
                cli.close()
        self.assertEqual(deltas, [])
        self.assertFalse(more)
        self.assertFalse(wrapped)
        self.assertEqual(len(ser.writes), 2)
        self.assertEqual(ser.writes[1][0], huc.CMD_SCRDELTA)


if __name__ == "__main__":
    unittest.main()
