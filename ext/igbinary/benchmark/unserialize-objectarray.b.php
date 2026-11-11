<?php

// Description: Unserialize object array

require_once 'bench.php';

class Obj {
	private $foo = 10;
	public $bar = "test";
	public $i;
}

call_user_func(function () {
    $b = new Bench('unserialize-object-array');

    $array = array();
    for ($i = 0; $i < 1000; $i++) {
        $o = new Obj();
        $o->i = $i;

        $array[] = $o;
    }
    $ser = igbinary_serialize($array);

    for ($i = 0; $i < 40; $i++) {
        $b->start();
        for ($j = 0; $j < 540; $j++) {
            $array = igbinary_unserialize($ser);
        }
        $b->stop($j);
        $b->write();
    }
});
