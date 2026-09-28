#ifndef THEIA_CURL_H
#define THEIA_CURL_H

#include <stddef.h>
#include <stdint.h>

typedef int (*TheiaCurlShouldCancel)(void *context);

// Returns a libcurl CURLcode, or -1 for allocation/setup failure. The caller
// owns *body and frees it with theia_curl_free, including after HTTP errors.
int theia_curl_get(const char *url, long timeout_ms,
                   TheiaCurlShouldCancel should_cancel, void *context,
                   uint8_t **body, size_t *body_length, long *status_code);
void theia_curl_free(void *pointer);
const char *theia_curl_error(int code);

#endif
