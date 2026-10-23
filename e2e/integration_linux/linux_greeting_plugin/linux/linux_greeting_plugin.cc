#include "include/linux_greeting_plugin/linux_greeting_plugin.h"

#include <cstring>
#include <flutter_linux/flutter_linux.h>

namespace {

constexpr char kChannelName[] = "rules_flutter/linux_greeting";
constexpr char kGetGreetingMethod[] = "getGreeting";
constexpr char kGreetingValue[] = "Hello from Linux C++ plugin!";

void handle_method_call(FlMethodChannel* channel,
                        FlMethodCall* method_call,
                        gpointer user_data) {
  (void)channel;
  (void)user_data;

  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  if (std::strcmp(method, kGetGreetingMethod) == 0) {
    g_autoptr(FlValue) result = fl_value_new_string(kGreetingValue);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send method call response: %s", error->message);
  }
}

}  // namespace

void linux_greeting_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, handle_method_call, nullptr, nullptr);
}
