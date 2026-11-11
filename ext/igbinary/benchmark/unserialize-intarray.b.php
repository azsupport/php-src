<?php

// Description: Unserialize array of small integers
// NOTE: Unserialization of positive integers in the range 0-65536 is specifically optimized.
// (they're common as counts, offsets, array indexes, etc.)

require_once 'bench.php';

call_user_func(function () {
    $b = new Bench('unserialize-intarray');

    $array = array();
    for ($i = 0; $i < 256; $i++) {
        $array[] = $i;
    }
    $ser = igbinary_serialize($array);

    for ($i = 0; $i < 40; $i++) {
        $b->start();
        for ($j = 0; $j < 50000; $j++) {
            $array = igbinary_unserialize($ser);
        }
        $b->stop($j);
        $b->write();
    }
});
