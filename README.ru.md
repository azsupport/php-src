# PHP для FreeBSD: ветки исходников с исправлениями безопасности

**English: [README.md](README.md)**. Это перевод; если они разойдутся, верен английский
текст.

**Что это.** Готовые к сборке исходники PHP для серверов FreeBSD (amd64), где PHP
собирают вручную, а не ставят из портов или пакетов: по ветке `freebsd/<версия>` на
каждую версию PHP. Каждая ветка идёт за своим источником исправлений безопасности и
добавляет небольшой отобранный набор патчей портов FreeBSD и исправления для
современной FreeBSD.

| Зачем | Что это даёт |
|---|---|
| Исправления безопасности | для каждой версии PHP, которая ещё работает на сервере, — в тот же день и без ожидания портов: официальные релизы php-src для 8.2–8.4, бэкпорты Remi Collet для 5.6, 7.4 и 8.1, у которых закончилась поддержка, и наши переносы для 5.6 |
| Тарболы релизов | каждое обновление, с уже сгенерированными `configure` и парсерами bison/re2c: на сервере нужны только компилятор C и `make` — как с тарболами с php.net |
| Один PHP, в который встроено всё | расширения, [встроенные расширения PECL](#встроенные-расширения-pecl), [curl](#встроенный-curl) с его библиотеками, [PCRE](#встроенная-pcre), а при желании и [OPcache](#встроенный-opcache-и-запрет-загрузки-расширений), без загрузки расширений во время работы |
| Несколько версий рядом | PHP 5.6, 7.4, 8.1, 8.2, 8.3 и 8.4, каждая в своём `/usr/local/phpXY` и со своим файлом модуля Apache (`libphp84.so`, …, `libphp56.so`) |
| Скрипты | [`config-check.sh`](tools/config-check.sh) записывает опции configure того PHP, что стоит на сервере; [`php-menu.sh`](tools/php-menu.sh) выбирает, что войдёт в сборку, диалогами — как `make config` портов |
| Проверки | [тестовая сборка](#тестовая-сборка-на-freebsd) в виртуальной машине FreeBSD; ежедневная [проверка апстрима](#проверка-апстрима): встроенный код, порты FreeBSD и конец поддержки PHP |

Не связано с PHP Group, Remi Collet и проектом FreeBSD.
Предоставляется как есть, без гарантий, — [aZsupport.com](https://azsupport.com).

## Содержание

- [Ветки](#ветки)
  - [Патчи портов FreeBSD: что применено и что нет](#патчи-портов-freebsd-что-применено-и-что-нет)
- [Сборка на FreeBSD из тарбола релиза](#сборка-на-freebsd-из-тарбола-релиза)
  (файл модуля Apache, `LoadModule`)
  - [PHP 8.4](#php-84), [8.3](#php-83), [8.2](#php-82), [8.1](#php-81), [7.4](#php-74), [5.6](#php-56)
  - [Что войдёт в сборку: php-menu.sh](#что-войдёт-в-сборку-php-menush)
  - [Встроенный OPcache и запрет загрузки расширений](#встроенный-opcache-и-запрет-загрузки-расширений)
  - [Тестовая сборка на FreeBSD](#тестовая-сборка-на-freebsd)
  - [Встроенные расширения PECL](#встроенные-расширения-pecl)
  - [OpenSSL](#openssl)
  - [Встроенный curl](#встроенный-curl)
  - [Встроенная PCRE](#встроенная-pcre)
- [Как приходят обновления](#как-приходят-обновления)
  - [Проверка апстрима](#проверка-апстрима)
  - [Патчи совместимости сборки](#патчи-совместимости-сборки)
  - [Опции сборки](#опции-сборки)
  - [Временные бэкпорты](#временные-бэкпорты)
  - [Токен](#токен)
- [Авторы и лицензии](#авторы-и-лицензии)

## Ветки

| Ветка | PHP | Источник | Поддержка источника | Тарбол |
|---|---|---|---|---|
| [`freebsd/8.4`](https://github.com/azsupport/php-src/tree/freebsd/8.4) | 8.4.x | новейший официальный релиз (теги `php-8.4.N` в [php/php-src](https://github.com/php/php-src)) | исправления безопасности до 31.12.2028 | [latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.4-latest) |
| [`freebsd/8.3`](https://github.com/azsupport/php-src/tree/freebsd/8.3) | 8.3.x | новейший официальный релиз (`php-8.3.N`) | исправления безопасности до 31.12.2027 | [latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.3-latest) |
| [`freebsd/8.2`](https://github.com/azsupport/php-src/tree/freebsd/8.2) | 8.2.x | новейший официальный релиз (`php-8.2.N`) | исправления безопасности до 31.12.2026 | [latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.2-latest) |
| [`freebsd/8.1`](https://github.com/azsupport/php-src/tree/freebsd/8.1) | 8.1.34 + бэкпорты | Remi Collet, [`PHP-8.1-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-8.1-security-backports) | поддержка закончилась 31.12.2025 | [latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.1-latest) |
| [`freebsd/7.4`](https://github.com/azsupport/php-src/tree/freebsd/7.4) | 7.4.33 + бэкпорты | Remi Collet, [`PHP-7.4-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-7.4-security-backports) | поддержка закончилась 28.11.2022 | [latest](https://github.com/azsupport/php-src/releases/tag/freebsd-7.4-latest) |
| [`freebsd/5.6`](https://github.com/azsupport/php-src/tree/freebsd/5.6) | 5.6.40 + бэкпорты | Remi Collet, [`PHP-5.6-security-backports-openssl11`](https://github.com/remicollet/php-src-security/tree/PHP-5.6-security-backports-openssl11) (поддержка OpenSSL 1.1; OpenSSL 3 — патчем совместимости здесь) | поддержка закончилась 31.12.2018 | [latest](https://github.com/azsupport/php-src/releases/tag/freebsd-5.6-latest) |

Ссылки на тарболы ведут на релизы `freebsd-<версия>-latest`.

**Релиз безопасности PHP от 21.10.2026** (CVE-2026-109618, CVE-2026-109619,
[анонс](https://www.php.net/archive/2026.php)):

| Ветка | Исправление | Замечание |
|---|---|---|
| `freebsd/8.2`, `freebsd/8.3`, `freebsd/8.4` | официальные исправленные релизы 8.2.35, 8.3.36 и 8.4.27 | полное исправление |
| `freebsd/7.4`, `freebsd/8.1` | коммит «Avoid state corruption via bailout» (Arnaud Le Blanc) из веток Remi Collet — минимальный бэкпорт в исходниках, который команда безопасности PHP дала для 7.4, 8.0 и 8.1 | меньше полного исправления 8.2+ (например, session upload progress в нём выключен в коде): меры в конфигурации из анонса оставьте |
| `freebsd/5.6` | перенос того же коммита на движок PHP 5 (ниже) | без проверки в апстриме: меры в конфигурации из анонса оставьте |

Перенос для 5.6:

| В PHP 5.6 | С переносом |
|---|---|
| Фатальные ошибки аллокатора | завершают воркер через `_exit()`, а не `longjmp()` |
| Состояние, которое ошибка оставляет следующему запросу | сбрасывается |
| Разбор multipart | хранит только те заголовки, которые использует |
| Session upload progress | выключен в коде |
| Исчерпание памяти | воркер сразу завершается, как и с официальным исправлением: shutdown-функции не выполняются, буферизованный вывод теряется, ошибка уходит в stderr (лог ошибок php-fpm или Apache) |

Перенос из двух частей:

| Часть | Патч |
|---|---|
| 1 | [`backport-php2shell-1.patch`](freebsd/patches/5.6/backport-php2shell-1.patch): код, предложенный в ветку Remi Collet в [pull request #32](https://github.com/remicollet/php-src-security/pull/32), — тот же код, что и наш перенос, как есть, чтобы синк пропустил его, когда он появится в его ветке |
| 2 | [`backport-php2shell-2-extra.patch`](freebsd/patches/5.6/backport-php2shell-2-extra.patch): то, что есть в официальном исправлении и в других известных нам переносах для 5.6 (php5.6 5.6.40-104 Ondřej Surý, патч 0261, и перенос [vperetti](https://github.com/vperetti/php-cve-2026-109618-109619-backports)), но нет в том pull request: самые маленькие массивы для `$_GET`, `$_POST`, `$_COOKIE`, более ранний сброс исключения после освобождения объектов и сброс header callback |

**Исправления июля–октября 2026 в 5.6.** Ветка 5.6 у Remi Collet не обновлялась с
02.07.2026, а его ветка 7.4 получила исправления релизов PHP с июля по октябрь 2026. В
`freebsd/5.6` — наши переносы этих исправлений, по патчу на область в
[`freebsd/patches/5.6/`](freebsd/patches/5.6) (`backport-*.patch`, коммиты апстрима —
в строке `Origin:` каждого), с их тестами:

| Область (патч) | Что исправляет |
|---|---|
| [GD: GIF](freebsd/patches/5.6/backport-gd-gif-lzw.patch) | CVE-2026-9672: декодер GIF LZW встроенной libgd |
| [pgsql](freebsd/patches/5.6/backport-pgsql-quotes.patch) | GHSA-7qpv-r5mr-78m4 (CVE-2026-17543): SQL-инъекция через `pg_insert()` и родственные функции (кавычки `E'...'`) |
| [phar: tar](freebsd/patches/5.6/backport-phar-tar.patch) | GHSA-vc5h-9ppw-p5f3 (CVE-2026-7260): циклы символических ссылок в tar-архивах; GHSA-j3wh-g957-2m85: подмена записей tar |
| [DatePeriod](freebsd/patches/5.6/backport-date-period.patch) | повторный `DatePeriod::__construct()` (утечка), аргументы, не инициализированные своим конструктором |
| [фильтры convert.*](freebsd/patches/5.6/backport-convert-filters.patch) | GHSA-88hq-2827-7pg6: чтение за границей кучи в фильтрах потоков convert.* |
| [FPM](freebsd/patches/5.6/backport-fpm-allowed-clients.patch) | GHSA-62xp-839h-2637: `listen.allowed_clients` сравнивал 96 из 128 бит адресов IPv6 |
| [OpenSSL](freebsd/patches/5.6/backport-openssl-peer-name.patch) | GHSA-vvx9-73fr-5jjx: нет перехода на CN, если в сертификате есть имя DNS, URI или SRV; GHSA-xr7j-rvgx-xq5p: чтение за границей при сравнении по маске |
| [редиректы HTTP](freebsd/patches/5.6/backport-http-redirects.patch) | GHSA-fpwc-w8rq-cr92: учётные данные сохранялись при редиректе на другой origin; GH-11274: 307/308 сохраняют POST |
| [SOAP](freebsd/patches/5.6/backport-soap.patch) | GHSA-rgrp-mwpx-f6rm: неограниченная рекурсия в ext/soap; GHSA-cj93-vc83-wgqv: размеры чанков в HTTP-клиенте SOAP |
| [filter](freebsd/patches/5.6/backport-filter-encoded.patch) | GHSA-ch8v-r6jh-4vvr: `FILTER_SANITIZE_ENCODED` оставлял 0xFF как есть |
| [mysqlnd](freebsd/patches/5.6/backport-mysqlnd-overread.patch) | GHSA-h35g-vwh6-m678 (CVE-2024-8929) и частичное исправление GHSA-r6x9-5r99-36j7: враждебный сервер MySQL выуживал байты кучи через чтение пакетов за границей в mysqlnd |

Не перенесено:

| Исправление | Почему нет |
|---|---|
| GHSA-9f67-6fw4-hpfp | только Windows |
| Исправления для пустого и односимвольного `Location` | 5.6 не затронута: по пустому она не переходит и читает его в буфер фиксированного размера |

Исправлению mysqlnd понадобилось и усиление 2024 года (GHSA-h35g-vwh6-m678,
CVE-2024-8929), которого нет ни в 5.6 у Remi Collet, ни у Ondřej Surý, поэтому
`backport-mysqlnd-overread.patch` переносит из PHP 7.4 и коммит 2024 года, и частичное
исправление 2026 года, с тестами протокола на поддельном сервере, адаптированными для
5.6. Из этого alt-php56 5.6.40-135 от TuxCare (errata от 10.08.2026, например
[CLSA-2026:1786360064](https://errata.tuxcare.com/els_alt_php/el8/CLSA-2026-1786360064.html))
исправляет CVE-2026-9672, CVE-2026-17543 и CVE-2026-7260.

**Коммиты.** Каждая ветка — это апстрим плюс такие коммиты, в таком порядке:

| # | Коммит | Что делает |
|---|---|---|
| 1 | **Apply curated FreeBSD ports patches** | те патчи `lang/phpXY` из [коллекции портов FreeBSD](https://github.com/freebsd/freebsd-ports), которые здесь важны ([ниже](#патчи-портов-freebsd-что-применено-и-что-нет)), — файлами с описанием и строкой происхождения в [`freebsd/patches/`](freebsd/patches). Тот же коммит удаляет каталог `.github/` апстрима, чтобы собственный CI php-src не запускался в этом форке (в тарболах релизов его и так нет) |
| 2 | **Apply build compatibility patches** | во всех ветках — имя файла модуля Apache (`libphpXY.so`), в 5.6 и 7.4 ещё и изменения, с которыми старая ветка собирается и работает на современной FreeBSD: [Патчи совместимости сборки](#патчи-совместимости-сборки) |
| 3 | **Backport security fixes** | только пока такие есть (сейчас 5.6): [Временные бэкпорты](#временные-бэкпорты) |
| 4 | **Bundle PECL extensions** | redis, memcached, memcache, igbinary, imagick, gmagick, swoole, OpenSwoole, excimer и mcrypt в `ext/`; собираются, только если включены: [Встроенные расширения PECL](#встроенные-расширения-pecl) |
| 5 | **Bundle curl** | curl в `ext/curl/libcurl` и его библиотеки в `ext/curl/deps`, встраиваются в PHP с `--with-curl=bundled`: [Встроенный curl](#встроенный-curl) |
| 6 | **Bundle PCRE** | новейшая PCRE2 (5.6: PCRE 8.45) вместо той, что встроена в апстриме: [Встроенная PCRE](#встроенная-pcre) |
| 7 | **Add the build options of this fork** | встроенный OPcache и запрет загрузки расширений, выключены, пока не заданы в configure: [Встроенный OPcache и запрет загрузки расширений](#встроенный-opcache-и-запрет-загрузки-расширений) |
| 8 | **Show the build id in the `php -v` banner** | дата сборки и коммит апстрима в `php -v` (ниже) |
| 9 | **README: describe the freebsd/X.Y branch** | блок заметок поверх исходного README с точным коммитом апстрима (строка `Upstream-Commit:`) и списками применённых и не применённых патчей портов; в заметках релиза — те же списки |

Id сборки:

| Где | Что показывает |
|---|---|
| `php -v` | `PHP 7.4.33 (cli) (built: ...) (fork: 20261021-fbsd-802c2107)`: новый макрос `PHP_FORK_BUILD` дописывается в баннер склейкой строковых литералов C |
| `PHP_VERSION` | остаётся чистой версией апстрима `7.4.33`, поэтому `phpversion()`, `version_compare()` и разборщики `PHP x.y.z` не сбиваются |
| SAPI | в 8.2+ баннер общий для всех SAPI (`php -v`, `php-fpm -v`); в 5.6/7.4 это баннер CLI |
| `phpinfo()` | показывает чистую версию, без id сборки |

**Зеркала.**

| Что зеркалируется | Как |
|---|---|
| Ветки Remi Collet | под исходными именами (`PHP-5.6-security-backports-openssl11`, `PHP-7.4-security-backports`, `PHP-8.1-security-backports`), поддерживаются в актуальном виде workflow |
| Теги релизов | `php-5.6.40`, `php-7.4.33`, `php-8.1.34`, `php-8.2.34`, `php-8.3.35` и `php-8.4.26`, один раз 21.10.2026. Более новые официальные теги не зеркалируются, потому что их push запустил бы здесь CI php-src, который срабатывает на теги, но их полная история входит в ветки `freebsd/8.x` |

### Патчи портов FreeBSD: что применено и что нет

Применяются только патчи, которые важны для монолитной сборки на FreeBSD:

| Файл порта | PHP | Что делает |
|---|---|---|
| `sapi/fpm/config.m4` | 5.6–8.3 | FPM узнаёт очередь listen через `SO_LISTENQLEN`; в `struct tcp_info` FreeBSD нет полей Linux |
| `sapi/apache2handler/config.m4` | все | `make install` ставит модуль Apache, не меняя `httpd.conf` (без `apxs -a`), что важно на серверах с несколькими сборками PHP (а наш `compat-apache-module-name.patch` называет файл по версии, ниже) |
| `build/Makefile.global` (`Makefile.global` в 5.6) | все | `make test` не останавливается, если загруженный `php.ini` пуст или в каталоге сканирования нет файлов `.ini` (BSD make выполняет рецепт через `sh -e`) |
| `sapi/fpm/www.conf.in` | 7.4+ | поясняет, что адреса IPv4-mapped на FreeBSD по умолчанию выключены |
| `TSRM/TSRM.c` | 8.1+ | без ассемблера TLS для Linux aarch64 на FreeBSD (на amd64 ни на что не влияет) |
| `php.ini-production`, `php.ini-development` | 8.2+ | в обоих шаблонах `session.upload_progress.enabled = Off`, как в порту с 23.10.2026: временная мера против CVE-2026-115560 до следующего релиза PHP. `make install` шаблоны не ставит, так что `php.ini` на сервере остаются как есть, а без `php.ini` действует значение, вкомпилированное по умолчанию (On) |
| `ext/pcre/php_pcre.h` | 8.4 | с `--with-external-pcre` системный `<pcre2.h>` подключается так же, как в порту; со встроенной PCRE ни на что не влияет |
| `Zend/zend.h` | 5.6 | без `alloca()` в потокобезопасных (ZTS) сборках на FreeBSD; на сборки без ZTS не влияет |
| `Zend/zend_compile.h`, `Zend/zend_execute.h`, `Zend/zend_list.[ch]` | 5.6 | макросы с арифметикой указателей превращены во встраиваемые функции (без неопределённого поведения, которое новый clang компилирует неверно) и 64-битные id списка ресурсов |

Не применены, по видам:

| Файлы порта | Почему нет |
|---|---|
| `configure.ac` / `configure.in`, `acinclude.m4`, `ext/mysqli/*`, `ext/zlib/config0.m4`, `ext/standard/image.c`, `php_session.h` | раздельная упаковка портов, где каждое расширение — отдельный пакет; `configure.ac` / `configure.in` подключают `ext/php_config.h`, который создаёт только Makefile портов, так что ручная сборка упала бы, и задают `include_path` PEAR портов |
| `sljit` и `xxhash` для PowerPC | другие архитектуры процессоров |
| `ext/openssl/openssl.c` (8.4) | для LibreSSL |
| `sapi/apache2filter/config.m4` (5.6) | экспериментальный SAPI apache2filter не используется; apache2handler получает то же изменение |
| `TSRM/threads.m4` (5.6) | правка портов в проверке pthreads в configure; на FreeBSD проверка апстрима и так проходит |
| `php-fpm.in`, `php_fpm.in` | скрипты rc.d портов |

Точный список для каждой версии, по строке на файл порта с причиной, — в
`freebsd/patches/<версия>/SKIPPED`, в README ветки и в заметках релиза.

## Сборка на FreeBSD из тарбола релиза

| Релиз | Что это |
|---|---|
| `freebsd-<версия>-latest` | всегда новейший тарбол ветки |
| `freebsd-<версия>-<ГГГГММДД>-<коммит>` | датированные релизы, сохраняются |

Тарбол распаковывается в каталог с датой и коммитом апстрима, например
`php-7.4.33-fbsd-20261021-802c2107/`, и PHP из него показывает то же в баннере `php -v`:
`PHP 7.4.33 (cli) (built: ...) (fork: 20261021-fbsd-802c2107)`. Сама версия остаётся
`7.4.33`. У тарболов, выпущенных до появления этого (21.10.2026), `(fork: ...)` в
баннере нет.

Каждый блок ниже пересобирает одну версию с опциями PHP, установленного в
`/usr/local/phpXY`: скачивает и проверяет новейший тарбол, распаковывает его в `/root`,
пишет `config.installed.sh` скриптом [`tools/config-check.sh`](tools/config-check.sh),
затем конфигурирует, собирает и ставит.

- Вставляйте блок как есть: команды работают и в `sh`, и в `csh`, а комментариев в них
  нет нарочно — интерактивный csh не считает `#` комментарием.
- Если PHP стоит в другом месте (например, `/usr/local/php5640`), поменяйте префикс в
  строке `config-check.sh` и в последней строке.
- После сборки перезапустите Apache или php-fpm, чтобы ни один воркер не остался на
  старом бинарнике.

Модуль Apache ставится в `/usr/local/libexec/apache24/` как `libphpXY.so`
(`libphp84.so`, `libphp83.so`, … `libphp74.so`, `libphp56.so`), а не как `libphp.so`,
`libphp7.so` или `libphp5.so`, — чтобы сборки разных версий не затирали друг друга.
`make install` не правит `httpd.conf`: после первой такой установки направьте строку
`LoadModule` на новый файл, иначе Apache продолжит грузить старый:

| Версия | Строка `LoadModule` |
|---|---|
| 8.1–8.4 | `LoadModule php_module libexec/apache24/libphp84.so` (`libphp83.so`, `libphp82.so`, `libphp81.so`) |
| 7.4 | `LoadModule php7_module libexec/apache24/libphp74.so` |
| 5.6 | `LoadModule php5_module libexec/apache24/libphp56.so` |

Один Apache грузит один модуль PHP.

### PHP 8.4

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.4-latest/php-8.4-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.4-latest/php-8.4-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.4-fbsd-latest.tar.xz.sha256` php-8.4-fbsd-latest.tar.xz
tar xf php-8.4-fbsd-latest.tar.xz
cd /root/`tar tf php-8.4-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php84
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php84/bin/php -v
```

### PHP 8.3

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.3-latest/php-8.3-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.3-latest/php-8.3-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.3-fbsd-latest.tar.xz.sha256` php-8.3-fbsd-latest.tar.xz
tar xf php-8.3-fbsd-latest.tar.xz
cd /root/`tar tf php-8.3-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php83
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php83/bin/php -v
```

### PHP 8.2

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.2-latest/php-8.2-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.2-latest/php-8.2-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.2-fbsd-latest.tar.xz.sha256` php-8.2-fbsd-latest.tar.xz
tar xf php-8.2-fbsd-latest.tar.xz
cd /root/`tar tf php-8.2-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php82
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php82/bin/php -v
```

### PHP 8.1

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.1-latest/php-8.1-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.1-latest/php-8.1-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.1-fbsd-latest.tar.xz.sha256` php-8.1-fbsd-latest.tar.xz
tar xf php-8.1-fbsd-latest.tar.xz
cd /root/`tar tf php-8.1-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php81
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php81/bin/php -v
```

### PHP 7.4

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-7.4-fbsd-latest.tar.xz.sha256` php-7.4-fbsd-latest.tar.xz
tar xf php-7.4-fbsd-latest.tar.xz
cd /root/`tar tf php-7.4-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php74
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php74/bin/php -v
```

### PHP 5.6

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-5.6-latest/php-5.6-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-5.6-latest/php-5.6-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-5.6-fbsd-latest.tar.xz.sha256` php-5.6-fbsd-latest.tar.xz
tar xf php-5.6-fbsd-latest.tar.xz
cd /root/`tar tf php-5.6-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php56
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php56/bin/php -v
```

Для 5.6 на FreeBSD 14 и 15 опции `--with-mcrypt=/usr/local` нужен пакет `libmcrypt`
(`--with-pcre-regex=/usr/local` со встроенной PCRE 8.45 не пишется, см.
[Встроенная PCRE](#встроенная-pcre)); FreeType находится через `pkg-config` (в пакете
`freetype2` больше нет `freetype-config`).

**Что делает [`config-check.sh`](tools/config-check.sh):**

| Случай | Что делает скрипт |
|---|---|
| Его аргумент | каталог установки (`/usr/local/php82`): скрипт запускает из него `bin/php` (или `sbin/php-fpm`, `bin/php-cgi`); подойдёт и путь к одному из этих бинарников |
| Опции | из установленного PHP (`php -n -i`, строка Configure Command), никогда не из `config.nice` вслепую: `config.nice` может остаться от запуска configure, который так и не был установлен |
| Старый `config.nice` | сравнивается с этими опциями. Скрипт находит его сам: `/root/php-<установленная версия>/config.nice` или новейший `/root/php-<установленная версия>-fbsd-*/config.nice` от прошлой сборки этого форка; другой можно указать вторым аргументом (`sh config-check.sh /usr/local/php74 /root/php-7.4.33/config.nice`) |
| Кавычки PHP 5.6 | 5.6 записывает опции с пробелами в сломанных кавычках (`'CFLAGS=-O3 '-pipe' ...''`): скрипт читает их так, как прочитал бы shell, — одной опцией |
| Бинарник не запускается | опции берутся из `php-config --configure-options`, а он печатает их совсем без кавычек, так что `CFLAGS=-O3 -pipe ...` распадается на отдельные слова: скрипт возвращает слова после `ИМЯ=значение` в его значение |
| PHP из пакетов | `lang/phpXY`, `phpXY-*`, `mod_phpXY`: `sh config-check.sh --pkg` (или `--pkg php74`, если пакетами стоит несколько версий PHP) пишет `config.installed.sh` для ручной сборки в `/usr/local/phpXY`: по опции на каждый установленный пакет расширения плюс опции порта `phpXY`, `CFLAGS` и `CPUTYPE` из `/etc/make.conf`. Он перечисляет то, что не переносит (пакеты PECL, утилиты), и печатает строку `pkg set -A 0`, которая сохранит библиотеки, когда пакеты потом удалят |
| Пакеты встроенных расширений PECL | сохраняют то, с чем были собраны, — как показывает `php --ri` PHP из пакетов: lz4 и zstd для redis (в `databases/php-redis` включены по умолчанию), SASL, сериализатор JSON и `MemcachedServer` для memcached (умолчания `databases/pecl-memcached`), igbinary, хуки swoole |
| Стоит `mod_phpXY` | одна сборка делает только один модуль SAPI (`./configure`: «You can build only one SAPI module»), а порты собирают модуль Apache (`mod_phpXY`) и embed-библиотеку (опция `EMBED` у `phpXY`, `libphp7.so` в `/usr/local/lib`) отдельно: скрипт оставляет модуль Apache, опускает `--enable-embed` и говорит, линкуется ли с embed-библиотекой какой-нибудь пакет (`pkg shlib -R libphp7.so`) |

Окружение одинаково для каждой сборки PHP, что бы ни было у старой:

```
CFLAGS='-O3 -pipe -march=<CPUTYPE из /etc/make.conf> -fstack-protector-strong -fno-strict-aliasing'
CXXFLAGS='-O3 -pipe -march=<CPUTYPE из /etc/make.conf> -fstack-protector-strong -fno-strict-aliasing'
LIBS='-lpthread'
```

| Переменная или опция | Правило |
|---|---|
| `LDFLAGS` | нет: clang не нужен `-fstack-protector` при линковке; `/usr/local/phpdeps` добавляет свои |
| `-std=c++17` | в `CXXFLAGS` только для intl в PHP 7.4 и новее, когда `c++` по умолчанию берёт более старый стандарт: clang 16 и новее (FreeBSD 13.3 и новее) и так берёт C++17, а PHP 8.1 и новее сам выбирает его для ICU 74 и новее |
| `-march` | всегда из `/etc/make.conf` сервера, на котором работает скрипт (`CPUTYPE` или `-march=` в его `CFLAGS`; без них — никакого): `-march` из `config.nice`, скопированного с сервера с другим процессором, не переносится. Если процессору не хватает того, что нужно этому `-march` (`x86-64-v4` нужен AVX-512, `x86-64-v3` — AVX2), скрипт предупреждает: PHP с ним остановился бы там с `Illegal instruction` |
| `--build` | называет нашу сборку и систему, на которой она собрана, по образцу портов `amd64-portbld-freebsd15.1`: `amd64-srcbld-freebsd15.1`; `build_alias` убирается |
| Отбрасываются и перечисляются в отчёте | строки `CFLAGS`, `CXXFLAGS`, `LDFLAGS`, `LIBS`, `CPPFLAGS`, `CC`, `CXX` и `CPP` старого `config.nice` и каждая опция `ИМЯ=значение` установленной сборки (окружение её запуска configure, которое записывает autoconf: PHP 5.6 держит там `CFLAGS` и подобные, порты оставляют `CC=cc`, `CPP=cpp`, `PKG_CONFIG`, `LDFLAGS=-fstack-protector`) |
| Переносятся | остальные строки окружения `config.nice` (`PKG_CONFIG_PATH`, `OPENSSL_CFLAGS`, …) |

Собрать прямо из ветки тоже можно, но тогда нужны autoconf, bison и re2c (сначала
`./buildconf --force`).

### Что войдёт в сборку: php-menu.sh

[`tools/php-menu.sh`](tools/php-menu.sh) — это `make config` портов для этого форка:
диалоги (bsddialog на FreeBSD 14 и новее, dialog на 13) с описаниями из портов. В
отличие от портов, всё встраивается в один PHP.

| Экран | Пункты |
|---|---|
| Опции сборки | опции `lang/phpXY` и `mod_phpXY`: SAPI, ZTS, отладка, IPv6, JIT OPcache, системная PCRE |
| Расширения | расширения `phpXY-extensions` плюс встроенные расширения PECL |
| Опции отдельных расширений | какой libcurl, legacy-провайдер OpenSSL, какая libgd и её форматы, драйверы PDO, обработчики DBA, сессии, сериализаторы и сжатие redis и memcached, Argon2 из libargon2 или из OpenSSL 3.2 в 8.4, … |

Расширение со своим экраном (curl, GD, PDO, redis, …) отмечено в списке стрелкой
`--->`. Его экран идёт после списка, если расширение включено, а кнопка **Options**
списка открывает экран пункта под курсором сразу и потом возвращает список с курсором
на этом пункте (Cancel там всё отменяет); экран, показанный так, сразу после списка
второй раз не показывается. Выпадающих списков в диалогах нет, поэтому выбор одного
пункта открывается так.

Что от чего зависит, проверяется прямо при выборе — по скриптам configure и исходникам
C каждой ветки:

| Правило | Например |
|---|---|
| Расширение, которое нужно другому, включается с пояснением | XSL включает DOM, сериализатор igbinary у redis включает igbinary |
| То, что не может быть вместе, не пропускается | модуль Apache и embed-библиотека, imagick и gmagick, swoole и openswoole, ZTS и Argon2 из OpenSSL |

Запускайте его внутри дерева исходников, после `config-check.sh`, и собирайте скриптом,
который он пишет, вместо `config.installed.sh`:

```sh
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/php-menu.sh
sh php-menu.sh
sh config.menu.sh
```

| Что | Как |
|---|---|
| Начинает с | того, что есть в установленной сборке (`config.installed.sh` от `config-check.sh`), сохраняя её окружение и прочие опции (layout, пути php.ini, `--build`). Без `config.installed.sh` — только с нашей базовой сборки (`/usr/local/phpXY`, `--disable-all`, CLI и OPcache; SAPI и расширения выбираются) с флагами компилятора, общими для всех сборок |
| Пишет | `config.menu.sh` — скрипт того же вида, с SAPI, опциями сборки и расширениями, выбранными в меню |
| Включено по умолчанию | OPcache внутри PHP и запрет загрузки расширений (опции этого форка, [ниже](#встроенный-opcache-и-запрет-загрузки-расширений)); встроенный curl там, где в базовой системе OpenSSL 3 (FreeBSD 14 и новее); Argon2 из OpenSSL — где 3.2 (FreeBSD 15) |
| Выключено, пока не выбрать | phpdbg: в 7.4 и новее меню пишет `--disable-phpdbg`, потому что `--disable-all` не трогает SAPI |
| Вводится на последнем экране | каталог установки (по умолчанию `/usr/local/phpXY` или каталог установленной сборки): из него получаются `--prefix` и `--mandir=<каталог>/man`, а прочие пути установленной сборки внутри её старого каталога переезжают вместе с ним. С mysqli или pdo_mysql (5.6: с расширением mysql) — сокет MySQL (`/tmp/mysql.sock`): один `--with-mysql-sock` задаёт значение по умолчанию и `mysqli.default_socket`, и `pdo_mysql.default_socket` |
| Не пишется | `--infodir` (PHP не ставит info-страниц); `--localstatedir=/var` — только вместе с FPM (его читает один php-fpm) |
| Выбор | сохраняется так же, как его сохраняют порты, — в `/var/db/php-menu/phpXY.options` — и становится началом следующего запуска (`--reset` начинает заново) |
| В конце | пакеты, которые нужны выбору |
| Без диалогов | `sh php-menu.sh --batch +GD -CGI PREFIX=/usr/local/php84` пишет скрипт; пункт со своего экрана включает и своё расширение (`+PDO_MYSQL` — PDO) |
| `--list` | `sh php-menu.sh --list` показывает пункты, пути, их состояние и шаблоны |

**Шаблоны.** Сначала меню спрашивает, с чего начать: с того, что оно нашло (сохранённый
выбор, установленная сборка или значения по умолчанию), или с шаблона — набора выборов
под одно приложение; в главном меню это есть ещё раз («Templates»). Шаблон включает свои
пункты и выключает остальные SAPI и расширения, которые в нём названы; прочее остаётся
по умолчанию, то, что нужно его пунктам, включается тоже, а на экранах после этого можно
поменять что угодно. Без диалогов: `sh php-menu.sh --batch --template=roundcube`.

| Шаблон | PHP | Для чего |
|---|---|---|
| `roundcube` | 7.4 и новее | php-fpm и CLI (скрипты из `bin/`, cron) для [Roundcube](https://roundcube.net/) 1.6 (PHP 7.3+) и 1.7 (PHP 8.1+); сверено с Roundcube 1.6.20 и 1.7.5 |

Что шаблон `roundcube` включает и чего в нём нет:

| Группа | Расширения |
|---|---|
| Требует его инсталлятор | ctype, dom, filter, intl, json, mbstring с функциями регэкспов, openssl, session, PDO, xml |
| Его [страница wiki](https://github.com/roundcube/roundcubemail/wiki/Install-Requirements) и его библиотеки | fileinfo, iconv, sockets |
| Необязательные, кроме LDAP | curl (встроенный, для Guzzle), exif (ориентация фото JPEG), gd (JPEG, WebP и FreeType для 1.7), imagick, xmlwriter, zip |
| База данных | только MySQL и только через PDO (pdo_mysql) |
| Нет в нём | mysqli, PostgreSQL, SQLite, LDAP; pspell и enchant — их использует только проверка орфографии (`spellcheck_engine`), а она с Roundcube 1.5.0 по умолчанию выключена (`enable_spellcheck`) |

Меню с шаблоном `roundcube` (bsddialog в консоли FreeBSD 80x25, шрифт Terminus): с чего
начать, опции сборки, расширения, драйверы PDO через кнопку Options, опции curl, GD,
mbstring и OpenSSL, главное меню и скрипт, который оно пишет:

<p><img src="docs/images/menu-roundcube.gif" alt="php-menu.sh с шаблоном roundcube" width="800"></p>

Кнопка Options на PDO и экран, который она открывает:

<p><img src="docs/images/menu-roundcube-options.png" alt="Кнопка Options на PDO" width="800"></p>
<p><img src="docs/images/menu-roundcube-pdo.png" alt="Драйверы PDO" width="800"></p>

Расширения с шаблоном `roundcube` и у голой сборки (по умолчанию: только CLI и OPcache):

<p><img src="docs/images/menu-roundcube-ext.png" alt="Расширения с шаблоном roundcube" width="800"></p>
<p><img src="docs/images/menu-bare-ext.png" alt="Расширения голой сборки" width="800"></p>

<details>
<summary>Ещё экраны: с чего начать, опции сборки, главное меню, скрипты</summary>

<p><img src="docs/images/menu-start-roundcube.png" alt="С чего начать: по умолчанию или шаблон" width="800"></p>
<p><img src="docs/images/menu-roundcube-core.png" alt="Опции сборки с шаблоном roundcube" width="800"></p>
<p><img src="docs/images/menu-roundcube-ext2.png" alt="Ещё расширения с шаблоном roundcube" width="800"></p>
<p><img src="docs/images/menu-main.png" alt="Главное меню" width="800"></p>
<p><img src="docs/images/menu-roundcube-script.png" alt="Скрипт шаблона roundcube" width="800"></p>
<p><img src="docs/images/menu-bare-core.png" alt="Опции голой сборки" width="800"></p>
<p><img src="docs/images/menu-bare-script.png" alt="Скрипт голой сборки" width="800"></p>
<p><img src="docs/images/menu-bare.gif" alt="php-menu.sh по умолчанию" width="800"></p>

</details>

Картинки делает [`tools/menu-screenshots.py`](tools/menu-screenshots.py) (pyte и
Pillow): bsddialog в терминале 80x25, шрифт Terminus и 16 цветов консоли FreeBSD.

### Встроенный OPcache и запрет загрузки расширений

Две опции configure этого форка, во всех ветках (патчи
`freebsd/patches/<версия>/feature-*.patch`). Обе выключены, пока их не задать;
`php-menu.sh` включает обе по умолчанию — в том числе когда начинает с
`config.installed.sh` сборки, сделанной до них.

| Что | `--enable-opcache-static` | `--disable-extension-loading` |
|---|---|---|
| Действие | OPcache встраивается в PHP (одинаково в CLI, php-fpm, php-cgi и модуль Apache), как в PHP 8.5: `opcache.so` нет, строка `zend_extension` не нужна | PHP не загружает расширения во время работы; `php -i` показывает `Dynamic Library Support => disabled (--disable-extension-loading)` |
| Старые строки php.ini | оставшаяся `zend_extension=opcache.so` молча пропускается, даже если старый `opcache.so` ещё лежит в `extension_dir`; `opcache.enable` и прочие настройки `opcache.*` работают как раньше | строки `extension=` и `zend_extension=`, `dl()` и `php -z` отклоняются с предупреждением при старте, где назван файл; строка расширения, которое уже встроено (`extension=mysqli`), молча пропускается |
| configure останавливается | в 8.x вместе с ZTS и JIT (до PHP 8.5 JIT достаёт данные потока способом, который работает только из `opcache.so`): добавьте `--disable-opcache-jit` или соберите `opcache.so` | если какое-то расширение собиралось бы как `.so` (для OPcache добавьте `--enable-opcache-static`) |

Без меню добавьте их к сборке: `sh config.installed.sh --enable-opcache-static
--disable-extension-loading`. Когда такая сборка установлена, строки `extension=` и
`zend_extension=opcache.so` в php.ini больше не нужны.

### Тестовая сборка на FreeBSD

| Что | Как |
|---|---|
| Workflow | [`.github/workflows/build-test.yml`](.github/workflows/build-test.yml): запуск — на https://github.com/azsupport/php-src/actions/workflows/build-test.yml кнопкой **Run workflow** |
| Машина | виртуальная машина FreeBSD, по умолчанию 15.1: clang 19, OpenSSL 3.5 из базы, библиотеки из `pkg` |
| Собирает | тарболы `-latest` с опциями configure наших серверов, встроенным curl (`--with-curl=bundled`) и `--with-openssl-legacy-provider` |
| Проверяет | `php -v`, `php -m`, [`tools/build-test-smoke.php`](tools/build-test-smoke.php) (ошибки разбора, DNS и IPv6, `tls://`, `ssl://` и `https://`, legacy-шифры OpenSSL, `openssl_seal()`, GD с FreeType, XML, сессии, встроенный curl и другое) и часть тестов PHP |
| Результат | по каждой версии, на странице запуска |
| На машине с FreeBSD | тот же скрипт, из checkout этой ветки с тарболами в `dist/`: `sh tools/build-test.sh --deps 5.6 7.4` ставит пакеты, `sh tools/build-test.sh --tests 5.6 7.4` собирает и проверяет; наборы опций — в [`tools/build-test.sh`](tools/build-test.sh) |

### Встроенные расширения PECL

Ветки и тарболы несут эти расширения PECL в `ext/`, поэтому они встраиваются в PHP так
же, как штатные, и не требуют ни `phpize`, ни строки `extension=`. Ничего не меняется,
пока не задана их опция:

| Расширение | PHP 8.2, 8.3, 8.4 | PHP 8.1 | PHP 7.4 | PHP 5.6 |
|---|---|---|---|---|
| redis | 6.3.0 | 6.3.0 | 6.3.0 | 4.3.0 |
| memcached | 3.4.0 | 3.4.0 | 3.4.0 | 2.2.0 |
| memcache | 8.2 | 8.2 | 4.0.5.3 | 3.0.8 |
| igbinary | 3.2.16 | 3.2.16 | 3.2.16 | 2.0.8 |
| imagick | 3.8.1 | 3.8.1 | 3.8.1 | 3.8.1 |
| gmagick | 2.0.6RC1 | 2.0.6RC1 | 2.0.6RC1 | 1.1.7RC3 |
| swoole | 6.2.3 | 6.1.10 | 4.8.13 | — |
| OpenSwoole | 4.12.1 | 4.12.1 | 4.12.1 | — |
| excimer | 1.2.7 | 1.2.7 | 1.2.7 | — |
| mcrypt | 1.0.9 | 1.0.9 | 1.0.9 | в самом PHP 5.6 |

Как их включить:

| Расширение | Опция configure | Пакет FreeBSD |
|---|---|---|
| [redis](https://pecl.php.net/package/redis) | `--enable-redis` | |
| [memcached](https://pecl.php.net/package/memcached) | `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` | `libmemcached` |
| [memcache](https://pecl.php.net/package/memcache) | `--enable-memcache` | |
| [igbinary](https://pecl.php.net/package/igbinary) | `--enable-igbinary`; как сериализатор для redis и memcached ещё `--enable-redis-igbinary` и `--enable-memcached-igbinary` | |
| [imagick](https://pecl.php.net/package/imagick) | `--with-imagick=/usr/local`; не вместе с gmagick | `ImageMagick7` или `ImageMagick7-nox11` |
| [gmagick](https://pecl.php.net/package/gmagick) | `--with-gmagick=/usr/local`; не вместе с imagick | `GraphicsMagick` |
| [swoole](https://pecl.php.net/package/swoole) (7.4+) | `--enable-swoole`; не вместе с OpenSwoole | `brotli` (по желанию, для сжатия brotli) |
| [OpenSwoole](https://pecl.php.net/package/openswoole) (7.4+) | `--enable-openswoole`; не вместе со swoole | |
| [excimer](https://pecl.php.net/package/excimer) (7.4+) | `--enable-excimer` | |
| [mcrypt](https://pecl.php.net/package/mcrypt) (7.4+) | `--with-mcrypt=/usr/local` | `libmcrypt` |

Версии — новейшие стабильные релизы PECL для каждой версии PHP, с такими исключениями:

| Исключение | Почему |
|---|---|
| memcache 3.0.8 для 5.6 | релиз, который дистрибутивы ставили для PHP 5.5/5.6; его единственный стабильный релиз 5.x — 2.2.7 от 2012 года |
| gmagick 2.0.6RC1, и 1.1.7RC3 для 5.6 | у gmagick стабильного релиза нет вовсе: 2.0.6RC1 (бета, 2021) плюс два более поздних коммита его git master с исправлениями для PHP 8.1 |
| OpenSwoole везде 4.12.1 | линия 4.x, на которой работают серверы (ниже) |

Исходники берутся из git-репозиториев апстрима на коммите тега релиза (у gmagick, где
тегов нет, — на коммите релиза), закреплённом в [`freebsd/pecl.conf`](freebsd/pecl.conf);
исправления, с которыми они собираются внутри php-src с clang 19, — в
[`freebsd/pecl/`](freebsd/pecl). Расширениям нужен `--enable-session` (обработчики
сессий); в 5.6 и 7.4 redis нужен ещё `--enable-json`, а в 5.6 — `--enable-hash`.

Две пары можно собрать только по одному из пары, и configure останавливается, если
заданы обе опции пары. Чтобы на сервере были оба из пары, встройте один в PHP, а другой
соберите отдельным модулем через `phpize`.

| Пара | Почему не в одном PHP |
|---|---|
| imagick и gmagick | в GraphicsMagick и ImageMagick одинаковые имена функций MagickWand, так что imagick и gmagick вызывали бы библиотеку друг друга |
| swoole и OpenSwoole | OpenSwoole — форк swoole с теми же символами C++ |

OpenSwoole — 4.12.1 для всех версий с 7.4, линия 4.x, на которой работают серверы:
OpenSwoole 22 и новее изменили API (пространство имён `OpenSwoole\`, настройки ini
`openswoole.*`, нет `Co\` и `swoole.use_shortname`). 4.12 в апстриме поддерживает PHP
до 8.2; для 8.3 и 8.4 патч портирует её:

| PHP | Изменение |
|---|---|
| 8.3+ | новый `php_url_encode_hash_ex()` из 8.3 |
| 8.3+ | границы стека C, которые проверяет PHP 8.3, следуют за стеками корутин (иначе каждый вызов в корутине падает с «Maximum call stack size reached») |
| 8.4 | `zend_str_tolower()` вместо `php_strtolower()` (её нет в 8.4) |
| 8.4 | `exit()` в корутине или сервере по-прежнему бросает `Swoole\ExitException` (в 8.4 exit стал функцией) |
| 8.4 | встроенная библиотека PHP явно объявляет свои nullable-параметры (уведомления об устаревании в PHP 8.4) |

Что ещё меняют патчи:

| Расширение | В апстриме | С патчем |
|---|---|---|
| swoole, OpenSwoole | включены по умолчанию (`--enable-swoole`, `--enable-openswoole`), а configure OpenSwoole проверяет переменную swoole вместо своей: внутри php-src это встроило бы их в каждый PHP (без `--disable-all`, а OpenSwoole даже с ним) | выключены по умолчанию |
| swoole 4.8 и 6.1, OpenSwoole | свой `--enable-openssl`: внутри php-src он сбрасывал настройку `--with-openssl`, и mysqlnd тогда собирался без своего кода OpenSSL (RSA для `caching_sha2_password`) | убран: они берут OpenSSL, если PHP собран `--with-openssl` |
| swoole, OpenSwoole | дописывают `-std=c++11`/`-std=c++14` в `CXXFLAGS`, а внутри php-src это действовало бы и на ext/intl (ICU 75 и новее нужен C++17) | убрано |
| swoole 6.x | вызывает нигде не объявленный `sw_usleep()` в той ветке кода, которую компилирует FreeBSD (нет futex) | `usleep()`, как в порту FreeBSD `devel/php-swoole` |
| OpenSwoole | порта FreeBSD нет, и на FreeBSD он не компилировался: его `swoole_socket.h` подключает `<netinet/ip6.h>` раньше `<sys/types.h>`, а его hiredis задаёт `_XOPEN_SOURCE`, который прячет типы BSD, нужные `<netinet/ip6.h>` | исправлено и то и другое; тестовая сборка собирает его вместе с gmagick на 7.4–8.4 |
| excimer | в FreeBSD нет `gettid()`, поэтому excimer 1.2.4 и новее там не компилировался (порт `devel/pecl-excimer` остался на 1.2.3) | id потока своего таймера берёт из `pthread_getthreadid_np()`; `-fvisibility=hidden` только своим исходникам |

igbinary как сериализатор (`--enable-memcached-igbinary`, `--enable-redis-igbinary`):

| Расширение | С igbinary как сериализатором |
|---|---|
| memcached | igbinary становится сериализатором по умолчанию (`memcached.serializer = igbinary`) для массивов и объектов. PHP без igbinary такие значения прочитать не сможет, поэтому, пока серверы с ним и без него делят один memcached, задайте в `php.ini` `memcached.serializer = php`. Значения, уже сохранённые сериализатором php, читаются в любом случае |
| redis | ничего не сериализует, пока не задан `Redis::OPT_SERIALIZER`, так что там igbinary используется только там, где код просит `Redis::SERIALIZER_IGBINARY` |

Как добавить их к пересборке:

| Способ | Что делать |
|---|---|
| Вручную | допишите опции после `sh config.installed.sh`, например `sh config.installed.sh --enable-redis --enable-memcache`, и уберите из `php.ini` строки `extension=redis.so` старых отдельных модулей |
| Скрипт | `config-check.sh` сам не добавляет их в `config.installed.sh`: для отдельных модулей установленного PHP, которые есть в дереве, он в конце печатает готовую к копированию полную команду — `sh config.installed.sh` с их опциями. Опции несут то, с чем модули были собраны (`php --ri`: сериализатор igbinary, lzf/zstd/lz4, SASL, curl у swoole, c-ares, pgsql), плюс `--enable-json`, `--enable-hash` или `--enable-session`, если в установленной сборке нет того, что им нужно; отчёт перечисляет строки `extension=` (файл и строку), которые надо убрать после `make install` |
| Пакеты | `config-check.sh --pkg` превращает установленные пакеты `phpXY-pecl-*` в опции, как и прочие пакеты расширений |

Новые релизы этих расширений находит ежедневная [проверка апстрима](#проверка-апстрима).

### OpenSSL

| PHP | С OpenSSL 3 базовой системы (FreeBSD 14 и 15; 3.5.6 во FreeBSD 15.1) |
|---|---|
| 8.1+ | поддерживается в апстриме: `--with-openssl` |
| 7.4 | [`compat-openssl3.patch`](freebsd/patches/7.4/compat-openssl3.patch): хватает `--with-openssl`, потому что FreeBSD поставляет `openssl.pc`. RC4 (по умолчанию у `openssl_seal()`), Blowfish, DES, RC2, CAST5 и MD4 требуют `--with-openssl-legacy-provider` (ниже) |
| 5.6 | [`compat-openssl3.patch`](freebsd/patches/5.6/compat-openssl3.patch) с `--with-openssl=/usr` и тем же `--with-openssl-legacy-provider`, что и 7.4. Сверх того `tls://` и `STREAM_CRYPTO_METHOD_TLS_*` договариваются о TLS 1.0–1.3: 5.6 ограничивает их TLS 1.0, который OpenSSL 3 на своём уровне безопасности по умолчанию отвергает, так что они не могли соединиться вовсе (`ssl://`, `https://` и `STREAM_CRYPTO_METHOD_SSLv23_*` и так выбирали новейшую версию) |

Что в 7.4 и 5.6 ведёт себя иначе, чем с OpenSSL 1.1, — это сам OpenSSL 3, так же как с
PHP 8.x; сборка 7.4 или 5.6 с отдельным OpenSSL 1.1 ведёт себя как раньше:

| Случай | С OpenSSL 3 |
|---|---|
| TLS 1.0 и 1.1 | по умолчанию выключены |
| Расшифровка RSA PKCS#1 v1.5 неверным ключом | возвращает случайные байты вместо ошибки (защита от атаки Marvin) |
| Ключи DSA/DH короче 512 бит, сертификаты с неправильно записанным временем | отклоняются |

Опция `--with-openssl-legacy-provider`:

| Что | Как |
|---|---|
| Действие | загружает legacy-провайдер OpenSSL 3 вместе с провайдером по умолчанию при старте, так что RC4, Blowfish, DES, RC2, CAST5, MD4 и подобные работают без правки `openssl.cnf` |
| Где есть | в апстриме PHP 8.4 ([php-src GH-13951](https://github.com/php/php-src/pull/13951)); этот форк добавляет ту же опцию в 5.6, 7.4, 8.1, 8.2 и 8.3. По умолчанию выключена, как в апстриме |
| Модуль | `/usr/lib/ossl-modules/legacy.so`, часть базовой системы FreeBSD 14 и 15; если его нет, PHP стартует, а эти алгоритмы остаются недоступны |
| OpenSSL 1.1 | в базовой системе FreeBSD 13.x: ничего не меняет — алгоритмы там встроены |
| Скрипт | `config-check.sh` добавляет её к сборке с OpenSSL 3, если установленный PHP умеет RC4 (собран с OpenSSL 1.1 или с legacy-провайдером), чтобы данные, зашифрованные на старой сборке `openssl_encrypt(..., "rc4", ...)`, оставались читаемыми, и всегда для 5.6 и 7.4, у которых `openssl_seal()` по умолчанию использует RC4. `sh config.installed.sh --without-openssl-legacy-provider` её убирает |

### Встроенный curl

Каждая ветка несёт curl в `ext/curl/libcurl` и нужные ему библиотеки в
`ext/curl/deps` — файлы релизов их портов FreeBSD, с SHA-256 из их distinfo
([`freebsd/curl.conf`](freebsd/curl.conf),
[`freebsd/curl-deps.conf`](freebsd/curl-deps.conf); в дерево их кладёт
[`tools/curl-sources.sh`](tools/curl-sources.sh)):

| Библиотека | Версия | Порт FreeBSD | Для чего она curl |
|---|---|---|---|
| curl | 8.23.0 | `ftp/curl` | с патчем configure этого порта |
| c-ares | 1.34.9 | `dns/c-ares` | резолвит имена (ниже) |
| nghttp2 | 1.70.0 | `www/libnghttp2` | HTTP/2 |
| brotli | 1.2.1 | `archivers/brotli` | ответы в `br` (`CURLOPT_ENCODING`); 1.2.1 исправляет CVE-2026-111497 — запись за границей в декодере |
| zstd | 1.5.7 | `archivers/zstd` | ответы в `zstd` (`CURLOPT_ENCODING`) |
| libidn2 | 2.3.8 | `dns/libidn2` | международные доменные имена (IDN) |
| libpsl | 0.23.3 | `dns/libpsl` | список публичных суффиксов: никаких cookies на целый публичный суффикс вроде `co.uk` |
| список публичных суффиксов | 21.09.2026 | `dns/public_suffix_list` | встроен в libpsl |

Как он собирается и работает:

| Что | Как |
|---|---|
| Сборка | `--with-curl=bundled` собирает всё это во время `configure` (две-три минуты, лог в `ext/curl/libcurl-build.log`) одними cc и make и линкует в PHP статически, с тем OpenSSL, который берёт сам PHP |
| Пакеты | не нужны: PHP не зависит ни от пакета curl, ни от его библиотек, а его curl так же свеж, как тарбол |
| Чего среди них нет | libunistring (libidn2 собирает ту её часть, которая ему нужна) и IDN-библиотеки для libpsl (curl отдаёт ей имена хостов уже в punycode, и встроенного списка хватает) |
| Символы | символы curl не экспортируются из `php` и `libphp.so`, символы его библиотек локальны в `libcurl.a`, так что модуль, который грузит libcurl системы или несёт свою копию nghttp2 (swoole), с ними не смешивается |
| Системный libcurl | его по-прежнему берёт простой `--with-curl` |
| OpenSSL | curl 8.18.0 и новее нужен OpenSSL 3.0 или новее. Во FreeBSD 13.x в базовой системе OpenSSL 1.1.1, поэтому там `config-check.sh` оставляет `--with-curl` (пакет curl) и объясняет почему; на FreeBSD 14 и 15 он пишет `--with-curl=bundled` |
| Исправления безопасности | curl или одной из его библиотек попадают в PHP с пересборкой: ежедневная [проверка апстрима](#проверка-апстрима) открывает issue на каждый новый релиз (теги их репозиториев), на изменения их портов FreeBSD и когда порт взял файл релиза, которого нет в бандле (его distinfo) |
| `/usr/local/phpdeps` | [`tools/build-deps.sh`](tools/build-deps.sh) берёт curl и эти библиотеки из тех же файлов и собирает так же |

Опции — как в порту FreeBSD, с такими отличиями:

| Отличие | Почему |
|---|---|
| имена резолвит c-ares (опция порта `CARES`, а не `THREADED_RESOLVER`) | зависший запрос к DNS не держит воркер (ниже) |
| нет IMAP, POP3, SMTP | PHPMailer, Symfony Mailer, Roundcube и IMAP-библиотеки ходят к почтовым серверам своими сокетами |
| нет WebSocket (`ws://`, `wss://`) | в PHP нет `curl_ws_send()` и `curl_ws_recv()`; в master php-src их тоже нет, только `CURLOPT_WS_OPTIONS` |
| нет NTLM | слабый, в curl с 8.20 только по явному включению, curl собирается его удалить; нужен лишь старым серверам и прокси Microsoft |
| нет headers API, экспорта TLS-сессий, `curl_easy_option_*`, текстового индикатора прогресса | PHP ничего из этого не вызывает; `CURLOPT_PROGRESSFUNCTION` и `CURLOPT_XFERINFOFUNCTION` работают |
| нет DICT, Gopher, IPFS, MQTT, RTSP, Telnet, TFTP, LDAP, SCP/SFTP (libssh2), GSSAPI | редкие протоколы |

c-ares здесь не ради скорости: время уходит на ответ DNS-сервера, а A и AAAA curl 8.23 и
так спрашивает параллельно. Разница — когда DNS-сервер не отвечает:

| Случай | Threaded-резолвер (`getaddrinfo()`) | c-ares |
|---|---|---|
| DNS-сервер не отвечает | `getaddrinfo()` прервать нельзя, поэтому хэндл ждёт на `curl_close()` (в 8.x — когда `$ch` уничтожается, самое позднее в конце запроса), пока тот не сдастся: с `resolv.conf` FreeBSD по умолчанию — не меньше 15 секунд на имя, а воркеры Apache и FPM тем временем копятся | бросает запрос сразу, и `CURLOPT_TIMEOUT` соблюдается. Проверено с DNS-сервером, который не отвечает, и `CURLOPT_TIMEOUT_MS` 1500: `curl_exec()` вернулся через 1,5 с, хэндл освободился сразу |
| `CURLOPT_DNS_SERVERS` и соседние опции | недоступны | работают |
| Что читает | резолвер системы, с модулями NSS | сам читает `/etc/resolv.conf`, `/etc/hosts` и строку `hosts:` из `/etc/nsswitch.conf`; модули NSS не используются |

Что встроенный curl оставляет:

| Оставлено | Что |
|---|---|
| Протоколы | HTTP(S), FTP(S), FILE (им могут пользоваться старые скрипты) |
| Возможности | HTTP/2, прокси, cookies, multipart (`CURLFile`), Unix-сокеты, IDN, PSL, brotli, zstd |
| Возможности, которые код должен включить сам | alt-svc, HSTS, DoH, AWS SigV4, `.netrc` |

### Встроенная PCRE

php-src несёт старую PCRE с известными ошибками безопасности памяти, а PHP использует JIT
по умолчанию (`pcre.jit=1`, с 7.0). Каждая ветка здесь несёт вместо неё новейший релиз
([`freebsd/pcre.conf`](freebsd/pcre.conf)):

| PHP | В php-src | Здесь |
|---|---|---|
| 8.4 | PCRE2 10.44 (и в master php-src тоже, октябрь 2026) | PCRE2 10.49 |
| 8.3 | PCRE2 10.42 | PCRE2 10.49 |
| 8.2 | PCRE2 10.40 | PCRE2 10.49 |
| 8.1 | PCRE2 10.39 | PCRE2 10.49 |
| 7.4 | PCRE2 10.35 | PCRE2 10.49 |
| 5.6 | PCRE 8.38, 2015 года | PCRE 8.45, последний релиз PCRE1 |

Ошибки старых копий:

| Ошибка | Исправлена в | Ветки |
|---|---|---|
| чтение за границей в JIT-компиляторе ([CVE-2022-1586](https://osv.dev/vulnerability/CVE-2022-1586), [CVE-2022-1587](https://osv.dev/vulnerability/CVE-2022-1587)) | PCRE2 10.40 | 7.4, 8.1 |
| чтение и запись за границей, в том числе в `pcre2_match` после отката JIT на неверном UTF ([CVE-2026-89156](https://security-tracker.debian.org/tracker/CVE-2026-89156); [oss-security, 04.09.2026](https://openwall.com/lists/oss-security/2026/09/04/7)) | PCRE2 10.48 | 7.4–8.4 |
| запись за границей в JIT с шаблоном под контролем атакующего ([CVE-2026-103111](https://app.opencve.io/cve/CVE-2026-103111)) | PCRE2 10.49 | 7.4–8.4 |
| ошибки JIT CVE-2017-6004 и CVE-2019-20838, переполнение целого CVE-2020-14155 и прочие исправления 8.39–8.45 (сама 5.6 JIT не использует) | PCRE 8.39–8.45 | 5.6 |

Как релиз попадает в дерево:

| Что | Как |
|---|---|
| Релиз | синк распаковывает тарбол релиза (его SHA-256 — тот же, что в `devel/pcre2` или `devel/pcre` freebsd-ports) |
| Импорт | [`freebsd/pcre/import-pcre2.sh`](freebsd/pcre/import-pcre2.sh) (5.6: [`import-pcre1.sh`](freebsd/pcre/import-pcre1.sh)) так же, как это делает php-src: исходники библиотеки, собственный `config.h` PHP (плюс умолчания релиза, которых в нём нет, например `MAX_VARLOOKBEHIND` для 7.4–8.3), список исходников в `ext/pcre/config0.m4` |
| Имена функций | PHP переименовывает функции своей встроенной PCRE в `main/php_compat.h` (`pcre2_compile_8` становится `php_pcre2_compile`), так что libpcre2, которую загрузил Apache, не перехватывает их вызовы. В списке php-src нет функций, добавленных после PCRE2 10.30 (и функций JIT у PCRE 8.x), а `pcre2_substitute` в 10.49 вызывает одну из них, поэтому импорт переименовывает и их |
| Тесты | тесты `ext/pcre` проходят как раньше; те, что печатают сообщения библиотеки, ожидают и старую, и новую формулировку, как в php-src с 8.1 и 8.3 (`freebsd/pcre/tests-<версия>.patch`) |
| Новые возможности | новая PCRE приносит их и в старые ветки: PHP 7.4 с 10.49 понимает lookbehind ограниченной переменной длины, например `(?<=a{1,3})b` |
| Системная PCRE | её по-прежнему берёт `--with-external-pcre` (5.6: `--with-pcre-regex=DIR`). `config-check.sh` не пишет эти опции, если PCRE дерева не старее системной, так что сборке не нужен пакет `pcre2` или `pcre`, и говорит об этом; если в системе библиотека новее, опция остаётся |
| Новые релизы | ежедневная [проверка апстрима](#проверка-апстрима) открывает issue на каждый новый релиз PCRE2 |

## Как приходят обновления

[`.github/workflows/sync.yml`](.github/workflows/sync.yml) запускается каждый час и
вызывает [`tools/sync.sh`](tools/sync.sh):

1. находит коммит апстрима для каждой цели из
   [`freebsd/targets.conf`](freebsd/targets.conf) через `git ls-remote`;
2. пропускает цели, у которых ветка уже несёт этот коммит и тот же набор патчей;
3. иначе пересобирает `freebsd/<версия>`, зеркалирует ветку Remi, собирает тарбол
   скриптом [`tools/makedist.sh`](tools/makedist.sh) (autoconf, bison и re2c из Ubuntu
   24.04) и публикует релизы.

Запуск можно сделать и вручную: на
https://github.com/azsupport/php-src/actions/workflows/sync.yml («Sync FreeBSD
branches») кнопкой **Run workflow**, по желанию с такими параметрами:

| Параметр | Что делает |
|---|---|
| `force` | пересобирает и перевыпускает, даже если апстрим не менялся |
| `targets` | только эти цели, например `7.4 8.4` (пусто — все) |
| `notes_only` | переписывает заметки текущих релизов, ничего не пересобирая (обычные запуски делают то же для актуальных целей) |

Полные заметки — в датированном релизе; `freebsd-<версия>-latest` ссылается на него.
Вторая сборка того же коммита апстрима в тот же день заменяет датированный релиз этого
дня. Локально: `tools/sync.sh --local` в клоне этого репозитория собирает ветки без
push.

### Проверка апстрима

Ежедневный workflow [`upstream-check.yml`](.github/workflows/upstream-check.yml) ищет
то, что веткам стоит взять. Каждая находка открывает одно issue с меткой `upstream`
([эти issue](https://github.com/azsupport/php-src/issues?q=label%3Aupstream)); само
ничего не применяется. За чем он следит — в
[`freebsd/upstream.conf`](freebsd/upstream.conf).

| Что ищет | Чего |
|---|---|
| Новые релизы | встроенных расширений PECL (теги репозиториев и PECL, сверяя с версиями PHP, которые поддерживает каждый релиз), curl, библиотек curl, PCRE2 |
| Коммиты портов FreeBSD, которые меняют патчи или сборку | их портов и `lang/php8x` |
| Файлы релизов в distinfo порта, которых нет в бандле | портов curl и его библиотек (не пока бандл впереди порта) |
| Конец security-поддержки, начиная за 60 дней до него | веток, которые собираются из тегов php-src (8.2 — 31.12.2026), с отметкой, есть ли у бэкпортов Remi Collet ветка, на которую можно перейти |

### Патчи совместимости сборки

Патчи, с которыми ветка просто собирается и работает на современной FreeBSD (и рядом со
сборками других версий), лежат в `freebsd/patches/<версия>/compat-*.patch` (формат git,
`-p1`, сверху строки `Description:` и `Origin:`). Они применяются всегда — коммитом
«Apply build compatibility patches» сразу после патчей портов — и перечислены в README
ветки и в заметках релиза; патч, который перестал применяться, роняет сборку, чтобы его
пересмотрели.

| Версия | Патч | Что исправляет |
|---|---|---|
| все | `compat-apache-module-name.patch` ([8.4](freebsd/patches/8.4/compat-apache-module-name.patch)) | `make install` кладёт модуль Apache в каталог модулей Apache как `libphpXY.so` (`libphp56.so`, `libphp74.so`, `libphp81.so` … `libphp84.so`) вместо `libphp5.so`, `libphp7.so` или `libphp.so`, чтобы сборки разных версий не затирали друг друга; `httpd.conf` не меняется, установка называет нужную ей строку `LoadModule` |
| 5.6 | [`compat-bison3.patch`](freebsd/patches/5.6/compat-bison3.patch) | парсеры, созданные bison 3.6+ (тарболы делаются на 3.8), сообщают только «syntax error» и сдвигают номера токенов `T_*`; теперь подробные ошибки и номера токенов тарбола 5.6.40 с php.net |
| 5.6 | [`compat-c99.patch`](freebsd/patches/5.6/compat-c99.patch) | clang 16+ (FreeBSD 14/15: clang 19) и gcc 14+ отвергают код до C99: проверки configure молча проваливались (нет `getaddrinfo` — нет разрешения имён IPv6; неверные типы `readdir_r` и `fopencookie`, ломавшие сборку; нет `pread`/`pwrite`, …), а четыре исходника не компилировались |
| 5.6 | [`compat-freetype-pkgconfig.patch`](freebsd/patches/5.6/compat-freetype-pkgconfig.patch) | FreeType без `freetype-config`: находится через `pkg-config`, и встроенная GD собирается с FreeType, так что `imagettftext()` рисует |
| 5.6 | [`compat-libxml2.patch`](freebsd/patches/5.6/compat-libxml2.patch) | изменения API libxml2 2.12+ (FreeBSD 15.1: 2.15) |
| 5.6 | [`compat-oniguruma.patch`](freebsd/patches/5.6/compat-oniguruma.patch) | с установленным пакетом `oniguruma` (он нужен 7.4 и 8.x) его `oniguruma.h` заслонял встроенный, и `ext/mbstring` не компилировался |
| 5.6 | [`compat-openssl3.patch`](freebsd/patches/5.6/compat-openssl3.patch) | OpenSSL 3: legacy-провайдер, `tls://`, `OPENSSL_SSLV23_PADDING`, открытый ключ CSR |
| 7.4 | [`compat-c99.patch`](freebsd/patches/7.4/compat-c99.patch) | проверки configure, которые отвергают clang 16+ и gcc 14+ (`write(2)` в stdout, функции в отдельных библиотеках) |
| 7.4 | [`compat-openssl3.patch`](freebsd/patches/7.4/compat-openssl3.patch) | OpenSSL 3: legacy-провайдер, `OPENSSL_SSLV23_PADDING`, открытый ключ CSR |

### Опции сборки

Опции этого форка (выше: встроенный OPcache и запрет загрузки расширений) — патчи в
`freebsd/patches/<версия>/feature-*.patch` (формат git, `-p1`, сверху строки
`Description:`, `Option:` и `Origin:`). Пока их опция configure не задана, они ничего не
меняют; применяются последними, по порядку имён, коммитом «Add the build options of
this fork» и перечислены в README ветки и в заметках релиза. Патч, который перестал
применяться, роняет сборку.

### Временные бэкпорты

Если ветке без поддержки нужно исправление безопасности раньше, чем его выпустит Remi
Collet, патч в формате git (`-p1`, сверху строки `Description:` и `Origin:`) можно
положить в `freebsd/patches/<версия>/backport-*.patch`. Он применяется отдельным
коммитом «Backport security fixes» и отмечается в README ветки. Когда в ветке апстрима
появится то же изменение (патч накладывается в обратную сторону), он пропускается сам, и
ветка возвращается к собственному исправлению апстрима.

### Токен

Workflow делает push секретом репозитория `SYNC_TOKEN`, если он есть: это
fine-grained personal access token для этого репозитория (он может обслуживать и другие
репозитории владельца) с правами **Contents** и **Workflows** на чтение и запись. Иначе
используется стандартный `GITHUB_TOKEN`, но ему может быть запрещено пушить историю
апстрима, которая трогает `.github/workflows`, так что без `SYNC_TOKEN` часть обновлений
веток `freebsd/8.x` могла бы отклоняться.

## Авторы и лицензии

- Этот форк (ветки, выбор патчей портов FreeBSD, тарболы релизов и инструменты):
  [aZsupport.com](https://azsupport.com) — аренда, настройка и администрирование
  выделенных веб-серверов на FreeBSD и Linux с 2004 года, с ежемесячным сопровождением
  (мониторинг 24/7, обновления безопасности, резервные копии) для проектов, где простой
  стоит денег.
- PHP: PHP Group, лицензия PHP (см. `LICENSE` в каждой ветке исходников).
- Бэкпорты безопасности для веток без поддержки: Remi Collet,
  [remicollet/php-src-security](https://github.com/remicollet/php-src-security).
- Патчи портов FreeBSD: мейнтейнеры портов FreeBSD, BSD-2-Clause.
- Инструменты в этой ветке: BSD-2-Clause, см. [LICENSE](LICENSE).
