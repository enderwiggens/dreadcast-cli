#!/usr/bin/env python3
"""Render real terminal output to PNG for the README.

Requires Python 3 with pyte (`pip install pyte`) and Google Chrome or Chromium
(set CHROME to its path if it isn't in the usual place).

  term2png.py inline <ansi-file> <out.png> [--cols N] [--max-rows N]
  term2png.py pty <out.png> --cols N --rows N [--wait SECONDS] -- command [args...]
  term2png.py gallery <out.png> "Title=image.png" ...

Inline output is replayed into a terminal emulator sized to fit. Full-screen programs
run in a pseudo-terminal, and the screen is captured after --wait seconds. Half-block
characters become real two-color cells, so pixel art stays crisp at any zoom.
"""
import fcntl, html, os, pty, select, signal, struct, subprocess, sys, tempfile, termios, time

import pyte
import wcwidth

CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
WORK = tempfile.mkdtemp(prefix="term2png-")
CELL_W, ROW_H, PAD = 8.4, 17, 20
BACKGROUND, FOREGROUND = "#0B1220", "#D7DDE6"
NAMED = {
    "black": "#1B2333", "red": "#E06C75", "green": "#98C379", "brown": "#E5C07B", "yellow": "#E5C07B",
    "blue": "#61AFEF", "magenta": "#C678DD", "cyan": "#56B6C2", "white": "#D7DDE6",
    "brightblack": "#5C6370", "brightred": "#E06C75", "brightgreen": "#98C379", "brightyellow": "#E5C07B",
    "brightblue": "#61AFEF", "brightmagenta": "#C678DD", "brightcyan": "#56B6C2", "brightwhite": "#FFFFFF",
}
FONT = "14px Menlo,'SF Mono',Consolas,'DejaVu Sans Mono',monospace"
EMOJI_FONT = "13px 'Apple Color Emoji','Noto Color Emoji',sans-serif"
PRESENTATION_SELECTOR = chr(0xFE0F)

# pyte drops the rest of a line after an emoji presentation selector, and terminals draw
# those emoji two cells wide. Each one is swapped for a wide placeholder (a CJK
# ideograph, which pyte also treats as two cells) and drawn as the original emoji.
EMOJI = {}


def protect_emoji(text):
    out = []
    for ch in text:
        if ch == PRESENTATION_SELECTOR and out:
            emoji = out.pop() + ch
            placeholder = next((k for k, v in EMOJI.items() if v == emoji), None)
            if placeholder is None:
                placeholder = chr(0x4E00 + len(EMOJI))
                EMOJI[placeholder] = emoji
            out.append(placeholder)
        else:
            out.append(ch)
    return "".join(out)


def color(value, default):
    if value in (None, "default"):
        return default
    if len(value) == 6 and all(c in "0123456789abcdefABCDEF" for c in value):
        return "#" + value
    return NAMED.get(value, default)


def screen_html(screen, rows):
    out = []
    for y in range(rows):
        line = screen.buffer[y]
        cells = []
        x = 0
        while x < screen.columns:
            cell = line[x]
            ch = cell.data
            if ch == "":
                x += 1
                continue
            fg = color(cell.fg, FOREGROUND)
            bg = color(cell.bg, None)
            if cell.reverse:
                fg, bg = (bg or BACKGROUND), fg
            width = 2 if wcwidth.wcwidth(ch[0]) == 2 else 1
            emoji = ch in EMOJI or ord(ch[0]) >= 0x1F000
            text = EMOJI.get(ch, ch)
            style = [f"width:{CELL_W * width}px"]
            if ch == "▀":
                style.append(f"background:linear-gradient({fg} 0 50%,{bg or BACKGROUND} 50% 100%)")
                text = " "
            elif ch == "▄":
                style.append(f"background:linear-gradient({bg or BACKGROUND} 0 50%,{fg} 50% 100%)")
                text = " "
            elif ch == "█":
                style.append(f"background:{fg}")
                text = " "
            else:
                if bg:
                    style.append(f"background:{bg}")
                style.append(f"color:{fg}")
                if emoji:
                    style.append(f"font:{EMOJI_FONT}")
                if cell.bold:
                    style.append("font-weight:700")
                if cell.italics:
                    style.append("font-style:italic")
            cells.append(f'<span style="{";".join(style)}">{html.escape(text)}</span>')
            x += width
        out.append('<div class="r">' + "".join(cells) + "</div>")
    return "\n".join(out)


def screenshot(page, width, height, out_png):
    page_path = os.path.join(WORK, "page.html")
    with open(page_path, "w", encoding="utf-8") as f:
        f.write(page)
    if os.path.exists(out_png):
        os.remove(out_png)
    # Chrome writes the screenshot, then sometimes never exits; stop it once the file lands.
    chrome = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                               f"--user-data-dir={os.path.join(WORK, 'chrome')}", "--default-background-color=00000000",
                               "--force-device-scale-factor=2", f"--window-size={width},{height}",
                               f"--screenshot={os.path.abspath(out_png)}", "file://" + page_path],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 45
    last = -1
    while time.time() < deadline and chrome.poll() is None:
        if os.path.exists(out_png):
            size = os.path.getsize(out_png)
            if size > 0 and size == last:
                break
            last = size
        time.sleep(0.4)
    if chrome.poll() is None:
        chrome.terminate()
        try:
            chrome.wait(5)
        except subprocess.TimeoutExpired:
            chrome.kill()
    if not os.path.exists(out_png):
        sys.exit("screenshot failed: " + out_png)


def render(screen, rows, out_png):
    width = int(screen.columns * CELL_W + PAD * 2)
    height = int(rows * ROW_H + PAD * 2)
    page = f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;background:transparent}}
.t{{background:{BACKGROUND};border-radius:10px;padding:{PAD}px;width:{width - PAD * 2}px;height:{height - PAD * 2}px;overflow:hidden}}
.r{{display:flex;height:{ROW_H}px}}
.r span{{display:block;flex:none;height:{ROW_H}px;line-height:{ROW_H}px;white-space:pre;font:{FONT};color:{FOREGROUND}}}
</style><div class="t">{screen_html(screen, rows)}</div>"""
    screenshot(page, width, height, out_png)


def inline(path, out_png, cols, max_rows=None):
    # newline="" keeps bare carriage returns, which redraw a line in place.
    data = open(path, encoding="utf-8", newline="").read().replace("\r\n", "\n").replace("\n", "\r\n")
    data = protect_emoji(data)
    rows = data.count("\n") + 2
    screen = pyte.Screen(cols, rows)
    pyte.Stream(screen).feed(data)

    def blank(y):
        return not "".join(screen.buffer[y][x].data for x in range(cols)).strip()

    used = rows
    while used > 1 and blank(used - 1):
        used -= 1
    first = 0
    while first < used - 1 and blank(first):
        first += 1
    last = used if max_rows is None else min(used, first + max_rows)
    # Drop leading blank rows (the image has its own padding) and anything past max_rows.
    trimmed = pyte.Screen(cols, last - first)
    for y in range(last - first):
        trimmed.buffer[y] = screen.buffer[y + first]
    render(trimmed, last - first, out_png)


def run_pty(out_png, cols, rows, wait, command):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(command[0], command, os.environ)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)
    decoder = __import__("codecs").getincrementaldecoder("utf-8")("replace")
    deadline = time.time() + wait
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            stream.feed(protect_emoji(decoder.decode(chunk)))
    render(screen, rows, out_png)
    try:
        os.write(fd, b"q")
        time.sleep(0.5)
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass


def gallery(out_png, items):
    figures = []
    for item in items:
        title, path = item.split("=", 1)
        figures.append(f'<figure><img src="file://{os.path.abspath(path)}"><figcaption>{html.escape(title)}</figcaption></figure>')
    columns = 2
    rows = (len(figures) + columns - 1) // columns
    width, height = 1000, rows * 196 + 24
    page = f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;background:transparent}}
.g{{background:{BACKGROUND};border-radius:10px;padding:12px;display:grid;grid-template-columns:repeat({columns},1fr);gap:4px 14px;
width:{width - 24}px;height:{height - 24}px;box-sizing:content-box}}
figure{{margin:0}} img{{width:100%;image-rendering:pixelated;border-radius:4px;display:block}}
figcaption{{font:13px Menlo,monospace;color:#A8BBC3;padding:6px 2px 8px}}
</style><div class="g">{''.join(figures)}</div>"""
    screenshot(page, width, height, out_png)


if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]

    def option(name, default):
        return args[args.index(name) + 1] if name in args else default

    if mode == "inline":
        rows = option("--max-rows", None)
        inline(args[0], args[1], int(option("--cols", "100")), int(rows) if rows else None)
    elif mode == "pty":
        run_pty(args[0], int(option("--cols", "100")), int(option("--rows", "30")), float(option("--wait", "3")),
                args[args.index("--") + 1:])
    elif mode == "gallery":
        gallery(args[0], args[1:])
    else:
        sys.exit(__doc__)
