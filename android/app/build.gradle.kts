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
    compileSdk = flutter.compileSdkVersion
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