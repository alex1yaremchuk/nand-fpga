from pathlib import Path
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.lib.colors import HexColor
from reportlab.pdfgen import canvas
from reportlab.pdfbase.pdfmetrics import stringWidth
from pypdf import PdfReader

out_pdf = Path('output/pdf/nand_fpga_app_summary.pdf')
out_pdf.parent.mkdir(parents=True, exist_ok=True)

PAGE_W, PAGE_H = letter
MARGIN_X = 0.6 * inch
TOP = PAGE_H - 0.55 * inch
BOTTOM = 0.55 * inch

c = canvas.Canvas(str(out_pdf), pagesize=letter)

# Palette + typography
COLOR_TITLE = HexColor('#0B1F3A')
COLOR_H = HexColor('#133B5C')
COLOR_TEXT = HexColor('#1F2937')
COLOR_MUTED = HexColor('#4B5563')

TITLE_FONT = 'Helvetica-Bold'
HEAD_FONT = 'Helvetica-Bold'
BODY_FONT = 'Helvetica'
MONO_FONT = 'Courier'

y = TOP


def wrap_text(text, font, size, max_w):
    words = text.split()
    lines = []
    cur = ''
    for w in words:
        cand = w if not cur else cur + ' ' + w
        if stringWidth(cand, font, size) <= max_w:
            cur = cand
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def draw_heading(text):
    global y
    c.setFillColor(COLOR_H)
    c.setFont(HEAD_FONT, 11)
    c.drawString(MARGIN_X, y, text)
    y -= 14


def draw_para(text, size=9.5, color=COLOR_TEXT, extra_gap=4):
    global y
    c.setFillColor(color)
    c.setFont(BODY_FONT, size)
    max_w = PAGE_W - 2 * MARGIN_X
    for line in wrap_text(text, BODY_FONT, size, max_w):
        c.drawString(MARGIN_X, y, line)
        y -= 12
    y -= extra_gap


def draw_bullets(items, size=9.5, indent=12, gap=3):
    global y
    max_w = PAGE_W - 2 * MARGIN_X - indent - 8
    c.setFillColor(COLOR_TEXT)
    c.setFont(BODY_FONT, size)
    for item in items:
        lines = wrap_text(item, BODY_FONT, size, max_w)
        c.drawString(MARGIN_X + 2, y, '-')
        c.drawString(MARGIN_X + indent, y, lines[0])
        y -= 12
        for ln in lines[1:]:
            c.drawString(MARGIN_X + indent, y, ln)
            y -= 12
        y -= gap


def draw_steps(items, size=9.0):
    global y
    max_w = PAGE_W - 2 * MARGIN_X - 16
    c.setFillColor(COLOR_TEXT)
    c.setFont(BODY_FONT, size)
    for i, item in enumerate(items, start=1):
        lines = wrap_text(item, BODY_FONT, size, max_w)
        c.drawString(MARGIN_X, y, f'{i}.')
        c.drawString(MARGIN_X + 14, y, lines[0])
        y -= 12
        for ln in lines[1:]:
            c.drawString(MARGIN_X + 14, y, ln)
            y -= 12
        y -= 2


# Title
c.setFillColor(COLOR_TITLE)
c.setFont(TITLE_FONT, 16)
c.drawString(MARGIN_X, y, 'nand-fpga App Summary (Repo-Based)')
y -= 18
c.setFillColor(COLOR_MUTED)
c.setFont(BODY_FONT, 8.5)
c.drawString(MARGIN_X, y, 'Source: README.md, doc/*.md, tools/*.ps1, tools/hack_uart_client.py, hack_computer/src/app/top.v')
y -= 16

# What it is
draw_heading('What it is')
draw_para(
    'A Tang Nano 20K FPGA implementation of the nand2tetris Hack computer, with a shared RTL codebase for PC simulation and FPGA-fit builds. '
    'The repo includes CPU/memory/UART integration, testbenches, and host tools for run control and screen/keyboard interaction.'
)

# Who it's for
draw_heading('Who it\'s for')
draw_para(
    'Primary persona: FPGA and digital design developers validating a Hack-compatible computer on hardware while using simulation-first regression workflows.'
)

# What it does
draw_heading('What it does')
draw_bullets([
    'Supports two build profiles: fpga_fit and sim_full (configurable ROM/SCREEN sizing in project_config.vh).',
    'Implements CPU core plus Hack-style memory/ROM mapping with synchronous timing contracts and dedicated timing testbenches.',
    'Provides an on-board control/UI path via TM1638 input/display integration in top.v.',
    'Exposes a UART bridge protocol for peek/poke/step/run/reset/state, keyboard injection, ROM read/write, halt, and screen deltas.',
    'Includes a Python UART client with state, viewer, watch, and runhack flows for interactive hardware control.',
    'Ships regression scripts for smoke tests, baseline program runs (Add/Max/Rect), and FPGA-vs-golden dump comparisons.'
])

# How it works
draw_heading('How it works (architecture)')
draw_bullets([
    'Top-level integration (hack_computer/src/app/top.v) wires cpu_core, rom32k_prog, memory_map, TM1638 IO blocks, and optional uart_bridge.',
    'cpu_core fetches instructions from ROM and exchanges data with memory_map (RAM/SCREEN/KBD path) on a single clock domain.',
    'project_config.vh controls profile-level knobs (ROM_ADDR_W, SCREEN_ADDR_W, UART enable/baud) for sim_full vs fpga_fit.',
    'Host-side PowerShell scripts compile/run Icarus testbenches and compare dump artifacts; hack_uart_client.py speaks the documented binary UART protocol.'
])

# How to run
draw_heading('How to run (minimal)')
draw_steps([
    'Install prerequisites used by scripts: Icarus Verilog (iverilog + vvp), Python 3, and pyserial.',
    'From repo root, run: powershell -ExecutionPolicy Bypass -File tools/run_hack_runner_smoke.ps1',
    'Run UART protocol testbench: powershell -ExecutionPolicy Bypass -File tools/run_uart_bridge_tb.ps1',
    'Optional hardware session: python tools/hack_uart_client.py --port COM5 viewer --words-per-row 8 --rows 8 --auto-run',
    'FPGA synthesis/programming setup instructions: Not found in repo.'
], size=8.9)

if y < BOTTOM:
    raise RuntimeError(f'Layout overflowed one page (y={y:.2f}, bottom={BOTTOM:.2f}).')

c.save()

reader = PdfReader(str(out_pdf))
if len(reader.pages) != 1:
    raise RuntimeError(f'Expected 1 page, got {len(reader.pages)} pages.')

print(out_pdf.resolve())
