--TEST--
DatePeriod::__construct() with a DateInterval or DateTime that was not initialized
--INI--
date.timezone=UTC
--FILE--
<?php
class I extends DateInterval { function __construct() {} }
class D extends DateTime { function __construct() {} }

foreach (array(
	function () { return new DatePeriod(new DateTime('2026-01-01'), new I, 1); },
	function () { return new DatePeriod(new D, new DateInterval('P1D'), 1); },
	function () { return new DatePeriod(new DateTime('2026-01-01'), new DateInterval('P1D'), new D); },
) as $f) {
	try {
		$f();
		echo "no exception\n";
	} catch (Exception $e) {
		echo get_class($e), ": ", $e->getMessage(), "\n";
	}
}
/* the error handling mode of the constructor must not leak out of it */
echo $undefined_variable, "after\n";
?>
--EXPECTF--
Exception: DatePeriod::__construct(): The DateInterval object has not been correctly initialized by its constructor
Exception: DatePeriod::__construct(): The DateTimeInterface object has not been correctly initialized by its constructor
Exception: DatePeriod::__construct(): The DateTimeInterface object has not been correctly initialized by its constructor

Notice: Undefined variable: undefined_variable in %s on line %d
after
