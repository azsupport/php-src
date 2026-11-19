--TEST--
GHSA-85c2-q967-79q5: stale SOAP_GLOBAL(ref_map) pointer with Apache Map (SoapClient, single return value)
--SKIPIF--
<?php if (!extension_loaded('soap')) die('skip soap extension not available'); ?>
--FILE--
<?php
class TestClient extends SoapClient {
    public $response;
    function __doRequest($request, $location, $action, $version, $one_way = 0) {
        return $this->response;
    }
}
$c = new TestClient(null, array('location' => 'test://', 'uri' => 'urn:a'));
$c->response = <<<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<SOAP-ENV:Body>
<testResponse>
<return>
  <map xsi:type="apache:Map" xmlns:apache="http://xml.apache.org/xml-soap">
    <item><key>foo</key><value id="stale"><object>bar</object></value></item>
    <item><key>foo</key><value>baz</value></item>
  </map>
  <stale href="#stale"/>
</return>
</testResponse>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>
XML;
var_dump($c->test());
$c->response = <<<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">
<SOAP-ENV:Body>
<testResponse>
<return id="r"><name>a</name><self href="#r"/></return>
</testResponse>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>
XML;
$r = $c->test();
var_dump($r->name, $r->self === $r, $r->self->self === $r);
echo "Done\n";
--EXPECTF--
object(stdClass)#%d (2) {
  ["map"]=>
  array(1) {
    ["foo"]=>
    string(3) "baz"
  }
  ["stale"]=>
  object(stdClass)#%d (1) {
    ["object"]=>
    string(3) "bar"
  }
}
string(1) "a"
bool(true)
bool(true)
Done
