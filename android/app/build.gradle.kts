plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.socialsave.social_save"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.socialsave.social_save"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packaging {
        // youtubedl-android runs libpython.so / libffmpeg.so from the native
        // library dir, so libraries must be extracted on install.
        jniLibs.useLegacyPackaging = true
        // Zip payloads named .so (Python, ffmpeg): nothing to strip.
        jniLibs.keepDebugSymbols += listOf("**/libpython.zip.so", "**/libffmpeg.zip.so")
        // Flutter is built for ARM only (--target-platform android-arm,android-arm64);
        // plugin libraries for x86/x86_64 (libmpv etc.) had no libflutter.so to run with.
        jniLibs.excludes += listOf("lib/x86/**", "lib/x86_64/**")
        // The on-phone engine (about 55 MB) ships for arm64-v8a only; other
        // ABIs keep the server flow and the Settings switch is hidden there.
        for (abi in listOf("armeabi-v7a", "x86", "x86_64")) {
            for (lib in listOf("libpython.so", "libpython.zip.so", "libqjs.so", "libffmpeg.so", "libffmpeg.zip.so", "libffprobe.so")) {
                jniLibs.excludes += "lib/$abi/$lib"
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core-ktx:1.16.0")
    // On-phone engine for "Download on this phone (no server)" (as in Seal).
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
}
