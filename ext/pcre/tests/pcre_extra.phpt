--TEST--
X (PCRE_EXTRA) modifier
--FILE--
<?php

var_dump(preg_match('/\y/', '\y'));
var_dump(preg_match('/\y/X', '\y'));

?>
--EXPECTF--
int(1)

Warning: preg_match(): Compilation failed: unrecognized character follows \ at offset %r(1|2)%r in %spcre_extra.php on line 4
bool(false)
