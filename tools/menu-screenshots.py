#!/usr/bin/env python3
"""menu-screenshots.py - the pictures of tools/az-menu.sh for the README.

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
MENU = os.path.join(HERE, 'tools', 'az-menu.sh')

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


# pkg for the session of the packages: the catalog of the repository az as a server
# reads it (the versions of a build of az.yml and az-php.yml of 05.11.2026)
FAKE_PKG = r"""#!/bin/sh
cat_az() {
    printf '%s\t%s\t%s\n' \
        azsupport 20261105_26110500 'Static libraries of /usr/local/azsupport, for builds of PHP and the programs' \
        curl 8.23.0_26110500 'Command line tool and library for transferring data with URLs (static, of azsupport/php-src)' \
        ffmpeg 9.0.2_26110500,1 'FFmpeg for the video sites, static (ffmpeg, ffprobe)' \
        ImageMagick6 6.9.13.59_26110500,1 'ImageMagick 6 for the video sites, static (convert6, identify6, ...)' \
        ImageMagick7 7.1.2.34_26110500 'ImageMagick 7 for the video sites, static (magick), and its libraries for imagick' \
        php56 5.6.40_26110500 'PHP 5.6 of azsupport/php-src (php56, php-fpm56, libphp56.so), static' \
        php74 7.4.33_26110500 'PHP 7.4 of azsupport/php-src (php74, php-fpm74, libphp74.so), static' \
        php81 8.1.34_26110500 'PHP 8.1 of azsupport/php-src (php81, php-fpm81, libphp81.so), static' \
        php82 8.2.30_26110500 'PHP 8.2 of azsupport/php-src (php82, php-fpm82, libphp82.so), static' \
        php83 8.3.29_26110500 'PHP 8.3 of azsupport/php-src (php83, php-fpm83, libphp83.so), static' \
        php84 8.4.27_26110500 'PHP 8.4 of azsupport/php-src (php84, php-fpm84, libphp84.so), static'
}
case "$1" in
    update) exit 0 ;;
    query) exit 1 ;;
    rquery)
        shift
        [ "$1" = -r ] && shift 2
        fmt="$1"; n="${2:-}"
        case "$fmt" in
            '%n-%v: %c') cat_az | awk -F '\t' -v n="$n" '$1 == n { print $1 "-" $2 ": " $3 }' ;;
            '%e')
                v="${n#php}"; b="${v%?}.${v#?}"
                echo "PHP $b of https://github.com/azsupport/php-src, built by az-menu.sh: bin/php$v, sbin/php-fpm$v with the rc.d script php_fpm$v, etc/php$v, the Apache module libphp$v.so, in the place of the package of the port; linked with the static libraries of /usr/local/azsupport." ;;
            '%At%Av'|'%At	%Av')
                v="${n#php}"
                printf 'configure\t%s\n' "--prefix=/usr/local --program-suffix=$v --sysconfdir=/usr/local/etc/php$v --libdir=/usr/local/lib/php$v --includedir=/usr/local/include/php$v --datadir=/usr/local/share/php$v --mandir=/usr/local/share/man --with-layout=GNU --localstatedir=/var --disable-all --with-libxml --enable-embed --enable-fpm --with-fpm-user=www --with-fpm-group=www --with-curl=/usr/local/azsupport --enable-dom --enable-filter --enable-mbstring --enable-opcache --enable-session --enable-gd --enable-mysqlnd --with-mysqli=mysqlnd --enable-pdo --with-pdo-mysql=mysqlnd --with-openssl --with-zip --enable-redis --enable-igbinary --enable-redis-igbinary --enable-redis-zstd --enable-memcached --with-libmemcached-dir=/usr/local/azsupport --disable-memcached-sasl --with-imagick=/usr/local/azsupport"
                printf 'cflags\t%s\n' '-O3 -pipe -march=x86-64-v3 -fstack-protector-strong -fno-strict-aliasing'
                printf 'built_by\t%s\n' 'az-menu.sh r16 (b28c3f4391, 05.11.2026 00:34 CET)' ;;
            '%dn-%dv') printf '%s\n' azsupport-20261105_26110500 curl-8.23.0_26110500 ImageMagick7-7.1.2.34_26110500 ;;
            *) cat_az ;;
        esac ;;
    *) exit 1 ;;
esac
"""


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

    def settle(self, quiet=1.2, limit=12.0):
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
        """the menu and the dialog it waits for (its process group, the session of the pty)"""
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self.pid, sig)
            except ProcessLookupError:
                return
            end = time.time() + 2
            while time.time() < end:
                try:
                    if os.waitpid(self.pid, os.WNOHANG)[0]:
                        return
                except ChildProcessError:
                    return
                time.sleep(0.05)


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
    # pkg as a server with the repository az sees it: the catalog of az (rquery), the
    # update, nothing of it installed yet (query)
    with open(os.path.join(fake, 'pkg'), 'w') as f:
        f.write(FAKE_PKG)
    os.chmod(os.path.join(fake, 'pkg'), 0o755)
    azconf = os.path.join(work, 'az.conf')
    with open(azconf, 'w') as f:
        f.write('az: { url: "https://github.com/azsupport/php-src/releases/download/az-fbsd15-amd64-v3", '
                'signature_type: "none", priority: 100, enabled: yes }\n')
    mkconf = os.path.join(work, 'make.conf')
    with open(mkconf, 'w') as f:
        f.write('CPUTYPE?=x86-64-v3\n')
    env = {
        'PATH': fake + ':' + os.environ.get('PATH', '/usr/bin:/bin'), 'TERM': 'xterm', 'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8', 'HOME': work, 'DIALOG': args.dialog, 'MAKE_CONF': mkconf,
        'AZ_MENU_DB': '/var/db/az-menu', 'OUT': './config.menu.sh', 'INSTALLED': './config.installed.sh',
        'LINES': str(ROWS), 'COLUMNS': str(COLS), 'TZ': 'Europe/Prague',
        'AZ_REPO_CONF': azconf, 'AZ_MENU_WORK': os.path.join(work, 'az-menu'),
    }
    menu = ['sh', MENU, '8.4']

    def fresh():
        shutil.rmtree('/var/db/az-menu', ignore_errors=True)
        for f in ('config.menu.sh', 'config.installed.sh'):
            try:
                os.unlink(os.path.join(work, f))
            except FileNotFoundError:
                pass

    # Roundcube: the template, the screens (PDO with the button Options), the script
    fresh()
    session('menu-roundcube', menu, [
        (None, 2.5, 'menu-start'),
        ('down', 2.5, 'menu-start-roundcube'),
        ('enter', 2.5, 'menu-roundcube-core'),
        ('enter', 3.0, 'menu-roundcube-ext'),
        ('P', 0.6, None),      # the items with P: PCNTL,
        ('P', 2.5, 'menu-roundcube-ext2'),  # PDO
        ('right', 0.8, None),  # the buttons: Cancel,
        ('right', 2.0, 'menu-roundcube-options'),  # Options
        ('enter', 3.0, 'menu-roundcube-pdo'),  # the drivers of PDO
        ('enter', 2.0, None),  # back in the list, on PDO
        ('pgdn', 2.0, None),
        ('pgdn', 2.0, None),
        ('enter', 2.0, None),  # curl: which libcurl
        ('enter', 2.0, None),  # GD options
        ('enter', 2.0, None),  # mbstring options
        ('enter', 2.0, None),  # php-memcached options (memcached is on by default)
        ('enter', 2.0, None),  # OpenSSL options (PDO was shown already)
        ('enter', 2.0, None),  # phpredis options (redis is on by default)
        ('enter', 2.5, 'menu-main'),
        ('end', 0.8, None),
        ('up', 2.0, None),
        ('enter', 3.5, 'menu-roundcube-script'),
        ('pgdn', 3.0, None),
        ('enter', 1.5, None),
        ('home', 1.5, None),
        ('enter', 3.0, None),
    ], painter, args.out, env, work)

    # the packages of az (sh az-menu.sh outside a PHP source tree): ffmpeg,
    # ImageMagick 7 and the ready php74 ticked (the first page of the list: the
    # terminal of pyte follows the scrolling of a list badly), then Options on php74
    fresh()
    session('menu-packages', ['sh', MENU], [
        (None, 2.5, None),
        ('down', 0.5, None),
        ('down', 0.5, None),
        (' ', 0.8, None),      # ffmpeg
        ('down', 0.5, None),
        ('down', 0.5, None),
        (' ', 0.8, None),      # ImageMagick7
        ('down', 0.5, None),   # php56
        ('down', 0.5, None),   # php56.build
        ('down', 0.5, None),   # php74, the ready one
        (' ', 3.0, 'menu-packages'),
        ('right', 0.8, None),  # the buttons: Cancel,
        ('right', 2.0, None),  # Options
        ('enter', 4.0, 'menu-packages-options'),  # what the ready php74 is built with
        ('enter', 1.5, None),
        ('esc', 1.0, None),
    ], painter, args.out, env, work)

    # the defaults: CLI and OPcache; redis (igbinary, zstd) and memcached
    fresh()
    session('menu-bare', menu, [
        (None, 2.0, None),
        ('enter', 2.5, 'menu-bare-core'),
        ('enter', 3.0, 'menu-bare-ext'),
        ('enter', 2.0, 'menu-bare-memcached'),  # php-memcached options
        ('enter', 2.5, 'menu-bare-redis'),  # phpredis options
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
