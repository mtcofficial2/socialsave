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
        // Android 7.0 and newer.
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

    signingConfigs {
        // Every SocialSave release so far is signed with this PC's debug key
        // (SHA-256 f5527ad4...). Android only installs an update signed with the
        // same key, so it must stay until a planned key rotation. v1+v2+v3
        // signatures let every Android version and installer verify the APK.
        getByName("debug") {
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    buildTypes {
        release {
            // Same key as every earlier release; see signingConfigs above.
            signingConfig = signingConfigs.getByName("debug")
            isDebuggable = false
            // Keep rules for the on-phone engine (see proguard-rules.pro).
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    // On-phone engine for "Download on this phone (no server)" (as in Seal).
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
}
