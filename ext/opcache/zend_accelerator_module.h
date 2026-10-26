/*
   +----------------------------------------------------------------------+
   | Zend OPcache                                                         |
   +----------------------------------------------------------------------+
   | Copyright (c) The PHP Group                                          |
   +----------------------------------------------------------------------+
   | This source file is subject to version 3.01 of the PHP license,      |
   | that is bundled with this package in the file LICENSE, and is        |
   | available through the world-wide-web at the following url:           |
   | https://www.php.net/license/3_01.txt                                 |
   | If you did not receive a copy of the PHP license and are unable to   |
   | obtain it through the world-wide-web, please send a note to          |
   | license@php.net so we can mail you a copy immediately.               |
   +----------------------------------------------------------------------+
   | Authors: Andi Gutmans <andi@php.net>                                 |
   |          Zeev Suraski <zeev@php.net>                                 |
   |          Stanislav Malyshev <stas@zend.com>                          |
   |          Dmitry Stogov <dmitry@php.net>                              |
   +----------------------------------------------------------------------+
*/

#ifndef ZEND_ACCELERATOR_MODULE_H
#define ZEND_ACCELERATOR_MODULE_H

#ifdef COMPILE_DL_OPCACHE
int start_accel_module(void);
#else
/* OPcache built into PHP (--enable-opcache-static, azsupport/php-src) */
#include "Zend/zend_modules.h"
extern zend_module_entry opcache_module_entry;
#define phpext_opcache_ptr &opcache_module_entry
void zend_accel_register_ini_entries(void);
#endif

void zend_accel_override_file_functions(void);

#endif /* _ZEND_ACCELERATOR_MODULE_H */
