<?php
// build-test-smoke.php - quick checks of a fresh PHP build (5.6 to 8.4), run by
// tools/build-test.sh: php -n [-d zend_extension=.../opcache.so] build-test-smoke.php <source dir>
// Prints one line per check: "ok <name>: <detail>", "FAIL <name>: <detail>" or
// "skip <name>: <reason>". Uses the network for DNS and TLS checks.

error_reporting(E_ALL);
// Buffer the output, so that the session functions still see no headers sent.
ob_start();
$src = isset($argv[1]) ? $argv[1] : getcwd();
$tmp = sys_get_temp_dir() . '/build-test-smoke-' . getmypid();
@mkdir($tmp);

function check($name, $ok, $detail = '')
{
    echo ($ok === null ? 'skip ' : ($ok ? 'ok ' : 'FAIL ')), $name, $detail !== '' ? ': ' . $detail : '', "\n";
    reset_error();
}
function info($name, $detail)
{
    echo 'info ', $name, ': ', $detail, "\n";
    reset_error();
}
function last_error()
{
    $e = error_get_last();
    $m = $e ? $e['message'] : '';
    if (function_exists('openssl_error_string')) {
        while (($o = openssl_error_string()) !== false) {
            $m .= ($m === '' ? '' : '; ') . $o;
        }
    }
    return $m;
}
function reset_error()
{
    if (function_exists('error_clear_last')) {
        error_clear_last();
    } else {
        @trigger_error('', E_USER_NOTICE);
    }
    if (function_exists('openssl_error_string')) {
        while (openssl_error_string() !== false) {
        }
    }
}

// Parser: detailed syntax errors.
file_put_contents("$tmp/perr.php", "<?php if { echo 1; }\n");
$out = array();
exec(escapeshellarg(PHP_BINARY) . ' -n -l ' . escapeshellarg("$tmp/perr.php") . ' 2>&1', $out);
$msg = trim(implode(' ', $out));
check('parse errors', strpos($msg, 'unexpected') !== false, substr($msg, 0, 80));
$r = @parse_ini_string("a = 1\nb = = 2\n");
check('INI parse errors', strpos(last_error(), 'unexpected') !== false, last_error());
if (PHP_MAJOR_VERSION == 5) {
    check('token numbers as in php.net 5.6.40', T_VARIABLE == 312 && T_OPEN_TAG == 376 && T_POW == 300,
        'T_VARIABLE ' . T_VARIABLE . ', T_OPEN_TAG ' . T_OPEN_TAG . ', T_POW ' . T_POW);
}

// Network: name resolution, IPv6 sockets, TLS.
$ip = gethostbyname('github.com');
check('DNS', $ip !== 'github.com', "github.com = $ip");
$s = @stream_socket_server('tcp://[::1]:0', $en, $es);
check('IPv6 (getaddrinfo)', (bool)$s, $s ? 'listening on [::1]' : $es);
$ctx = stream_context_create(array('ssl' => array('verify_peer' => false, 'verify_peer_name' => false)));
foreach (array('tls', 'ssl') as $proto) {
    $c = @stream_socket_client("$proto://github.com:443", $en, $es, 15, STREAM_CLIENT_CONNECT, $ctx);
    check("$proto://", (bool)$c, $c ? 'connected to github.com:443' : "$es " . last_error());
    if ($c) {
        fclose($c);
    }
}
$c = @stream_socket_client('tcp://github.com:443', $en, $es, 15, STREAM_CLIENT_CONNECT, $ctx);
$r = $c ? @stream_socket_enable_crypto($c, true, STREAM_CRYPTO_METHOD_TLS_CLIENT) : false;
check('enable_crypto(STREAM_CRYPTO_METHOD_TLS_CLIENT)', (bool)$r, $r ? 'TLS on tcp://github.com:443' : last_error());
$verify = stream_context_create(array('ssl' => array('cafile' => '/etc/ssl/cert.pem')));
$html = @file_get_contents('https://github.com/', false, $verify);
check('https:// with certificate check', $html !== false && strlen($html) > 1000, $html === false ? last_error() : strlen($html) . ' bytes');

// curl: the bundled libcurl (--with-curl=bundled; build-test.sh sets CURL_BUNDLED to
// its version): that version, no libcurl.so linked, its symbols not exported, the
// rare protocols off, the features of the FreeBSD port on, HTTPS with the CA path.
if (function_exists('curl_version')) {
    $cv = curl_version();
    $bundled = (string)getenv('CURL_BUNDLED');
    $detail = 'libcurl ' . $cv['version'] . ', ' . $cv['ssl_version'];
    if ($bundled !== '') {
        check("curl: bundled $bundled", $cv['version'] === $bundled, $detail);
        $ldd = array();
        exec('ldd ' . escapeshellarg(PHP_BINARY) . ' 2>/dev/null', $ldd);
        $so = preg_grep('/libcurl\.so/', $ldd);
        check('curl: no libcurl.so linked', $ldd ? !$so : null, $ldd ? ($so ? trim(implode(' ', $so)) : 'ldd shows none') : 'no ldd');
        $nm = array();
        exec('nm -D --defined-only ' . escapeshellarg(PHP_BINARY) . ' 2>/dev/null', $nm);
        $exp = preg_grep('/ T curl_(easy|multi|global|share|url|ws)_/', $nm);
        check('curl: libcurl symbols not exported', $nm ? !$exp : null, $nm ? ($exp ? count($exp) . ' exported, e.g. ' . trim(reset($exp)) : 'none exported') : 'no nm');
        $off = array_values(array_intersect($cv['protocols'], array('dict', 'gopher', 'gophers', 'ipfs', 'ipns',
            'mqtt', 'mqtts', 'rtsp', 'telnet', 'tftp', 'ldap', 'ldaps', 'scp', 'sftp', 'smb', 'smbs')));
        check('curl: rare protocols off', !$off, $off ? 'has ' . implode(' ', $off) : implode(' ', $cv['protocols']));
        // CURL_VERSION_* bits of curl.h (the PHP constants differ between versions)
        $bits = array('SSL' => 4, 'libz' => 8, 'AsynchDNS' => 128, 'IDN' => 1024, 'HTTP2' => 65536,
            'PSL' => 1048576, 'brotli' => 8388608, 'alt-svc' => 16777216, 'zstd' => 67108864, 'HSTS' => 268435456);
        $lack = array();
        foreach ($bits as $n => $b) {
            if (!($cv['features'] & $b)) {
                $lack[] = $n;
            }
        }
        check('curl: features of the port', !$lack, $lack ? 'missing ' . implode(' ', $lack) : implode(' ', array_keys($bits)));
    } else {
        info('curl', $detail . ' (not the bundled one)');
    }
    $ch = curl_init('https://github.com/');
    // 3 = CURL_HTTP_VERSION_2_0, 0 bytes of CURLOPT_ENCODING: every encoding curl has
    curl_setopt_array($ch, array(CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 20,
        CURLOPT_HTTP_VERSION => 3, CURLOPT_ENCODING => ''));
    $body = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $hv = defined('CURLINFO_HTTP_VERSION') ? ', HTTP version ' . curl_getinfo($ch, CURLINFO_HTTP_VERSION) : '';
    check('curl: https:// with certificate check', $body !== false && $code == 200,
        $body === false ? curl_error($ch) : strlen($body) . " bytes, status $code$hv");
    curl_close($ch);
}

// OpenSSL: legacy algorithms, openssl_seal() default, CSR public key.
if (extension_loaded('openssl')) {
    // With --with-openssl-legacy-provider (all versions here, the option of PHP 8.4;
    // build-test.sh sets OPENSSL_LEGACY=1) PHP loads the OpenSSL 3 legacy provider;
    // without it the result is only shown.
    $legacy_required = getenv('OPENSSL_LEGACY') === '1';
    $methods = array_map('strtolower', openssl_get_cipher_methods());
    $legacy = array('rc4', 'bf-cbc', 'des-cbc', 'rc2-cbc', 'cast5-cbc', 'des-ede3-cbc');
    $missing = array_diff($legacy, $methods);
    $detail = OPENSSL_VERSION_TEXT . ($missing ? '; missing ' . implode(' ', $missing) : '; all listed');
    if ($legacy_required) {
        check('OpenSSL legacy ciphers listed', !$missing, $detail);
    } else {
        info('OpenSSL legacy ciphers (built without --with-openssl-legacy-provider)', $detail);
    }
    foreach (array('bf-cbc' => 8, 'des-cbc' => 8, 'rc2-cbc' => 8, 'cast5-cbc' => 8, 'rc4' => 0) as $m => $ivlen) {
        if (!$legacy_required && !in_array($m, $methods)) {
            continue;
        }
        $iv = str_repeat("\1", $ivlen);
        $enc = @openssl_encrypt('secret data', $m, 'k3y-k3y-k3y-k3y!', OPENSSL_RAW_DATA, $iv);
        $dec = $enc === false ? false : @openssl_decrypt($enc, $m, 'k3y-k3y-k3y-k3y!', OPENSSL_RAW_DATA, $iv);
        check("openssl_encrypt $m", $dec === 'secret data', $dec === 'secret data' ? 'round trip' : last_error());
    }
    $md4 = @openssl_digest('abc', 'md4');
    if ($legacy_required || $md4 !== false) {
        check('openssl_digest md4', $md4 === 'a448017aaf21d8525fc10ae87aa6729d', $md4 === false ? last_error() : (string)$md4);
    }
    $key = openssl_pkey_new(array('private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA));
    $det = openssl_pkey_get_details($key);
    $pub = openssl_pkey_get_public($det['key']);
    if (PHP_MAJOR_VERSION < 8 && ($legacy_required || in_array('rc4', $methods))) {
        $ok = openssl_seal('sealed text', $sealed, $ekeys, array($pub));
        $opened = null;
        if ($ok) {
            openssl_open($sealed, $opened, $ekeys[0], $key);
        }
        check('openssl_seal() default cipher (RC4)', $opened === 'sealed text', $ok ? 'sealed and opened' : last_error());
    }
    $csr = openssl_csr_new(array('commonName' => 'build-test'), $key);
    $cpk = $csr ? openssl_csr_get_public_key($csr) : false;
    $cdet = $cpk ? openssl_pkey_get_details($cpk) : array();
    check('openssl_csr_get_public_key() public part only', $cpk && isset($cdet['rsa']) && !isset($cdet['rsa']['d']),
        $cpk ? (isset($cdet['rsa']['d']) ? 'private exponent present' : 'public key') : last_error());
} else {
    check('openssl', null, 'not built');
}

// GD with FreeType.
if (extension_loaded('gd')) {
    $font = "$src/ext/gd/tests/Tuffy.ttf";
    if (is_file($font) && function_exists('imagettftext')) {
        $im = imagecreatetruecolor(300, 100);
        $box = imagettftext($im, 24, 0, 10, 50, imagecolorallocate($im, 255, 255, 255), $font, 'ABCDEF');
        check('GD imagettftext', is_array($box) && $box[2] > $box[0] && $box[1] > $box[7], is_array($box) ? implode(',', $box) : last_error());
    } else {
        check('GD imagettftext', false, function_exists('imagettftext') ? "no $font" : 'no FreeType support');
    }
    $im = imagecreatetruecolor(16, 16);
    ob_start();
    imagepng($im);
    $png = ob_get_clean();
    check('GD PNG', @imagecreatefromstring($png) !== false, strlen($png) . ' bytes');
    ob_start();
    imagejpeg($im);
    $jpg = ob_get_clean();
    check('GD JPEG', @imagecreatefromstring($jpg) !== false, strlen($jpg) . ' bytes');
    if (function_exists('imagewebp')) {
        ob_start();
        imagewebp($im);
        check('GD WebP', strlen(ob_get_clean()) > 0);
    }
}

// XML.
if (extension_loaded('libxml') && function_exists('simplexml_load_string')) {
    libxml_use_internal_errors(true);
    simplexml_load_string('<a><b></a>');
    $errs = libxml_get_errors();
    check('libxml errors', count($errs) > 0, LIBXML_DOTTED_VERSION . ': ' . (count($errs) ? trim($errs[0]->message) : 'none'));
    libxml_clear_errors();
}
if (extension_loaded('dom')) {
    $d = new DOMDocument();
    $d->loadXML('<!DOCTYPE a [<!ENTITY e "x"><!ENTITY f "y">]><a/>');
    $n = array();
    foreach ($d->doctype->entities as $k => $v) {
        $n[] = $k;
    }
    sort($n);
    check('DOM entity iteration', $n === array('e', 'f'), implode(',', $n));
}
if (function_exists('xmlrpc_encode_request')) {
    check('xmlrpc', strpos(xmlrpc_encode_request('m', array(1)), '<methodName>m</methodName>') !== false);
}

// Strings and data.
if (extension_loaded('mbstring')) {
    check('mbstring', mb_strtoupper("\xc3\xa9t\xc3\xa9", 'UTF-8') === "\xc3\x89T\xc3\x89");
    if (in_array('UTF-8-Mobile#DOCOMO', mb_list_encodings())) {
        check('mbstring UTF-8-Mobile', mb_convert_encoding("caf\xc3\xa9", 'UTF-8-Mobile#DOCOMO', 'UTF-8') === "caf\xc3\xa9");
    }
}
if (function_exists('iconv')) {
    check('iconv', @iconv('UTF-8', 'ISO-8859-1//TRANSLIT', "caf\xc3\xa9") === "caf\xe9", ICONV_IMPL . ' ' . ICONV_VERSION);
}
if (class_exists('finfo')) {
    $f = new finfo(FILEINFO_NONE);
    $t = $f->buffer("#!/bin/sh\necho hi\n");
    check('fileinfo', stripos($t, 'shell script') !== false, $t);
}
if (function_exists('gzcompress')) {
    $data = str_repeat('abc', 1000);
    check('zlib', gzuncompress(gzcompress($data)) === $data, 'zlib.output_compression=' . var_export(ini_get('zlib.output_compression'), true));
}
if (function_exists('mcrypt_encrypt')) {
    $k = '0123456789abcdef';
    $iv = str_repeat("\0", 8);
    $e = @mcrypt_encrypt(MCRYPT_BLOWFISH, $k, 'mcrypt text', MCRYPT_MODE_CBC, $iv);
    check('mcrypt', rtrim(@mcrypt_decrypt(MCRYPT_BLOWFISH, $k, $e, MCRYPT_MODE_CBC, $iv), "\0") === 'mcrypt text');
}
check('crypt blowfish', crypt('rasmuslerdorf', '$2y$07$usesomesillystringforsalt$') === '$2y$07$usesomesillystringfore2uDLvp1Ii2e./U9C8sBjqp8I90dH6hi');
check('crypt sha512', crypt('rasmuslerdorf', '$6$rounds=5000$usesomesillystri$') === '$6$rounds=5000$usesomesillystri$D4IrlXatmP7rx3P3InaxBeoomnAihCKRVQP22JZ6EY47Wc6BkroIuUUBOov1i.S5KPgErtP/EN5mcO.ChWQW21');
if (defined('PASSWORD_ARGON2ID')) {
    $h = password_hash('pw', PASSWORD_ARGON2ID);
    check('password_hash argon2id', password_verify('pw', $h), substr($h, 0, 20));
}
if (extension_loaded('intl')) {
    check('intl', class_exists('IntlDateFormatter'), defined('INTL_ICU_VERSION') ? 'ICU ' . INTL_ICU_VERSION : '');
}
check('pcre', preg_match('/\p{Lu}/u', "\xc3\x89") === 1, PCRE_VERSION);

// Files, sessions, streams.
check('readdir', count(scandir('/')) > 3);
if (function_exists('curl_init')) {
    $ch = curl_init('https://github.com/');
    $fp = fopen('php://memory', 'w+');
    curl_setopt($ch, CURLOPT_FILE, $fp);
    curl_setopt($ch, CURLOPT_CAINFO, '/etc/ssl/cert.pem');
    $ok = curl_exec($ch);
    rewind($fp);
    $len = strlen(stream_get_contents($fp));
    check('curl into php://memory (fopencookie)', $ok && $len > 1000, $ok ? "$len bytes" : curl_error($ch));
}
if (function_exists('session_start')) {
    session_save_path($tmp);
    ini_set('session.use_cookies', '0');
    ini_set('session.cache_limiter', '');
    session_id('buildtest');
    session_start();
    $_SESSION['n'] = 42;
    session_write_close();
    $_SESSION = array();
    session_start();
    check('session files', isset($_SESSION['n']) && $_SESSION['n'] == 42);
    session_destroy();
}
// Bundled PECL extensions (built when enabled), against local servers if they run.
function port_open($port)
{
    $f = @fsockopen('127.0.0.1', $port, $en, $es, 2);
    if ($f) {
        fclose($f);
        return true;
    }
    return false;
}
if (class_exists('Redis')) {
    if (port_open(6379)) {
        $r = new Redis();
        $r->connect('127.0.0.1', 6379, 2);
        $r->set('build-test', 'redis value');
        check('redis', $r->get('build-test') === 'redis value', 'phpredis ' . phpversion('redis') . ', set/get');
    } else {
        check('redis', null, 'phpredis ' . phpversion('redis') . ' loaded, no server on 6379');
    }
}
if (class_exists('Memcached')) {
    if (port_open(11211)) {
        $m = new Memcached();
        $m->addServer('127.0.0.1', 11211);
        $m->set('build-test', 'memcached value');
        check('memcached', $m->get('build-test') === 'memcached value', 'memcached ' . phpversion('memcached') . ', set/get');
    } else {
        check('memcached', null, 'memcached ' . phpversion('memcached') . ' loaded, no server on 11211');
    }
}
if (class_exists('Memcache')) {
    if (port_open(11211)) {
        $m = new Memcache();
        $m->connect('127.0.0.1', 11211);
        $m->set('build-test-2', 'memcache value');
        check('memcache', $m->get('build-test-2') === 'memcache value', 'memcache ' . phpversion('memcache') . ', set/get');
    } else {
        check('memcache', null, 'memcache ' . phpversion('memcache') . ' loaded, no server on 11211');
    }
}
if (class_exists('Imagick')) {
    $im = new Imagick();
    $im->newImage(8, 8, new ImagickPixel('red'));
    $im->setImageFormat('png');
    $blob = $im->getImageBlob();
    $v = Imagick::getVersion();
    check('imagick', substr($blob, 1, 3) === 'PNG', 'imagick ' . phpversion('imagick') . ', ' . $v['versionString']);
}
if (class_exists('Gmagick')) {
    $g = new Gmagick();
    $g->newImage(8, 8, 'red', 'png');
    check('gmagick', substr($g->getImageBlob(), 1, 3) === 'PNG', 'gmagick ' . phpversion('gmagick'));
}
if (class_exists('ExcimerProfiler')) {
    $p = new ExcimerProfiler();
    $p->setPeriod(0.001);
    $p->setEventType(EXCIMER_REAL);
    $p->start();
    $t = microtime(true);
    $x = 0;
    while (microtime(true) - $t < 0.05) {
        $x++;
    }
    $p->stop();
    $n = count($p->getLog());
    check('excimer', $n > 0, 'excimer ' . phpversion('excimer') . ", $n samples in 50 ms");
}
if (function_exists('igbinary_serialize')) {
    $data = array('a' => 1, 'b' => array(1.5, 'x', true), 'c' => null);
    check('igbinary', igbinary_unserialize(igbinary_serialize($data)) === $data, 'igbinary ' . phpversion('igbinary'));
    if (class_exists('Redis') && defined('Redis::SERIALIZER_IGBINARY') && port_open(6379)) {
        $r = new Redis();
        $r->connect('127.0.0.1', 6379, 2);
        $r->setOption(Redis::OPT_SERIALIZER, Redis::SERIALIZER_IGBINARY);
        $r->set('build-test-ig', $data);
        check('redis with igbinary', $r->get('build-test-ig') === $data, 'serializer igbinary');
    }
    if (class_exists('Memcached') && defined('Memcached::HAVE_IGBINARY') && Memcached::HAVE_IGBINARY && port_open(11211)) {
        $m = new Memcached();
        $m->addServer('127.0.0.1', 11211);
        $m->setOption(Memcached::OPT_SERIALIZER, Memcached::SERIALIZER_IGBINARY);
        $m->set('build-test-ig', $data);
        check('memcached with igbinary', $m->get('build-test-ig') === $data, 'serializer igbinary');
    }
}
$sw = extension_loaded('openswoole') ? 'openswoole' : (extension_loaded('swoole') ? 'swoole' : '');
if ($sw !== '') {
    $res = array();
    Swoole\Coroutine\run(function () use (&$res) {
        $chan = new Swoole\Coroutine\Channel(2);
        Swoole\Coroutine::create(function () use ($chan) {
            usleep(10000);
            $chan->push('from coroutine');
        });
        $res[] = $chan->pop(2.0);
    });
    check($sw, $res === array('from coroutine'), "$sw " . phpversion($sw) . ', coroutine and channel');
    if (extension_loaded('openssl')) {
        check("$sw with openssl", defined('SWOOLE_SSL'), 'SWOOLE_SSL defined');
    }
}
// mysqlnd uses OpenSSL itself (RSA for sha256 and caching_sha2 auth) when PHP is
// built --with-openssl; an extension that resets PHP_OPENSSL in configure breaks it.
if (extension_loaded('mysqlnd') && extension_loaded('openssl')) {
    ob_start();
    $re = new ReflectionExtension('mysqlnd');
    $re->info();
    $mi = ob_get_clean();
    if (preg_match('/extended SSL => (.+)/', $mi, $mm)) {
        check('mysqlnd extended SSL', trim($mm[1]) === 'supported', trim($mm[1]));
    }
}
check('opcache loaded', extension_loaded('Zend OPcache') ? true : null, extension_loaded('Zend OPcache') ? '' : 'not loaded');

foreach (glob("$tmp/*") as $f) {
    @unlink($f);
}
@rmdir($tmp);
ob_end_flush();
