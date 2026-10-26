import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key.
//
// GitHub Actions ka har runner apna ek naya debug keystore banata hai. Agar
// release APK debug key se sign hoti, to har nayi APK purani APK ke upar
// install hi nahi hoti ("signatures do not match"), yaani GitHub par naya
// release aata hai par phone par update nahi hota. Is liye ek FIXED key
// (android/key.properties + android/app/noor-release.p12) use karo.
//
// Key na ho to debug key par wapas aa jata hai, taaki `flutter run --release`
// laptop par chalte rahe.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val hasReleaseKey = keystorePropertiesFile.exists()

android {
    namespace = "com.sunesra_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs Java 8 core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sunesra_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        multiDexEnabled = true
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                // storeFile key.properties me module ke hisaab se relative hai.
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeType = keystoreProperties.getProperty("storeType", "PKCS12")
            }
        }
    }

    buildTypes {
        release {
            // FIXED release key jab tak key.properties maujood hai, warna debug key.
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Resource shrinking band karo.
            //
            // Flutter ka apna plugin release par ise khol deta hai, aur
            // shrinker un resources ko *silently* kaat deta hai jo sirf
            // `Resources.getIdentifier()` se padhe jaate hain — code me koi
            // `R.raw.x` reference nahi, isliye res/raw ke chaaron azaan clips
            // APK se gayab ho jaati thin. Native player ko "resId == 0" milta
            // tha, `AzaanAudio` "nothing to play" likhta tha, aur Azaan bajta
            // hi nahi tha — debug me bhi nahi, kyunki resource to banta hi nahi.
            //
            // Is app me dynamic lookups kaafi hain (awnings, widget, icon
            // variants), to shrinker ka faayda bhi kam tha: kuch MB ke liye
            // Azaan chup ho jana kharab soda hai.
            isShrinkResources = false
        }
    }
}

// Flutter ka plugin apni configuration `afterEvaluate` ke andar bhi kar sakta
// hai, jahan wo upar likhi value ko dobara overwrite kar de. Ye sabse aakhir
// chalta hai, isliye shrinker kabhi wapas na aaye — yahi guarantee deta hai.
afterEvaluate {
    android.buildTypes.findByName("release")?.isShrinkResources = false
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
