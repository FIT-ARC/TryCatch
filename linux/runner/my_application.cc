#include "my_application.h"

#include <string.h>

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// Set to the user-visible app name (matches the .desktop Name= and the
// Flutter WindowOptions title) so GNOME, KDE and task managers agree.
static const char* kAppTitle = "TryCatch";

// --- Desktop-environment detection ------------------------------------------
//
// The stock Flutter template only enables the GNOME-style GtkHeaderBar on
// GNOME/X11 and assumes it works everywhere on Wayland. On KDE Plasma that
// leaves a GNOME-looking client-side header bar (or an unthemed GTK3
// titlebar) where KWin should be drawing native Breeze decorations.
//
// Policy: use the header bar only on GNOME-like desktops; everywhere else
// (KDE Plasma in particular, on both X11 and Wayland) fall back to a
// traditional title bar and let the window manager/compositor decorate.

static gboolean env_value_contains(const char* env_name,
                                   const char* needle) {
  const gchar* value = g_getenv(env_name);
  if (value == nullptr || needle == nullptr) {
    return FALSE;
  }
  gchar* lower = g_ascii_strdown(value, -1);
  gboolean found = strstr(lower, needle) != nullptr;
  g_free(lower);
  return found;
}

static gboolean env_any_contains(const char* needle) {
  return env_value_contains("XDG_CURRENT_DESKTOP", needle) ||
         env_value_contains("XDG_SESSION_DESKTOP", needle) ||
         env_value_contains("DESKTOP_SESSION", needle);
}

static gboolean is_kde_desktop() {
  if (env_any_contains("kde") || env_any_contains("plasma")) {
    return TRUE;
  }
  // KDE exports KDE_SESSION_VERSION even when the XDG vars are minimal.
  return g_getenv("KDE_SESSION_VERSION") != nullptr;
}

static gboolean is_gnome_like_desktop() {
  return env_any_contains("gnome") || env_any_contains("unity") ||
         env_any_contains("pantheon") || env_any_contains("budgie");
}

static gboolean should_use_header_bar(GtkWindow* window) {
  // KDE Plasma first: never force the GNOME header bar there — KWin draws
  // native Breeze decorations on X11, and on Wayland a plain title keeps
  // the Breeze-GTK styling instead of the GNOME CSD look.
  if (is_kde_desktop()) {
    return FALSE;
  }
  if (is_gnome_like_desktop()) {
    return TRUE;
  }
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    // GNOME Shell / Mutter (covers Ubuntu) get the header bar; every other
    // X11 WM (KWin, Xfwm, Muffin, Openbox, i3, …) keeps server decorations.
    if (g_strcmp0(wm_name, "GNOME Shell") == 0 ||
        g_strcmp0(wm_name, "Mutter") == 0) {
      return TRUE;
    }
    return FALSE;
  }
#endif
  // Wayland (or unknown backend) on a non-GNOME desktop: let the compositor
  // decorate instead of imposing the GNOME header bar.
  return FALSE;
}

static void set_window_icon(GtkWindow* window) {
  // Candidates in priority order: dev-time tree (`flutter run` from the
  // repo root) first, then the installed bundle layout (CMake installs
  // linux/assets/ to <bundle>/assets/).
  const char* candidates[] = {
      "linux/assets/icon.png",
      "assets/icon.png",
      nullptr,
  };
  for (int i = 0; candidates[i] != nullptr; i++) {
    g_autoptr(GError) icon_error = nullptr;
    GdkPixbuf* icon =
        gdk_pixbuf_new_from_file(candidates[i], &icon_error);
    if (icon != nullptr) {
      gtk_window_set_icon(window, icon);
      g_object_unref(icon);
      return;
    }
  }
  g_warning("Failed to load application icon (tried linux/assets/icon.png)");
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // GNOME-like desktops get the GtkHeaderBar; KDE Plasma (and every other
  // non-GNOME setup) keeps a traditional title bar so KWin/the compositor
  // draws native decorations instead of an out-of-place GNOME header bar.
  if (should_use_header_bar(window)) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, kAppTitle);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, kAppTitle);
    // Make sure the WM/compositor decorates the window (relevant on KDE:
    // KWin draws Breeze SSD on X11 from this).
    gtk_window_set_decorated(window, TRUE);
  }

  gtk_window_set_default_size(window, 1280, 720);

  set_window_icon(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // Required for the flutter_scene GPU renderer (needs Impeller).
  fl_dart_project_set_enable_flutter_gpu(project, TRUE);
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
