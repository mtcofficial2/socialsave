# On-phone engine (youtubedl-android). R8 broke commons-compress: its zip
# extra-field registry instantiates classes by reflection, and after
# shrinking it failed with "class ...zip.a is not a concrete class", so the
# engine could not unpack Python/ffmpeg on first use.
-keep class org.apache.commons.compress.** { *; }
-dontwarn org.apache.commons.compress.**
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-dontwarn com.fasterxml.jackson.**
-dontwarn java.beans.**
-keep class org.tukaani.xz.** { *; }
-dontwarn org.tukaani.**
-dontwarn org.brotli.dec.**
-dontwarn com.github.luben.zstd.**
-dontwarn org.objectweb.asm.**