import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.gatonegro5.gatomix.tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.gatonegro5.gatomix.tv"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 3.1.35: misma llave fija que la app GatoMix. CI: ANDROID_KEYSTORE_PATH /
    // ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD.
    // Local: gatomix_tv/android/key.properties. Sin llave: debug solo fuera de CI.
    val keyProps = Properties()
    val keyPropsFile = rootProject.file("key.properties")
    if (keyPropsFile.exists()) {
        keyPropsFile.inputStream().use { keyProps.load(it) }
    }
    val envStore = System.getenv("ANDROID_KEYSTORE_PATH")
    val propStore = keyProps.getProperty("storeFile")
    val storePath = when {
        !envStore.isNullOrBlank() && file(envStore).exists() -> envStore
        !propStore.isNullOrBlank() && file(propStore).exists() -> file(propStore).path
        else -> null
    }
    val storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
        ?: keyProps.getProperty("storePassword")
    val keyAlias = System.getenv("ANDROID_KEY_ALIAS")
        ?: keyProps.getProperty("keyAlias")
    val keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
        ?: keyProps.getProperty("keyPassword")
    val hasReleaseKey = storePath != null &&
        !storePassword.isNullOrBlank() &&
        !keyAlias.isNullOrBlank() &&
        !keyPassword.isNullOrBlank()
    if (!hasReleaseKey && System.getenv("CI") == "true") {
        throw GradleException("CI sin llave de firma Android (ANDROID_KEYSTORE_*): no se firma en debug.")
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("gatomixRelease") {
                storeFile = file(storePath!!)
                this.storePassword = storePassword
                this.keyAlias = keyAlias
                this.keyPassword = keyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("gatomixRelease")
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
