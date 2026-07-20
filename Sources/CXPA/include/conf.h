/*
 * conf.h — hand-authored configuration for the vendored libxpa, replacing the
 * autoconf-generated header. Values reflect macOS (Apple clang, BSD sockets).
 * Included only when HAVE_CONFIG_H is defined (set in Package.swift).
 */
#ifndef XPA_CONF_H
#define XPA_CONF_H

#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STDINT_H 1
/* macOS has no malloc.h — malloc lives in stdlib.h */
/* #undef HAVE_MALLOC_H */
#define HAVE_UNISTD_H 1
#define HAVE_GETOPT_H 1
#define HAVE_PWD_H 1
/* macOS has no values.h */
/* #undef HAVE_VALUES_H */
#define HAVE_DLFCN_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_SYS_SHM_H 1
#define HAVE_SYS_MMAN_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_IPC_H 1
#define HAVE_SETJMP_H 1
#define HAVE_SOCKLEN_T 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1
#define HAVE_SNPRINTF 1
#define HAVE_SETENV 1
#define HAVE_POSIX_SPAWN 1
#define HAVE_CRT_EXTERNS_H 1
#define HAVE__NSGETENVIRON 1
#define HAVE_ATEXIT 1
#define HAVE_GETADDRINFO 1
#define HAVE_LIBPTHREAD 1
#define _REENTRANT 1

/* No GUI toolkit event-loop bindings, not Cygwin/MinGW. */
/* #undef HAVE_TCL */
/* #undef HAVE_XT */
/* #undef HAVE_GTK */
/* #undef HAVE_CYGWIN */
/* #undef HAVE_MINGW32 */

#endif /* XPA_CONF_H */
