<?php

// Description: Unserialize object array

require_once 'bench.php';

class Obj {
	private $foo = 10;
	public $bar = "test";
	public $i;
}

call_user_func(function () {
    $b = new Bench('unserialize-object');

    $o = new Obj();
    $o->i = 2;
    $ser = igbinary_serialize($o);

    for ($i = 0; $i < 40; $i++) {
        $b->start();
        for ($j = 0; $j < 300000; $j++) {
            $o2 = igbinary_unserialize($ser);
        }
        $b->stop($j);
        $b->write();
    }
});
