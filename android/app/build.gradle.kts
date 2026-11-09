import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.p2pcommunicator.p2p_communicator"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.p2pcommunicator.p2p_communicator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: CI passes the keystore through environment variables
    // (from repository secrets); locally a key.properties file can do the same.
    // Without either, release builds fall back to the debug key.
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    fun signingValue(env: String, prop: String): String? =
        System.getenv(env)?.takeIf { it.isNotBlank() } ?: keyProps.getProperty(prop)

    val releaseStoreFile = signingValue("ANDROID_KEYSTORE_PATH", "storeFile")

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = file(releaseStoreFile)
                storeType = "pkcs12"
                storePassword = signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
                keyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    // Where updates come from. "github" (the default, see pubspec.yaml
    // default-flavor) updates itself from the latest GitHub release; "play"
    // is the Google Play build: Play forbids self-updating, so it has no
    // install permission and uses Play's in-app update flow instead. Same
    // application id and signing key, so either can update the other.
    flavorDimensions += "store"
    productFlavors {
        create("github") { dimension = "store" }
        create("play") { dimension = "store" }
    }

    buildTypes {
        release {
            // R8 shrinking stays on; proguard-rules.pro keeps the classes
            // veilid-core reaches over JNI (protected store, plugin init).
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (releaseStoreFile != null) {
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
    // Play in-app updates, only in the Play build (2.1.0, Google, 2023).
    "playImplementation"("com.google.android.play:app-update:2.1.0")
}
