/*
 * Stand-in for libglibutil's logging macros.  Arguments are still evaluated
 * and type-checked by the printf attribute, so a format/argument mismatch in
 * the daemon fails here exactly as it would against the real header.  Set
 * TEST_VERBOSE=1 to see the lines.
 */
#pragma once
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

__attribute__((format(printf, 2, 3)))
static inline void
gutil_shim_log(const char* level, const char* fmt, ...)
{
    if (!getenv("TEST_VERBOSE"))
        return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[%s] ", level);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

#define GERR(...)     gutil_shim_log("E", __VA_ARGS__)
#define GWARN(...)    gutil_shim_log("W", __VA_ARGS__)
#define GINFO(...)    gutil_shim_log("I", __VA_ARGS__)
#define GDEBUG(...)   gutil_shim_log("D", __VA_ARGS__)
#define GVERBOSE(...) gutil_shim_log("V", __VA_ARGS__)
