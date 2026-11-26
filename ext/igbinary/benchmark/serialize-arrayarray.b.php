<?php

// Description: Serialize array of array and unserialize it

require_once 'bench.php';

$b = new Bench('serialize-array-array');

class Obj {
	private $foo = 10;
	public $bar = "test";
	public $i;
}

$array = array();
$inner_array = array(array());
for ($i = 0; $i < 1000; $i++) {
    $array[] = $inner_array;
}

for ($i = 0; $i < 40; $i++) {
	$b->start();
	for ($j = 0; $j < 2000; $j++) {
		$ser = igbinary_serialize($array);
		$unser = igbinary_unserialize($ser);
	}
	$b->stop($j);
	$b->write();
}
