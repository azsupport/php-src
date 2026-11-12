/*
   +----------------------------------------------------------------------+
   | Zend OPcache                                                         |
   +----------------------------------------------------------------------+
   | Copyright (c) 1998-2016 The PHP Group                                |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | http://www.php.net/license/3_01.txt                                  |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
   | Authors: Andi Gutmans <andi@zend.com>                                |
   |          Zeev Suraski <zeev@zend.com>                                |
   |          Stanislav Malyshev <stas@zend.com>                          |
   |          Dmitry Stogov <dmitry@zend.com>                             |
   +----------------------------------------------------------------------+
*/

#ifndef ZEND_ACCELERATOR_MODULE_H
#define ZEND_ACCELERATOR_MODULE_H

#ifdef COMPILE_DL_OPCACHE
int start_accel_module(void);
#else
/* OPcache built into PHP (--enable-opcache-static, azsupport/php-src) */
extern zend_module_entry opcache_module_entry;
#define phpext_opcache_ptr &opcache_module_entry
void zend_accel_register_ini_entries(TSRMLS_D);
#endif
void zend_accel_override_file_functions(TSRMLS_D);

#endif /* _ZEND_ACCELERATOR_MODULE_H */
