pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // 9.1.1, not 9.1.0: Flutter 3.50's Gradle plugin refuses anything older
    // ("lower than Flutter's minimum supported version of Android Gradle
    // Plugin version 9.1.1"), and the CI runner pins that channel.
    id("com.android.application") version "9.1.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // START: FlutterFire Configuration
    id("com.google.gms.google-services") version "4.5.0" apply false
    // END: FlutterFire Configuration
}

include(":app")
