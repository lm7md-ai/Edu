# JNI names are looked up by the VM from the Kotlin object and must survive R8.
-keep class ai.lm7md.edu.NativeRuntimeJni { *; }
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# Flutter discovers the host activity and runtime plugin reflectively.
-keep class ai.lm7md.edu.MainActivity { *; }
-keep class ai.lm7md.edu.EduNativeRuntimePlugin { *; }

# sqlite3.dart and SQLite's C/FFI entry points must not be renamed or stripped.
-keep class org.sqlite.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.tekartik.sqflite.** { *; }

# Preserve native method names/signatures across app and bundled backend libraries.
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-dontwarn org.sqlite.**
-dontwarn io.flutter.**
