#include "TheiaCurl.h"

#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint8_t *bytes;
    size_t count;
    size_t capacity;
    int allocation_failed;
    TheiaCurlShouldCancel should_cancel;
    void *context;
} TheiaCurlBuffer;

static pthread_once_t curl_init_once = PTHREAD_ONCE_INIT;
static CURLcode curl_init_result = CURLE_FAILED_INIT;

static void initialize_curl(void) {
    curl_init_result = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static size_t append_body(char *bytes, size_t size, size_t count, void *context) {
    TheiaCurlBuffer *buffer = context;
    if (size != 0 && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length == 0) return 0;
    // Gaia's 1,000-row CSV is much smaller; bound a malformed response.
    const size_t limit = 16 * 1024 * 1024;
    if (length > limit - buffer->count) return 0;
    size_t needed = buffer->count + length;
    if (needed > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 4096;
        while (capacity < needed) capacity = capacity > limit / 2 ? limit : capacity * 2;
        uint8_t *grown = realloc(buffer->bytes, capacity);
        if (!grown) {
            buffer->allocation_failed = 1;
            return 0;
        }
        buffer->bytes = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->bytes + buffer->count, bytes, length);
    buffer->count = needed;
    return length;
}

static int check_cancel(void *context, curl_off_t download_total,
                        curl_off_t downloaded, curl_off_t upload_total,
                        curl_off_t uploaded) {
    (void)download_total;
    (void)downloaded;
    (void)upload_total;
    (void)uploaded;
    TheiaCurlBuffer *buffer = context;
    return buffer->should_cancel && buffer->should_cancel(buffer->context);
}

int theia_curl_get(const char *url, long timeout_ms,
                   TheiaCurlShouldCancel should_cancel, void *context,
                   uint8_t **body, size_t *body_length, long *status_code) {
    if (!url || !body || !body_length || !status_code) return -1;
    *body = NULL;
    *body_length = 0;
    *status_code = 0;
    pthread_once(&curl_init_once, initialize_curl);
    if (curl_init_result != CURLE_OK) return curl_init_result;

    CURL *handle = curl_easy_init();
    if (!handle) return -1;
    TheiaCurlBuffer buffer = {0};
    buffer.should_cancel = should_cancel;
    buffer.context = context;
    curl_easy_setopt(handle, CURLOPT_URL, url);
    curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(handle, CURLOPT_MAXREDIRS, 3L);
    curl_easy_setopt(handle, CURLOPT_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
    curl_easy_setopt(handle, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, timeout_ms);
    curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS,
                     timeout_ms < 10000 ? timeout_ms : 10000L);
    curl_easy_setopt(handle, CURLOPT_USERAGENT, "Theia/1.0");
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, append_body);
    curl_easy_setopt(handle, CURLOPT_WRITEDATA, &buffer);
    curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, check_cancel);
    curl_easy_setopt(handle, CURLOPT_XFERINFODATA, &buffer);
    curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L);
    CURLcode result = curl_easy_perform(handle);
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, status_code);
    curl_easy_cleanup(handle);
    *body = buffer.bytes;
    *body_length = buffer.count;
    if (buffer.allocation_failed) return -1;
    return result;
}

void theia_curl_free(void *pointer) { free(pointer); }

const char *theia_curl_error(int code) {
    return code < 0 ? "Could not allocate the catalog response" : curl_easy_strerror((CURLcode)code);
}
