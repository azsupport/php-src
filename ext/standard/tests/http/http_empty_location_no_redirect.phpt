--TEST--
Empty Location header: not followed (as before in PHP 5.6), nothing read past it
--INI--
allow_url_fopen=1
--FILE--
<?php
$serverCode = <<<'CODE'
$server = stream_socket_server("tcp://127.0.0.1:0", $errno, $errstr);
phpt_notify_server_start($server);

for ($n = 0; $n < 2; $n++) {
    $conn = stream_socket_accept($server, 10);
    if (!$conn) {
        break;
    }
    $req = fgets($conn);
    while (trim(fgets($conn)) !== '') {}
    $uri = explode(' ', $req)[1];
    $body = "uri=$uri";
    $location = $n == 0 ? "Location:" : "Location: ";
    fwrite($conn, "HTTP/1.1 302 Found\r\n$location\r\nContent-Length: " . strlen($body) . "\r\n\r\n$body");
    fclose($conn);
}
CODE;

$clientCode = <<<'CODE'
$ctx = stream_context_create(['http' => ['follow_location' => 1]]);
echo file_get_contents("http://{{ ADDR }}/a/b", false, $ctx), "\n";
var_dump($http_response_header[1]);
echo file_get_contents("http://{{ ADDR }}/c/d", false, $ctx), "\n";
var_dump($http_response_header[1]);
CODE;

include sprintf("%s/ServerClientTestCase.inc", __DIR__);
ServerClientTestCase::getInstance()->run($clientCode, $serverCode);
?>
--EXPECT--
uri=/a/b
string(9) "Location:"
uri=/c/d
string(9) "Location:"
