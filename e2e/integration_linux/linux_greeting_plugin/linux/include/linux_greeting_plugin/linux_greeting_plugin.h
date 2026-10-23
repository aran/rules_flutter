#ifndef FLUTTER_PLUGIN_LINUX_GREETING_PLUGIN_H_
#define FLUTTER_PLUGIN_LINUX_GREETING_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

void linux_greeting_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_LINUX_GREETING_PLUGIN_H_
