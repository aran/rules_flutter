#import "VGPVendoredPlugin.h"

#import <StaticGreeting/StaticGreeting.h>
#import <VendoredGreeting/VendoredGreeting.h>

@implementation VGPVendoredPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
#if TARGET_OS_OSX
  NSObject<FlutterBinaryMessenger> *messenger = registrar.messenger;
#else
  NSObject<FlutterBinaryMessenger> *messenger = [registrar messenger];
#endif
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"vendored_plugin" binaryMessenger:messenger];
  [registrar addMethodCallDelegate:[[VGPVendoredPlugin alloc] init] channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"greeting"]) {
    result([NSString stringWithUTF8String:vendored_greeting()]);
  } else if ([call.method isEqualToString:@"staticGreeting"]) {
    result([NSString stringWithUTF8String:static_greeting()]);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
