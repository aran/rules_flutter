#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

/// Answers `greeting` with what VendoredGreeting.framework, a prebuilt dynamic
/// framework, returns.
@interface VGPVendoredPlugin : NSObject <FlutterPlugin>
@end
