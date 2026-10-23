#!/usr/bin/env python3
"""menu-screenshots.py - the pictures of tools/php-menu.sh for the README.

Runs sessions of the menu in an 80x25 terminal (pyte), as the FreeBSD console
shows it: bsddialog, the Terminus font (10x20) and the 16 VGA colors of vt(4).
Writes PNG screenshots and an animated GIF of each session into docs/images
(--out to change).

Usage: python3 tools/menu-screenshots.py [--dialog PATH] [--font DIR] [--out DIR]
  --dialog  bsddialog (default: the one in PATH); on Linux it can be built from
            contrib/bsddialog of freebsd-src (add slider.c to lib/GNUmakefile)
  --font    the directory with terminus-normal.otb and terminus-bold.otb
            (default /usr/share/fonts/opentype/terminus, Debian fonts-terminus-otb)
Needs python3 with pyte and Pillow. The sessions run with a uname that says
FreeBSD 15.1 amd64 and a make.conf with CPUTYPE?=x86-64-v3, so that the script
the menu shows is the one of a server; the choices go to a temporary directory.
"""
import argparse, fcntl, os, pty, select, shutil, signal, struct, sys, tempfile, termios, time

import pyte
from PIL import Image, ImageDraw, ImageFont

COLS, ROWS = 80, 25
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MENU = os.path.join(HERE, 'tools', 'php-menu.sh')

# the palette of vt(4) (the VGA one): normal, then bright
VGA = {
    'black': (0, 0, 0), 'red': (170, 0, 0), 'green': (0, 170, 0), 'brown': (170, 85, 0),
    'blue': (0, 0, 170), 'magenta': (170, 0, 170), 'cyan': (0, 170, 170), 'white': (170, 170, 170),
    'brightblack': (85, 85, 85), 'brightred': (255, 85, 85), 'brightgreen': (85, 255, 85),
    'brightbrown': (255, 255, 85), 'brightblue': (85, 85, 255), 'brightmagenta': (255, 85, 255),
    'brightcyan': (85, 255, 255), 'brightwhite': (255, 255, 255),
}
ALIASES = {'yellow': 'brown', 'brightyellow': 'brightbrown', 'bfightmagenta': 'brightmagenta'}

# the keys as xterm sends them in keypad mode (bsddialog turns it on)
KEYS = {'enter': b'\r', 'down': b'\x1bOB', 'up': b'\x1bOA', 'pgdn': b'\x1b[6~', 'pgup': b'\x1b[5~',
        'space': b' ', 'tab': b'\t', 'esc': b'\x1b', 'home': b'\x1bOH', 'end': b'\x1bOF',
        'right': b'\x1bOC', 'left': b'\x1bOD'}


def color(name, default, bright=False):
    name = ALIASES.get(name, name)
    if name == 'default':
        name = default
    if len(name) == 6 and all(c in '0123456789abcdefABCDEF' for c in name):
        return tuple(int(name[i:i + 2], 16) for i in (0, 2, 4))
    if bright and not name.startswith('bright'):
        name = 'bright' + name
    return VGA.get(name, VGA[default])


class Term:
    """The menu in a pseudo terminal of 80x25, read into a pyte screen."""

    def __init__(self, argv, env, cwd):
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
            os.chdir(cwd)
            os.execvpe(argv[0], argv, env)
        self.pid, self.fd = pid, fd

    def settle(self, quiet=0.35, limit=8.0):
        """read until the program is quiet"""
        end = time.time() + limit
        last = time.time()
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                self.stream.feed(data)
                last = time.time()
            elif time.time() - last >= quiet:
                return True
        return True

    def key(self, k):
        os.write(self.fd, KEYS.get(k, k.encode() if isinstance(k, str) else k))

    def cells(self):
        rows = []
        for y in range(ROWS):
            line = self.screen.buffer[y]
            rows.append([line[x] for x in range(COLS)])
        return rows

    def close(self):
        try:
            os.kill(self.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


class Painter:
    def __init__(self, fontdir, size=20):
        self.normal = ImageFont.truetype(os.path.join(fontdir, 'terminus-normal.otb'), size)
        self.bold = ImageFont.truetype(os.path.join(fontdir, 'terminus-bold.otb'), size)
        x0, y0, x1, y1 = self.normal.getbbox('M')
        self.cw, self.ch = int(self.normal.getlength('M')), size
        self.pal = Image.new('P', (1, 1))
        flat = []
        for name in ('black', 'red', 'green', 'brown', 'blue', 'magenta', 'cyan', 'white',
                     'brightblack', 'brightred', 'brightgreen', 'brightbrown', 'brightblue',
                     'brightmagenta', 'brightcyan', 'brightwhite'):
            flat += VGA[name]
        self.pal.putpalette(flat + [0] * (768 - len(flat)))

    def paint(self, rows):
        img = Image.new('RGB', (COLS * self.cw, ROWS * self.ch), VGA['black'])
        d = ImageDraw.Draw(img)
        for y, line in enumerate(rows):
            for x, c in enumerate(line):
                fg = color(c.fg, 'white', bright=c.bold)
                bg = color(c.bg, 'black')
                if c.reverse:
                    fg, bg = bg, fg
                px, py = x * self.cw, y * self.ch
                d.rectangle([px, py, px + self.cw - 1, py + self.ch - 1], fill=bg)
                if c.data.strip():
                    d.text((px, py), c.data, font=self.bold if c.bold else self.normal, fill=fg)
        return img

    def indexed(self, img):
        return img.quantize(palette=self.pal, dither=Image.Dither.NONE)


def session(name, argv, steps, painter, out, env, cwd):
    """steps: (key or None, seconds the frame stays in the GIF, PNG name or None)"""
    t = Term(argv, env, cwd)
    frames, times = [], []
    try:
        for key, hold, shot in steps:
            if key:
                t.key(key)
            t.settle()
            img = painter.paint(t.cells())
            frames.append(painter.indexed(img))
            times.append(int(hold * 1000))
            if shot:
                painter.indexed(img).save(os.path.join(out, shot + '.png'), optimize=True)
                print('wrote %s.png' % shot)
    finally:
        t.close()
    gif = os.path.join(out, name + '.gif')
    frames[0].save(gif, save_all=True, append_images=frames[1:], duration=times, loop=0, optimize=False,
                   disposal=1)
    print('wrote %s.gif (%d frames)' % (name, len(frames)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--dialog', default=shutil.which('bsddialog'))
    ap.add_argument('--font', default='/usr/share/fonts/opentype/terminus')
    ap.add_argument('--out', default=os.path.join(HERE, 'docs', 'images'))
    args = ap.parse_args()
    if not args.dialog:
        sys.exit('no bsddialog (--dialog PATH)')
    os.makedirs(args.out, exist_ok=True)
    painter = Painter(args.font)

    work = tempfile.mkdtemp(prefix='menu-shots-')
    fake = os.path.join(work, 'bin')
    os.makedirs(fake)
    with open(os.path.join(fake, 'uname'), 'w') as f:
        f.write('#!/bin/sh\ncase "$1" in -p|-m) echo amd64 ;; -r) echo 15.1-RELEASE ;; *) echo FreeBSD ;; esac\n')
    os.chmod(os.path.join(fake, 'uname'), 0o755)
    mkconf = os.path.join(work, 'make.conf')
    with open(mkconf, 'w') as f:
        f.write('CPUTYPE?=x86-64-v3\n')
    env = {
        'PATH': fake + ':' + os.environ.get('PATH', '/usr/bin:/bin'), 'TERM': 'xterm', 'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8', 'HOME': work, 'DIALOG': args.dialog, 'MAKE_CONF': mkconf,
        'PHP_MENU_DB': '/var/db/php-menu', 'OUT': './config.menu.sh', 'INSTALLED': './config.installed.sh',
        'LINES': str(ROWS), 'COLUMNS': str(COLS), 'TZ': 'Europe/Prague',
    }
    menu = ['sh', MENU, '8.4']

    def fresh():
        shutil.rmtree('/var/db/php-menu', ignore_errors=True)
        for f in ('config.menu.sh', 'config.installed.sh'):
            try:
                os.unlink(os.path.join(work, f))
            except FileNotFoundError:
                pass

    # Roundcube: the template, the screens, the script
    fresh()
    session('menu-roundcube', menu, [
        (None, 2.5, 'menu-start'),
        ('down', 2.5, 'menu-start-roundcube'),
        ('enter', 2.5, 'menu-roundcube-core'),
        ('enter', 3.0, 'menu-roundcube-ext'),
        ('pgdn', 2.5, None),
        ('pgdn', 2.5, None),
        ('pgdn', 2.5, 'menu-roundcube-ext2'),
        ('pgdn', 2.5, None),
        ('enter', 2.0, None),  # curl: which libcurl
        ('enter', 2.0, None),  # GD options
        ('enter', 2.0, None),  # mbstring options
        ('enter', 2.0, None),  # OpenSSL options
        ('enter', 2.5, 'menu-main'),
        ('end', 0.8, None),
        ('up', 2.0, None),
        ('enter', 3.5, 'menu-roundcube-script'),
        ('pgdn', 3.0, None),
        ('enter', 1.5, None),
        ('home', 1.5, None),
        ('enter', 3.0, None),
    ], painter, args.out, env, work)

    # bare PHP: the defaults (CLI and OPcache only)
    fresh()
    session('menu-bare', menu, [
        (None, 2.0, None),
        ('enter', 2.5, 'menu-bare-core'),
        ('enter', 3.0, 'menu-bare-ext'),
        ('enter', 2.5, None),
        ('end', 0.8, None),
        ('up', 2.0, None),
        ('enter', 3.5, 'menu-bare-script'),
        ('enter', 1.5, None),
        ('home', 1.5, None),
        ('enter', 3.0, None),
    ], painter, args.out, env, work)
    fresh()
    shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    main()
