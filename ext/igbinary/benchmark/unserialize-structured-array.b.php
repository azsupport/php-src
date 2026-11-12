<?php

// Description: Unserialize structured array

require_once 'bench.php';

call_user_func(function () {
    $b = new Bench('unserialize-structured-array');

    $array = [];
    for ($i = 0; $i < 1000; $i++) {
        $array[] = ['key' => "da string $i", 'flag' => $i % 2];
    }
    $ser = igbinary_serialize($array);

    for ($i = 0; $i < 40; $i++) {
        $b->start();
        for ($j = 0; $j < 5800; $j++) {
            $array = igbinary_unserialize($ser);
        }
        $b->stop($j);
        $b->write();
    }
});
