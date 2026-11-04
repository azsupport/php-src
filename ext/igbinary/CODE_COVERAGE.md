Generating Code Coverage
========================

1. Clone php-src (e.g. for the PHP-7.4 branch)
2. Copy the igbinary directory into php-src/ext/igbinary
3. Run `cd /path/to/php-src; ./buildconf --force; ./configure --disable-all --enable-maintainer-zts --enable-debug --enable-cgi --enable-session --enable-json --enable-igbinary --enable-gcov; make -j8`
4. Run the tests: `make test TESTS=ext/igbinary/tests`
5. Generate coverage from the tests: `make lcov TESTS=ext/igbinary/tests`
6. View the code coverage in `lcov_html/index.html` for ext/igbinary in your browser.
