// Lumen's shared Kotlin code: used by the Android TV app (as a normal library) and by the
// iPhone/iPad app (as an Apple framework called "Shared", which Swift imports).
//
// Kotlin Multiplatform splits code into source sets: commonMain is plain Kotlin that runs
// everywhere; androidMain / iosMain hold the few platform-specific bits (`expect`/`actual`,
// roughly like `#if os(iOS)` but checked by the compiler).
plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.android.kotlin.multiplatform.library)
}

kotlin {
    android {
        namespace = "com.hayat.lumen.shared"
        compileSdk = 37
        minSdk = 29
        // Runs commonTest on the JVM too (./gradlew :shared:testAndroidHostTest).
        withHostTest {}
    }

    // iPhone/iPad devices, and the Simulator on Apple-silicon Macs.
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "Shared"
            isStatic = true
        }
    }

    // Not shipped anywhere: lets the shared tests run as native code on Linux (cloud sessions
    // can't run iOS), which checks the same native regex and string code the iPhone uses.
    linuxX64()

    applyDefaultHierarchyTemplate()

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.ktor.client.core)
            implementation(libs.kotlinx.serialization.json)
            implementation(libs.kotlinx.serialization.json.io)
            implementation(libs.kotlinx.io.core)
        }
        iosMain.dependencies {
            implementation(libs.ktor.client.darwin)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.ktor.client.mock)
            implementation(libs.kotlinx.coroutines.test)
        }
    }
}
