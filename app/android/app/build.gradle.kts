import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "fr.niceescap.bataille_corse"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "fr.niceescap.bataille_corse"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Signature de release.
    //
    // Le keystore n'est JAMAIS dans le dépôt : la CI le reconstruit à partir
    // des secrets GitHub (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`,
    // `KEY_ALIAS`, `KEY_PASSWORD`). En local, sans ces secrets, on retombe
    // sur les clés de debug : `flutter run --release` reste possible, mais le
    // binaire obtenu n'est PAS publiable.
    //
    // Voir `docs/DEPLOIEMENT.md` §7 pour la procédure de création du
    // keystore et sa politique de sauvegarde.
    // GitHub Actions injecte les secrets **absents** comme des chaînes
    // VIDES, pas comme des variables manquantes : tester `!= null` ne
    // suffirait pas, le décodage base64 d'une chaîne vide échouerait.
    val envKeystoreB64: String = System.getenv("KEYSTORE_BASE64") ?: ""
    val envKeystorePass: String = System.getenv("KEYSTORE_PASSWORD") ?: ""
    val envKeyAlias: String = System.getenv("KEY_ALIAS") ?: ""
    val envKeyPass: String = System.getenv("KEY_PASSWORD") ?: ""

    val signatureDisponible: Boolean = envKeystoreB64.isNotBlank() &&
        envKeystorePass.isNotBlank() &&
        envKeyAlias.isNotBlank() &&
        envKeyPass.isNotBlank()

    signingConfigs {
        if (signatureDisponible) {
            create("release") {
                // Le secret arrive en base64 : on le décode dans un fichier
                // temporaire, hors du dépôt, dans le répertoire de build.
                val fichier = file("${layout.buildDirectory.get()}/upload-keystore.jks")
                fichier.writeBytes(Base64.getDecoder().decode(envKeystoreB64))
                storeFile = fichier
                storePassword = envKeystorePass
                keyAlias = envKeyAlias
                keyPassword = envKeyPass
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
