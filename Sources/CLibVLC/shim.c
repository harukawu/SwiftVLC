// CLibVLC shim — helpers for Swift interop with libVLC C API.

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "CLibVLC.h"

/// Wrapper for libvlc_log_set that formats the va_list message in C
/// and calls a simpler Swift-compatible callback with the formatted string.
///
/// Swift can't easily handle C va_list arguments, so we format here
/// and pass the result to a simplified callback.
typedef void (*swiftvlc_log_cb)(void *data, int level,
                                 const char *module,
                                 const char *message);

struct swiftvlc_log_context {
    swiftvlc_log_cb callback;
    void *data;
};

static void swiftvlc_log_bridge(void *data, int level,
                                 const libvlc_log_t *ctx,
                                 const char *fmt, va_list args) {
    struct swiftvlc_log_context *context = (struct swiftvlc_log_context *)data;

    // Format the message
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, args);

    // Get module name
    const char *module = NULL;
    const char *header = NULL;
    unsigned line = 0;
    libvlc_log_get_context(ctx, &module, &header, &line);

    context->callback(context->data, level, module, buf);
}

/// Sets up a simplified log callback that receives pre-formatted messages.
/// Returns a context pointer that must be freed with swiftvlc_log_unset(),
/// or NULL on allocation failure.
void *swiftvlc_log_set(libvlc_instance_t *instance,
                        swiftvlc_log_cb callback,
                        void *data) {
    struct swiftvlc_log_context *context = malloc(sizeof(*context));
    if (!context) {
        return NULL;
    }
    context->callback = callback;
    context->data = data;
    libvlc_log_set(instance, swiftvlc_log_bridge, context);
    return context;
}

/// Unsets the log callback and frees the bridge context.
/// Safe to call with a NULL context — only clears the libVLC log callback.
void swiftvlc_log_unset(libvlc_instance_t *instance, void *context) {
    libvlc_log_unset(instance);
    free(context);
}

static int swiftvlc_is_directory(const char *path) {
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static pthread_mutex_t swiftvlc_plugin_path_mutex = PTHREAD_MUTEX_INITIALIZER;

static int swiftvlc_path_list_contains(const char *list, const char *path) {
    if (!list || !path || path[0] == '\0') {
        return 0;
    }

    size_t path_len = strlen(path);
    const char *cursor = list;
    while (*cursor) {
        const char *separator = strchr(cursor, ':');
        size_t segment_len = separator ? (size_t)(separator - cursor) : strlen(cursor);
        if (segment_len == path_len && strncmp(cursor, path, path_len) == 0) {
            return 1;
        }
        if (!separator) {
            break;
        }
        cursor = separator + 1;
    }

    return 0;
}

char *swiftvlc_copy_bundled_plugins_path(void) {
#if defined(__APPLE__)
    Dl_info info;
    if (dladdr((const void *)&libvlc_new, &info) == 0 || !info.dli_fname) {
        return NULL;
    }

    char framework_path[PATH_MAX];
    size_t binary_path_len = strnlen(info.dli_fname, sizeof(framework_path));
    if (binary_path_len >= sizeof(framework_path)) {
        return NULL;
    }
    memcpy(framework_path, info.dli_fname, binary_path_len + 1);

    char *last_slash = strrchr(framework_path, '/');
    if (!last_slash) {
        return NULL;
    }
    *last_slash = '\0';

    char plugins_path[PATH_MAX];
    int written = snprintf(plugins_path, sizeof(plugins_path), "%s/plugins", framework_path);
    if (written < 0 || (size_t)written >= sizeof(plugins_path)) {
        return NULL;
    }

    if (!swiftvlc_is_directory(plugins_path)) {
        return NULL;
    }

    return strdup(plugins_path);
#else
    return NULL;
#endif
}

int swiftvlc_prepare_bundled_plugins(void) {
    char *plugins_path = swiftvlc_copy_bundled_plugins_path();
    if (!plugins_path) {
        return 0;
    }

    pthread_mutex_lock(&swiftvlc_plugin_path_mutex);

    int result = 0;
    const char *existing = getenv("VLC_PLUGIN_PATH");
    if (!existing || existing[0] == '\0') {
        result = setenv("VLC_PLUGIN_PATH", plugins_path, 1) == 0 ? 1 : 0;
        goto done;
    }

    if (swiftvlc_path_list_contains(existing, plugins_path)) {
        result = 1;
        goto done;
    }

    size_t existing_len = strlen(existing);
    size_t plugins_len = strlen(plugins_path);
    size_t combined_len = existing_len + 1 + plugins_len + 1;
    char *combined = malloc(combined_len);
    if (!combined) {
        goto done;
    }

    snprintf(combined, combined_len, "%s:%s", existing, plugins_path);
    result = setenv("VLC_PLUGIN_PATH", combined, 1) == 0 ? 1 : 0;
    free(combined);

done:
    pthread_mutex_unlock(&swiftvlc_plugin_path_mutex);
    free(plugins_path);
    return result;
}
