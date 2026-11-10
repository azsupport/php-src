ARG PHP_VERSION
FROM php:$PHP_VERSION
WORKDIR /code
ENV NO_INTERACTION=1
RUN mkdir -p src/php7/
ADD src/php7/*.c src/php7/*.h ./src/php7/
ADD *.c *.h config.m4 ./
RUN phpize &&  ./configure && make -j$(nproc)
ADD tests ./tests
