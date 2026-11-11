--TEST--
GHSA-vc5h-9ppw-p5f3 (circular symlinks in tar should not cause stack overflow)
--CREDITS--
Calvin Young - eWalker Consulting (HK) Limited
Enoch Chow - Isomorph Cyber
--SKIPIF--
<?php if (!extension_loaded("phar")) die("skip");?>
--FILE--
<?php
/* The upstream test ships the archives as binary files; patch(1) cannot add
 * those, so the same archives are written here: ustar symlink entries only. */
function ghsa_vc5h_tar($path, array $links) {
	$data = '';
	foreach ($links as $name => $target) {
		$h = str_pad($name, 100, "\0") . "0000644\0" . "0000000\0" . "0000000\0"
			. "00000000000\0" . "00000000000\0" . "        " . "2"
			. str_pad($target, 100, "\0") . "ustar\0" . "00"
			. str_repeat("\0", 64) . "0000000\0" . "0000000\0" . str_repeat("\0", 167);
		$sum = 0;
		for ($i = 0; $i < 512; $i++) {
			$sum += ord($h[$i]);
		}
		$data .= substr_replace($h, sprintf("%06o\0 ", $sum), 148, 8);
	}
	file_put_contents($path, $data . str_repeat("\0", 1024));
}
$base = dirname(__FILE__) . '/ghsa-vc5h-9ppw-p5f3';

// simple 2-cycle
ghsa_vc5h_tar($base . '-2.tar', array('file_a' => 'file_b', 'file_b' => 'file_a'));
$phar = new PharData($base . '-2.tar');
var_dump($phar['file_a']->getContent() === '');

// rho-shaped cycle (tail leading into a loop)
ghsa_vc5h_tar($base . '-rho.tar', array('file_a' => 'file_b', 'file_b' => 'file_c', 'file_c' => 'file_d', 'file_d' => 'file_b'));
$phar = new PharData($base . '-rho.tar');
var_dump($phar['file_a']->getContent() === '');

// long cycle (400 entries)
$links = array();
for ($i = 0; $i < 400; $i++) {
	$links['link_' . $i] = 'link_' . (($i + 1) % 400);
}
ghsa_vc5h_tar($base . '-long.tar', $links);
$phar = new PharData($base . '-long.tar');
var_dump($phar['link_0']->getContent() === '');
?>
--CLEAN--
<?php
$base = dirname(__FILE__) . '/ghsa-vc5h-9ppw-p5f3';
@unlink($base . '-2.tar');
@unlink($base . '-rho.tar');
@unlink($base . '-long.tar');
?>
--EXPECT--
bool(true)
bool(true)
bool(true)
