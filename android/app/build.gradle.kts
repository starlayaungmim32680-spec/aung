import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (6 Nov 2026): Fly's own upload key, not the debug key -
// Google Play refuses debug-signed apps, and the Android App Link for the
// password-reset screen (/.well-known/assetlinks.json on the Worker) is
// tied to this key's SHA-256. The key and its passwords live OUTSIDE git:
//   android/key.properties   (gitignored - storePassword, keyPassword,
//                             keyAlias=upload, storeFile=<path to .jks>)
//   C:/Users/AUNG/fly-keys/fly-upload.jks  (+ 2 backups, never in git)
// A release build without key.properties stops with a clear error instead
// of quietly signing with the debug key again.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "com.aungdev.fly"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.aungdev.fly"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Dev / prod split (5 Oct 2026) - see lib/app_config.dart.
    //   prod: com.aungdev.fly, "fly", uses android/app/google-services.json
    //         (Firebase aung-1756e).
    //   dev:  com.aungdev.fly.dev, "Fly Dev", uses
    //         android/app/src/dev/google-services.json (Firebase fly-dev).
    // Build with --flavor prod / --flavor dev.
    buildFeatures {
        resValues = true
    }
    flavorDimensions += "env"
    productFlavors {
        create("prod") {
            dimension = "env"
            resValue("string", "app_name", "fly")
            // 6 Nov 2026: the host of the password-reset email link =
            // Firebase's own action page (the custom action URL can't be set:
            // EMAIL_TEMPLATE_UPDATE_NOT_ALLOWED). Firebase Hosting serves
            // /.well-known/assetlinks.json there (firebase_hosting/), so the
            // link opens Fly (App Link, AndroidManifest.xml).
            manifestPlaceholders["authLinkHost"] = "aung-1756e.firebaseapp.com"
        }
        create("dev") {
            dimension = "env"
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
            resValue("string", "app_name", "Fly Dev")
            manifestPlaceholders["authLinkHost"] = "fly-dev-58b29.firebaseapp.com"
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Only stop a RELEASE build (debug runs don't need the key).
            val buildingRelease = gradle.startParameter.taskNames.any {
                it.contains("Release", ignoreCase = true)
            }
            if (buildingRelease && !keystorePropertiesFile.exists()) {
                throw GradleException(
                    "android/key.properties is missing - release builds must be " +
                        "signed with Fly's upload key (see build.gradle.kts).")
            }
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
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
    // Works around a known upstream bug in the `camera` plugin's CameraX
    // dependency (camera-core 1.5.x is missing this transitive dependency).
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    // Beauty Lab (9 Nov 2026): GPUPixel v1.3.1 (github.com/pixpark/gpupixel,
    // Apache-2.0) - Fly Dev only while we test it, prod does not get it.
    "devImplementation"(files("libs/gpupixel-release.aar"))
}