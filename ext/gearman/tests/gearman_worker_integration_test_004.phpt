--TEST--
Worker callback exception message is sent to gearmand (issue #21)
--SKIPIF--
<?php
require_once('skipif.inc');
require_once('skipifconnect.inc');
?>
--FILE--
<?php
require_once('connect.inc');

$func = 'issue21_' . getmypid() . '_' . time();

$wpid = pcntl_fork();
if ($wpid === -1) {
    die("FAIL: could not fork");
}
if ($wpid === 0) {
    $w = new GearmanWorker();
    if ($w->addServer($host, $port) !== true) exit(2);
    $w->setTimeout(10000);
    $w->addFunction($func, function($job) {
        throw new RuntimeException("test exception message");
    });
    /* work() will propagate the exception after sending it to gearmand */
    try {
        $w->work();
    } catch (\Throwable $e) {
        /* expected */
    }
    exit(0);
}

usleep(200000);

$received = null;

$client = new GearmanClient();
if ($client->addServer($host, $port) !== true) {
    die("FAIL: could not add server");
}
$client->setExceptionCallback(function($task) use (&$received) {
    $received = $task->data();
    return GEARMAN_WORK_EXCEPTION;
});

$client->addTask($func, 'payload');
$client->runTasks();

pcntl_waitpid($wpid, $ws, 0);

if ($received === "test exception message") {
    echo "PASS" . PHP_EOL;
} else {
    echo "FAIL: received=" . var_export($received, true) . PHP_EOL;
}
--EXPECT--
PASS
