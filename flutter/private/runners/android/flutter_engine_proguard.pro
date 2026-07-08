# R8/ProGuard keep rules the Flutter Android embedding requires. Attached to
# every `flutter_android_engine` target so they reach the consuming
# android_binary's R8 invocation transitively — the same way Gradle builds
# get them from AGP's default config plus the Flutter Gradle plugin's
# flutter_proguard_rules.pro.

# The embedding marks its JNI surface with @androidx.annotation.Keep
# (FlutterJNI and friends); libflutter.so's JNI_OnLoad registers natives on
# those classes by name and aborts the process if lookup fails. AGP's
# default proguard-android-optimize.txt honors @Keep; rules_android's R8
# invocation has no default config, so we replicate the @Keep contract here.
-keep class androidx.annotation.Keep
-keep @androidx.annotation.Keep class * { *; }
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <methods>;
}
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <fields>;
}
-keepclasseswithmembers class * {
    @androidx.annotation.Keep <init>(...);
}

# JNI resolves registered native methods by name; renaming them breaks
# RegisterNatives/dlsym lookup (also part of AGP's default config).
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# From flutter_tools' flutter_proguard_rules.pro:
# R8 can incorrectly strip FlutterPlugin implementations
# (https://github.com/flutter/flutter/issues/154580).
-if class * implements io.flutter.embedding.engine.plugins.FlutterPlugin
-keep,allowshrinking,allowobfuscation class <1>
-dontwarn io.flutter.plugin.**
-dontwarn android.**
