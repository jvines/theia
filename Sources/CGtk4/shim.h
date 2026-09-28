#include <gtk/gtk.h>
#include <glib-unix.h>

static inline void theia_gtk_native_dialog_response(GtkNativeDialog *dialog, int response) {
    g_signal_emit_by_name(dialog, "response", response);
}
