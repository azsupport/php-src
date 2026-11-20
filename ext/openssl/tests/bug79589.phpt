--TEST--
Bug #79589: TLS unexpected EOF failure
--SKIPIF--
<?php
if (!extension_loaded("openssl")) die("skip openssl not loaded");
if (getenv("SKIP_ONLINE_TESTS")) die("skip online test");
?>
--FILE--
<?php

$release = file_get_contents(
    'https://chromedriver.storage.googleapis.com/LATEST_RELEASE',
    false,
    stream_context_create(['ssl' => ['verify_peer'=> false]])
);
echo gettype($release);

?>
--EXPECT--
string
