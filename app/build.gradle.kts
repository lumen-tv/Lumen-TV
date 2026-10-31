// AGP 9 compiles Kotlin itself ("built-in Kotlin"), so there is no
// org.jetbrains.kotlin.android plugin here — only the Compose compiler plugin.
// KSP runs Room's code generator (like a Swift macro, but as a build step).
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

// The app's version. Bump this to publish an update: when it reaches main, the Release
// workflow builds the APK and puts it on GitHub Releases, and the TV offers it.
val lumenVersion = "0.8.0"

android {
    namespace = "com.hayat.lumen"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.hayat.lumen"
        minSdk = 29
        targetSdk = 37
        versionName = lumenVersion
        // Android only installs an update with a higher versionCode, so derive it from the
        // version name: 0.2.0 → 200, 1.4.12 → 10412. (Was hand-set to 2 before 0.2.0.)
        versionCode = lumenVersion.split('.').map(String::toInt).let { (major, minor, patch) ->
            major * 10_000 + minor * 100 + patch
        }
    }

    signingConfigs {
        // A shared debug key checked into the repo, so an APK built in a cloud
        // session and one built on your laptop can be installed over each other.
        // (Android refuses an update signed with a different key, which would
        // force an uninstall and wipe your playlists/favourites.)
        getByName("debug") {
            storeFile = rootProject.file("keystore/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
        // The private release key. It lives only on Hayat's Mac (backed up) and in the repo's
        // GitHub Actions secrets, never in the repo: anyone holding it could sign an "update"
        // that every installed Lumen would accept. The Release workflow passes it in through
        // these environment variables.
        val releaseKeystore = providers.environmentVariable("LUMEN_KEYSTORE").orNull
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = providers.environmentVariable("LUMEN_KEYSTORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("LUMEN_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("LUMEN_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Published releases are signed with the private key (see above). Without it (a release
            // built on a laptop or in a cloud session) the shared debug key is used, so it installs
            // for testing, but it can't update a TV that has a published release, and vice versa.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    testOptions {
        // Lets plain JVM unit tests call android.util.Log etc. without crashing.
        unitTests.isReturnDefaultValues = true
    }

    lint {
        // TV banners conventionally ship as a single xhdpi bitmap.
        disable += "IconMissingDensityFolder"
    }
}

dependencies {
    // The code shared with the iPhone/iPad app (playlist parsing, names, keys).
    implementation(project(":shared"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.kotlinx.coroutines.android)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.androidx.tv.material)

    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    implementation(libs.androidx.media3.exoplayer)
    implementation(libs.androidx.media3.exoplayer.hls)
    implementation(libs.androidx.media3.datasource.okhttp)
    implementation(libs.androidx.media3.ui.compose)
    implementation(libs.androidx.media3.ui)

    implementation(libs.okhttp)
    // Coil loads channel logos (like Kingfisher/Nuke on iOS), over the app's OkHttp client.
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    testImplementation(libs.junit)
    testImplementation(libs.kxml2)
}

ksp {
    // Room writes its schema JSON here so future migrations can be checked against it.
    arg("room.schemaLocation", "$projectDir/schemas")
    arg("room.generateKotlin", "true")
}
