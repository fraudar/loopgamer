# Regras ProGuard / R8 seguras para LoopGamer (Flutter + JNI C++/Vulkan)

# Preserva metainformação útil para stack traces em crashes de release
-keepattributes SourceFile,LineNumberTable,*Annotation*,Signature,InnerClasses,EnclosingMethod

# Preserva Activity, Service e FileProvider declarados no AndroidManifest.xml
-keep class org.loopgamer.emulator.MainActivity { *; }
-keep class org.loopgamer.emulator.EmulationForegroundService { *; }
-keep class org.loopgamer.emulator.DownloadForegroundService { *; }
-keep class androidx.core.content.FileProvider { *; }

# Nunca remove/renomeia métodos JNI nativos nem classes chamadas via FindClass
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# Flutter embedding & plugins registrados em GeneratedPluginRegistrant
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class dev.flutter.plugins.** { *; }

-dontwarn io.flutter.plugin.**
-dontwarn io.flutter.embedding.**
-dontwarn com.google.android.play.core.**
-dontwarn android.**
-dontwarn javax.**
-dontwarn org.codehaus.**

# Extração de pacotes de dados (commons-compress / xz / junrar)
-keep class org.apache.commons.compress.** { *; }
-keep class org.tukaani.xz.** { *; }
-keep class com.github.junrar.** { *; }
-dontwarn org.apache.commons.compress.**
-dontwarn org.tukaani.xz.**
-dontwarn com.github.junrar.**
-dontwarn org.slf4j.**
