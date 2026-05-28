/**
 * Minimal Flutter Linux runner.
 *
 * Creates a GTK window, loads the Flutter Linux embedding, and starts the
 * Flutter engine. This replaces the CMake-template-based runner with a
 * programmatic approach suitable for Bazel builds.
 *
 * The runner expects the following layout relative to the executable:
 *   lib/                  (AOT: libapp.so)
 *   data/
 *     flutter_assets/
 *     icudtl.dat
 */

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Defined in generated_plugin_registrant.cc (always generated, may be no-op).
extern void fl_register_plugins(FlPluginRegistry *registry);

static void on_activate(GtkApplication *app) {
  GtkWindow *window =
      GTK_WINDOW(gtk_application_window_new(app));
  gtk_window_set_title(window, "Flutter");
  gtk_window_set_default_size(window, 800, 600);

  g_autoptr(FlDartProject) project = fl_dart_project_new();

  FlView *view = fl_view_new(project);
  fl_register_plugins(FL_PLUGIN_REGISTRY(fl_view_get_engine(view)));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  gtk_widget_show_all(GTK_WIDGET(window));
}

int main(int argc, char *argv[]) {
  g_autoptr(GtkApplication) app =
      gtk_application_new(GTK_APP_ID, G_APPLICATION_FLAGS_NONE);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
  return g_application_run(G_APPLICATION(app), argc, argv);
}
