--TEST--
Worker exit() mid-callback returns job to queue (issue #26)
--SKIPIF--
<?php
require_once('skipif.inc');
require_once('skipifconnect.inc');
?>
--FILE--
<?php
require_once('connect.inc');

$func = 'issue26_' . getmypid() . '_' . time();

/* Submit a background job */
$client = new GearmanClient();
if ($client->addServer($host, $port) !== true) {
    die("FAIL: could not add server");
}
$handle = $client->doBackground($func, 'test_payload');
if ($client->returnCode() !== GEARMAN_SUCCESS) {
    die("FAIL: could not submit job");
}

/* Worker 1: grabs the job and exit()s without completing it */
$pid1 = pcntl_fork();
if ($pid1 === -1) {
    die("FAIL: could not fork worker 1");
}
if ($pid1 === 0) {
    $w = new GearmanWorker();
    if ($w->addServer($host, $port) !== true) exit(2);
    $w->setTimeout(10000);
    if ($w->addFunction($func, function($job) { exit(1); }) !== true) exit(2);
    $w->work();
    exit(0);
}
pcntl_waitpid($pid1, $status1, 0);
if (!pcntl_wifexited($status1) || pcntl_wexitstatus($status1) !== 1) {
    die("FAIL: worker 1 did not exit from inside the callback");
}

/* Brief pause for gearmand to detect the disconnect */
usleep(500000);

/* Worker 2: should receive the retried job */
$pid2 = pcntl_fork();
if ($pid2 === -1) {
    die("FAIL: could not fork worker 2");
}
if ($pid2 === 0) {
    $w = new GearmanWorker();
    if ($w->addServer($host, $port) !== true) exit(3);
    $w->setTimeout(10000);
    if ($w->addFunction($func, function($job) {
        echo "payload: " . $job->workload() . PHP_EOL;
        return "done";
    }) !== true) exit(3);
    $ret = $w->work();
    exit($ret ? 0 : 2);
}
pcntl_waitpid($pid2, $status2, 0);

if (!pcntl_wifexited($status2)) {
    echo "FAIL: worker 2 did not exit normally" . PHP_EOL;
} elseif (pcntl_wexitstatus($status2) === 0) {
    echo "PASS" . PHP_EOL;
} else {
    echo "FAIL: job was not retried" . PHP_EOL;
}
--EXPECT--
payload: test_payload
PASS
