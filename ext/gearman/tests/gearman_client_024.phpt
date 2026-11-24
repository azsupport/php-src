--TEST--
GearmanClient::setSSL(), gearman_client_set_ssl()
--SKIPIF--
<?php
if (!extension_loaded("gearman")) die("skip");
if (!method_exists('GearmanClient', 'setSSL')) die("skip libgearman without SSL support");
?>
--FILE--
<?php
$client = new GearmanClient();
var_dump($client->setSSL());
var_dump($client->setSSL(false));
var_dump($client->setSSL(true, null, null, null));

$client2 = gearman_client_create();
var_dump(gearman_client_set_ssl($client2));
var_dump(gearman_client_set_ssl($client2, false));

print "OK";
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
OK
