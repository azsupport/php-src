# Gearman PHP Extension

The Gearman PHP Extension provides a wrapper to libgearman. This gives the user the ability to write fully featured Gearman clients and workers in PHP, allowing them to quickly develop distributed applications.

For more information about Gearman, see: http://www.gearman.org/

## Requirements

| Extension version | libgearman version | PHP version |
|---|---|---|
| 0.8.* | >= 0.14 | |
| 1.0.* | >= 0.21 | |
| 1.1.* | >= 1.1.0 | |
| 2.0.* | >= 1.1.8 | 7.0 - 7.4 |
| 2.1.* | >= 1.1.18 | 7.2 - 8.6 |

The extension requires the Gearman C server and library package to be installed. You can download the latest from:

https://github.com/gearman/gearmand/releases

## Installation

Make sure you have the PHP development packages installed (if you have the `phpize` command, you're all set). You'll also probably want the PHP command line interface installed as well (usually named `php-cli`).

```bash
phpize
./configure
make
make install
```

Then add the following line to your `php.ini`:

```ini
extension="gearman.so"
```

Verify the module is loaded:

```bash
php --info | grep gearman
```

## Quick Start

1. Start the gearmand server in a separate terminal:

   ```bash
   gearmand
   ```

2. In another terminal, start a worker:

   ```bash
   php examples/reverse_worker.php
   ```

3. In another terminal, run the client:

   ```bash
   php examples/reverse_client.php
   ```

You should see output from both scripts about the status and then a final result.

## Links

- PECL package: https://pecl.php.net/package/gearman
- Gearman: http://www.gearman.org/
- gearmand: https://github.com/gearman/gearmand
