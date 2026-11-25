--TEST--
Worker forking children mid-callback does not cause premature job completion (issue #40)
--SKIPIF--
<?php
require_once('skipif.inc');
require_once('skipifconnect.inc');
?>
--FILE--
<?php
require_once('connect.inc');

$func = 'issue40_' . getmypid() . '_' . time();

/* Worker in a child so we can be the client in the parent */
$wpid = pcntl_fork();
if ($wpid === -1) {
    die("FAIL: could not fork worker");
}
if ($wpid === 0) {
    $w = new GearmanWorker();
    if ($w->addServer($host, $port) !== true) exit(2);
    $w->setTimeout(10000);
    if ($w->addFunction($func, function($job) {
        /* Fork two children inside the callback */
        $children = [];
        for ($i = 0; $i < 2; $i++) {
            $pid = pcntl_fork();
            if ($pid === -1) {
                continue;
            } elseif ($pid === 0) {
                usleep(100000);
                exit(0);
            }
            $children[] = $pid;
        }
        foreach ($children as $pid) {
            pcntl_waitpid($pid, $s, 0);
        }
        return "completed";
    }) !== true) exit(2);
    $w->work();
    exit(0);
}

/* Give the worker time to register */
usleep(200000);

/* Submit a foreground job and check the result */
$client = new GearmanClient();
if ($client->addServer($host, $port) !== true) {
    die("FAIL: could not add server");
}
$client->setTimeout(15000);
$result = $client->doNormal($func, 'test_payload');
$rc = $client->returnCode();

pcntl_waitpid($wpid, $ws, 0);

if ($rc === GEARMAN_SUCCESS && $result === "completed") {
    echo "PASS" . PHP_EOL;
} else {
    echo "FAIL: rc=$rc result=" . var_export($result, true) . PHP_EOL;
}
--EXPECT--
PASS
