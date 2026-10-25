<?php

// Description: Serialize object array

require_once 'bench.php';

class Obj {
	private $foo = 10;
	public $bar = "test";
	public $i;
}

call_user_func(function () {
    $b = new Bench('serialize-object-array');

    $array = array();
    for ($i = 0; $i < 1000; $i++) {
        $o = new Obj();
        $o->i = $i;

        $array[] = $o;
    }

    for ($i = 0; $i < 40; $i++) {
        $b->start();
        for ($j = 0; $j < 2000; $j++) {
            $ser = igbinary_serialize($array);
        }
        $b->stop($j);
        $b->write();
    }
});
