--TEST--
GEARMAN_WORKER_STOP_WAIT_ON_SIGNAL constant and addOptions()
--SKIPIF--
<?php
if (!extension_loaded("gearman")) die("skip");
if (!defined("GEARMAN_WORKER_STOP_WAIT_ON_SIGNAL")) die("skip libgearman too old");
?>
--FILE--
<?php
$worker = new GearmanWorker();
$worker->addOptions(GEARMAN_WORKER_STOP_WAIT_ON_SIGNAL);
$after = $worker->options();
var_dump(($after & GEARMAN_WORKER_STOP_WAIT_ON_SIGNAL) !== 0);
$worker->removeOptions(GEARMAN_WORKER_STOP_WAIT_ON_SIGNAL);
$removed = $worker->options();
var_dump(($removed & GEARMAN_WORKER_STOP_WAIT_ON_SIGNAL) === 0);
print "OK";
?>
--EXPECT--
bool(true)
bool(true)
OK
