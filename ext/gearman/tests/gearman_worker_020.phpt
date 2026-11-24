--TEST--
GearmanWorker::setSSL(), gearman_worker_set_ssl()
--SKIPIF--
<?php
if (!extension_loaded("gearman")) die("skip");
$w = new GearmanWorker();
if (@$w->setSSL(false) === false) die("skip libgearman without worker SSL support");
?>
--FILE--
<?php
$worker = new GearmanWorker();
var_dump($worker->setSSL());
var_dump($worker->setSSL(false));
var_dump($worker->setSSL(true, null, null, null));

$worker2 = gearman_worker_create();
var_dump(gearman_worker_set_ssl($worker2));
var_dump(gearman_worker_set_ssl($worker2, false));

print "OK";
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
bool(true)
bool(true)
OK
