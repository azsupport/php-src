<?php
/*
Serialization performance depends on the `igbinary.compact_strings` option which enables duplicate string tracking.
String are inserted to a hash table, which adds some overhead when serializing.
In usual scenarios this does not have much of an impact,
because the typical usage pattern is "serialize rarely, unserialize often".
With the `compact_strings` option enabled,
igbinary is usually a bit slower than the standard serializer.
Without it, igbinary is a bit faster.

An example run is below, where 64-bit php is compiled on Linux with '-O2',
and igbinary/msgpack are compiled as shared extensions, with their default CFLAGS.

Running with PHP 7.4.11-dev
igbinary version=3.2.2
opcache is enabled
igbinary.compact_strings=1
Smaller times are better (the iterations completed faster)

                               |            |   igbinary time(seconds)                         |    default time(seconds)                         |    msgpack time(seconds)
                     Benchmark | iterations |    serialize unserialize ser_bytes unser_speedup |    serialize unserialize ser_bytes unser_speedup |    serialize unserialize ser_bytes unser_speedup
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
                 list_of_lists |       2000 |      0.15064     0.15876     22316        2.674x |      0.25412     0.42447     52786        1.000x |      0.34359     0.29189      8269        1.454x
                    scalar_int |    3000000 |      0.20974     0.19293         6        1.180x |      0.17139     0.22772         4        1.000x |      0.22638     0.25168         1        0.905x
                  scalar_array |      10000 |      0.15353     0.11325     11223        5.464x |      1.09133     0.61879     20633        1.000x |      0.12545     0.19745      8225        3.134x
                        object |     300000 |      0.07174     0.08972        58        2.154x |      0.05573     0.19324        87        1.000x |      0.06844     0.17768        49        1.088x
                      stdClass |     300000 |      0.07428     0.09715        51        1.291x |      0.05457     0.12541        79        1.000x |      0.06821     0.15103        41        0.830x
 distinct_stringtostring_array |        600 |      0.31830     0.20146    307546        1.250x |      0.11900     0.25178    371679        1.000x |      0.08651     0.27759    304469        0.907x
   array_of_reusedkey_stdClass |       1000 |      0.10825     0.18101     18533        3.219x |      0.20980     0.58272     91789        1.000x |      0.16887     0.47627     48619        1.223x
     array_of_reusedkey_object |       1000 |      0.16439     0.18577     25423        3.129x |      0.19977     0.58133     98679        1.000x |      0.16267     0.48471     55509        1.199x
      array_of_reusedkey_array |       1000 |      0.08211     0.07175     16517        2.245x |      0.09531     0.16108     70789        1.000x |      0.13455     0.20111     30619        0.801x
 */

if (!function_exists('hrtime')) {
	function hrtime(bool $as_seconds = false) {
		return microtime($as_seconds);
	}
}

function from_callable($c): Closure {
	return Closure::fromCallable($c);
}

class MyObject {
	private $longPropertyName = 10;
	public $bar = "test";
	public $i;
	public function __construct($longPropertyName, $bar, $i) {
		$this->longPropertyName = $longPropertyName;
		$this->bar = $bar;
		$this->i = $i;
	}
}

class Example {
	public $data;
	/** @var int */
	public $iterations;
	public function __construct($data, int $iterations) {
		$this->data = $data;
		$this->iterations = $iterations;
	}
}

class Result {
	/** @var float */
	public $serialize_time;
	/** @var float */
	public $unserialize_time;
	/** @var int the length of the serialized data */
	public $serialized_bytes;
	public function __construct(float $serialize_time, float $unserialize_time, int $serialized_bytes) {
		$this->serialize_time = $serialize_time;
		$this->unserialize_time = $unserialize_time;
		$this->serialized_bytes = $serialized_bytes;
	}
}

class Benchmark {
	const NANOSECONDS_PER_SECOND = 1000000000;
	public static function run(Closure $serialize, Closure $unserialize, Example $example): Result {
		$iterations = (int)$example->iterations;
		$data = $example->data;
		$t1 = hrtime(true);
		for ($i = 0; $i < $iterations; $i++) {
			$ser = $serialize($data);
		}
		$t2 = hrtime(true);
		for ($i = 0; $i < $iterations; $i++) {
			$result = $unserialize($ser);
		}
		$t3 = hrtime(true);
		return new Result(($t2 - $t1) / self::NANOSECONDS_PER_SECOND, ($t3 - $t2) / self::NANOSECONDS_PER_SECOND, strlen($ser));
	}

	public static function createArrayArray() {
		srand(13333);
		$data = [];
		for ($i = 0; $i < 1000; $i++) {
			$part = [];
			for ($j = 0; $j < rand() % 20; $j++) {
				$part[] = rand() % 300;
			}
			$data[] = $part;
		}
		return $data;
	}

	public static function createObjectArray(): array {
		$array = [];
		for ($i = 0; $i < 1000; $i++) {
			$o = new MyObject($i, "test$i", null);

			$array[] = $o;
		}
		return $array;
	}

	public static function createObject(): MyObject {
		return new MyObject(10, 1234, true);
	}

	public static function createScalarArray(): array {
		$array = [];
		for ($i = 0; $i < 1000; $i++) {
			switch ($i % 4) {
			case 0:
				$array[] = "da string " . $i;
				break;
			case 1:
				$array[] = 1.31 * $i;
				break;
			case 2:
				$array[] = rand(0, PHP_INT_MAX);
				break;
			case 3:
				$array[] = (bool)($i & 1);
				break;
			}
		}
		return $array;
	}

	public static function createStdClassArray(): array {
		$array = [];
		for ($i = 0; $i < 1000; $i++) {
			$array = [];
			for ($i = 0; $i < 1000; $i++) {
				$o = new MyObject(10, $i, $i % 2 != 0);
				$array[] = $o;
			}
		}
		return $array;
	}

	public static function createReusedArrayArray(): array {
		$array = [];
		for ($i = 0; $i < 1000; $i++) {
			$array = [];
			for ($i = 0; $i < 1000; $i++) {
				$o = ['longPropertyName' => 10, 'i' => $i, 'isOdd' => $i % 2 != 0];
				$array[] = $o;
			}
		}
		return $array;
	}

	/**
	 * @return array<string, Example>
	 */
	public static function createExamples(): array {
		return [
			'list_of_lists' => new Example(self::createArrayArray(), 2000),
			'scalar_int' => new Example(1, 3000000),
			'scalar_array' => new Example(self::createScalarArray(), 10000),
			'object' => new Example(self::createObject(), 300000),
			'stdClass' => new Example((object)['longPropertyName' => 10, 'bar' => 'test', 'i' => null], 300000),
			'distinct_stringtostring_array' => new Example(unserialize(file_get_contents(__DIR__ . '/l10n-en.ser')), 600),
			'array_of_reusedkey_stdClass' => new Example(self::createStdClassArray(), 1000),
			'array_of_reusedkey_object' => new Example(self::createObjectArray(), 1000),
			'array_of_reusedkey_array' => new Example(self::createReusedArrayArray(), 1000),
		];
	}

	public static function createSerializersToBenchmark(): array
	{
		$igbinary_serialize = from_callable('igbinary_serialize');
		$igbinary_unserialize = from_callable('igbinary_unserialize');
		$serialize = from_callable('serialize');
		$unserialize = from_callable('unserialize');
		$igbinary = ['serialize' => $igbinary_serialize, 'unserialize' => $igbinary_unserialize];
		$default = ['serialize' => $serialize, 'unserialize' => $unserialize];
		$serializers = [
			'igbinary' => $igbinary,
			'default' => $default,
		];
		if (function_exists('json_encode') && getenv('BENCHMARK_JSON')) {
			// NOTE that json does not preserve class types or distinguish between associative arrays and objects
			$json = ['serialize' => from_callable('json_encode'), 'unserialize' => from_callable('json_decode')];
			$serializers['json'] = $json;
		}
		if (function_exists('simdjson_decode') && getenv('BENCHMARK_SIMDJSON')) {
			// NOTE that json does not preserve class types or distinguish between associative arrays and objects
			$json = ['serialize' => from_callable('json_encode'), 'unserialize' => from_callable('simdjson_decode')];
			$serializers['simdjson'] = $json;
		}
		if (function_exists('msgpack_pack')) {
			// NOTE that json does not preserve class types or distinguish between associative arrays and objects
			$msgpack = ['serialize' => from_callable('msgpack_pack'), 'unserialize' => from_callable('msgpack_unpack')];
			$serializers['msgpack'] = $msgpack;
		}
		return $serializers;
	}

	public static function main() {
		error_reporting(E_ALL);
		ini_set('display_errors', 'stderr');
		$serializers = self::createSerializersToBenchmark();

		$opcache_enabled = function_exists('opcache_get_status') ? opcache_get_status()['opcache_enabled'] : false;
		printf("Running with PHP %s\n", PHP_VERSION);
		printf("igbinary version=%s\n", phpversion('igbinary'));
		printf("opcache is %s\n", $opcache_enabled ? 'enabled' : 'disabled');
		printf("igbinary.compact_strings=%s\n", ini_get('igbinary.compact_strings'));
		printf("Smaller times are better (the iterations completed faster)\n");
		echo "\n";
		$first_line = sprintf("%30s |           ", "");
		foreach ($serializers as $name => $results) {
			$first_line .= sprintf(" | %10s time(seconds)                        ", $name);
		}
		echo "$first_line\n";
		printf("%30s | iterations", "Benchmark");
		foreach ($serializers as $_) {
			printf(" |    serialize unserialize ser_bytes unser_speedup", $name);
		}
		echo "\n";
		echo str_repeat('-', strlen($first_line)) . "\n";
		$examples = self::createExamples();
		foreach ($examples as $exampleName => $example) {
			$results = [];
			foreach ($serializers as $name => $callbacks) {
				gc_collect_cycles();
				$results[$name] = self::run($callbacks['serialize'], $callbacks['unserialize'], $example);
			}
			printf("%30s | %10d", $exampleName, $example->iterations);
			foreach ($results as $name => $result) {
				$unser_speedup = $results['default']->unserialize_time / $result->unserialize_time;
				printf(" |    %9.5f %11.5f %9d %12.3fx", $result->serialize_time, $result->unserialize_time, $result->serialized_bytes, $unser_speedup);
			}
			echo "\n";
		}
	}
}

Benchmark::main();
