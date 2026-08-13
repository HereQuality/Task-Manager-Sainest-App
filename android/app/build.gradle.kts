import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Play Store upload-signing credentials -- read from android/key.properties
// (gitignored, never committed; see key.properties.example for the
// template and PLAY_STORE_RELEASE.md for how to generate the keystore).
// Deliberately optional: if the file doesn't exist (a fresh checkout, or
// CI without the secret), releaseSigningProps stays null and the release
// build type below falls back to debug signing so `flutter build`/`flutter
// run --release` still work locally without it.
val keyPropertiesFile = rootProject.file("key.properties")
val releaseSigningProps: Properties? = if (keyPropertiesFile.exists()) {
    Properties().apply { load(keyPropertiesFile.inputStream()) }
} else {
    null
}

android {
    namespace = "com.hqepl.qtask360"
    // flutter.compileSdkVersion (this Flutter SDK's own default) is 34 --
    // file_picker 8.x pulls in flutter_plugin_android_lifecycle, which
    // requires compiling against API 36+. Overridden explicitly rather
    // than waiting on a Flutter SDK upgrade to bump the default.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
}

    defaultConfig {
        applicationId = "com.hqepl.qtask360"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningProps != null) {
            create("release") {
                storeFile = file(releaseSigningProps.getProperty("storeFile"))
                storePassword = releaseSigningProps.getProperty("storePassword")
                keyAlias = releaseSigningProps.getProperty("keyAlias")
                keyPassword = releaseSigningProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Uses the real upload key once android/key.properties exists;
            // falls back to the debug key otherwise (matches the Flutter
            // template default) so this project keeps building without it.
            signingConfig = if (releaseSigningProps != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Explicitly off (this was already the implicit default, but
            // left unstated) -- code shrinking is what caused
            // flutter_local_notifications' documented Gson/TypeToken
            // crash on this app (see proguard-rules.pro's own comment for
            // the full story). Don't flip this on without also verifying
            // those keep rules actually prevent it recurring.
            isMinifyEnabled = false
            isShrinkResources = false
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
}