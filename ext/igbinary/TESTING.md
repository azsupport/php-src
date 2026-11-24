# Testing

## Running tests

```sh
phpize
./configure
make clean
# To run tests with normal options
make test
# To run a specific test with Valgrind to debug crashes or memory leaks, add -m
make test TESTS="-m tests/igbinary_0mytest.phpt"
```

### Running APCu test cases

This is only necessary if you've touched the igbinary memory management code or the code for interacting with APCu,
or are debugging an issue involving both APCu with the igbinary serializer.

Note that APCu 5.1.10 or newer is strongly recommended,
since there were [known bugs in APCu](https://github.com/krakjoe/apcu/issues/260) prior to that.

Instructions

```sh
# go to modules directory
cd modules

# ... and create symlink to apcu extension
# it will be loaded during test suite
# replace this example path with the actual path to apcu.so for the php binary
ln -nsf /opt/lib/php/extensions/no-debug-non-zts-20121212/apcu.so
```

### Code Coverage

See [`CODE_COVERAGE.md`](./CODE_COVERAGE.md)
