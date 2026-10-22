#!/bin/sh
php -r "if (preg_match('/-dev|RC[0-9]+/', PHP_VERSION)) { printf('%d.%d.%d', PHP_MAJOR_VERSION, PHP_MINOR_VERSION, max(PHP_RELEASE_VERSION-1,0)); } else { echo PHP_VERSION; }"
