/**
 * Custom Flutter Linux runner — Approach 3 example.
 *
 * Minimal GTK runner compiled with cc_binary (rules_cc).
 * Uses extern declaration for the registrant (no #include needed).
 */

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Defined in the registrant .cc (always generated, may be no-op).
extern void fl_register_plugins(FlPluginRegistry* registry);

static void on_activate(GtkApplication* app) {
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(app));
  gtk_window_set_title(window, "Custom Runner");
  gtk_window_set_default_size(window, 800, 600);

  g_autoptr(FlDartProject) project = fl_dart_project_new();

  FlView* view = fl_view_new(project);
  fl_register_plugins(FL_PLUGIN_REGISTRY(fl_view_get_engine(view)));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  gtk_widget_show_all(GTK_WIDGET(window));
}

int main(int argc, char* argv[]) {
  g_autoptr(GtkApplication) app =
      gtk_application_new("com.example.linuxexample", G_APPLICATION_FLAGS_NONE);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
  return g_application_run(G_APPLICATION(app), argc, argv);
}
