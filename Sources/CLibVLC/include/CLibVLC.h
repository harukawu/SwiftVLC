// CLibVLC.h — Umbrella header for the libVLC C API
// Exposes the raw libVLC 4.0 C functions to Swift via the CLibVLC module.

#ifndef CLibVLC_h
#define CLibVLC_h

#include "vlc/vlc.h"

// MARK: - Swift interop shims

/// Simplified log callback that receives pre-formatted messages.
/// Swift can't handle C va_list arguments, so the shim formats in C.
typedef void (*swiftvlc_log_cb)(void *data, int level,
                                 const char *module,
                                 const char *message);

/// Sets up a simplified log callback. Returns a context pointer
/// that must be freed with swiftvlc_log_unset().
void *swiftvlc_log_set(libvlc_instance_t *instance,
                        swiftvlc_log_cb callback,
                        void *data);

/// Unsets the log callback and frees the bridge context.
void swiftvlc_log_unset(libvlc_instance_t *instance, void *context);

/// Returns a newly allocated path to libvlc.framework's bundled plugins
/// directory, or NULL if the framework/plugins directory cannot be found.
/// The caller must free the returned pointer.
char *swiftvlc_copy_bundled_plugins_path(void);

/// Ensures libvlc.framework's bundled plugins directory is present in
/// VLC_PLUGIN_PATH before libvlc_new() scans for dynamic modules.
/// Returns 1 when a bundled path is available and 0 otherwise.
int swiftvlc_prepare_bundled_plugins(void);

#endif /* CLibVLC_h */
