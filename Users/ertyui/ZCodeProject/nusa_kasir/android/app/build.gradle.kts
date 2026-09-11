plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Dev build detection ──
// `flutter build apk --dart-define=NUSA_DEV=true` reaches Gradle as a
// base64-encoded `-Pdart-defines` property (the Flutter tool's encoding of
// --dart-define; "NUSA_DEV=true" → "TlVTQV9ERVY9dHJ1ZQ==").
// The dev build gets its own applicationId so it installs side-by-side with
// production apps, and skips the google-services plugin because com.nusa.dev
// has no Firebase project entry in google-services.json.
val isDevBuild = (project.findProperty("dart-defines") as String? ?: "")
    .split(",").contains("TlVTQV9ERVY9dHJ1ZQ==")

if (!isDevBuild) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = if (isDevBuild) "com.nusa.dev" else "com.nusa.kelontong"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = if (isDevBuild) "com.nusa.dev" else "com.nusa.kelontong"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    buildTypes {
        release {
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

    // Firebase BoM — otomatis cocokkan versi semua Firebase SDK
    implementation(platform("com.google.firebase:firebase-bom:34.16.0"))
    implementation("com.google.firebase:firebase-analytics")
    // Google Sign-In butuh Firebase Auth
    implementation("com.google.firebase:firebase-auth")
    // Activity Result API — modern way to handle startActivityForResult
    implementation("androidx.activity:activity-ktx:1.9.3")
}
