import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.gatonegro5.gatomix"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.gatonegro5.gatomix"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
            // Solo para pruebas en emulador x86_64 (gm34): GATOMIX_EMU=1.
            // El release de CI no la define y sigue saliendo solo arm64.
            if (System.getenv("GATOMIX_EMU") == "1") abiFilters += listOf("x86_64")
        }
    }

    // Firma de release. La contraseña NO vive en el repo.
    // CI: ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD /
    // ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD (secretos de GitHub).
    // Local: android/key.properties (ver key.properties.example).
    // Sin ninguna de las dos, el release se firma en debug.
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
    // 3.1.35: en CI (GitHub pone CI=true) nunca se firma en debug: cada runner
    // trae otro debug.keystore y el celular rechaza la actualizacion.
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
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    implementation("com.github.TeamNewPipe:NewPipeExtractor:v0.26.5")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
}
