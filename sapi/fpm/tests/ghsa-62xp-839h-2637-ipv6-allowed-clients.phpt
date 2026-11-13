--TEST--
FPM: GHSA-62xp-839h-2637 - IPv6 listen.allowed_clients compared on all 128 bits
--SKIPIF--
<?php include "skipif.inc";
      @stream_socket_client('tcp://[::1]:0', $errno);
      if ($errno != 111 && $errno != 61) die('skip IPv6 not supported.');
?>
--FILE--
<?php

include "include.inc";

$logfile = dirname(__FILE__).'/php-fpm.log.tmp';
$srcfile = dirname(__FILE__).'/php-fpm.tmp.php';
$port1 = 9000+PHP_INT_SIZE;
$port2 = $port1+1;

/* ::dead:beef shares its first 96 bits with ::1 */
$cfg = <<<EOT
[global]
error_log = $logfile
[exact]
listen = [::]:$port1
listen.allowed_clients = ::1
pm = static
pm.max_children = 1
[prefix]
listen = [::]:$port2
listen.allowed_clients = ::dead:beef
pm = static
pm.max_children = 1
EOT;

file_put_contents($srcfile, '<?php echo "ghsa-62xp-reached\n";');
$fpm = run_fpm($cfg, $tail);
if (is_resource($fpm)) {
    fpm_display_log($tail, 2);
    foreach (array('exact' => $port1, 'prefix' => $port2) as $name => $port) {
        try {
            $req = run_request('[::1]', $port, $srcfile);
            echo $name, ": ", strpos($req, "ghsa-62xp-reached") !== false ? "ok" : "error", "\n";
        } catch (Exception $e) {
            echo $name, ": error\n";
        }
    }
    proc_terminate($fpm);
    stream_get_contents($tail);
    fclose($tail);
    proc_close($fpm);
}

?>
Done
--EXPECTF--
[%s] NOTICE: fpm is running, pid %d
[%s] NOTICE: ready to handle connections
exact: ok
prefix: error
Done
--CLEAN--
<?php
    @unlink(dirname(__FILE__).'/php-fpm.log.tmp');
    @unlink(dirname(__FILE__).'/php-fpm.tmp.php');
?>
