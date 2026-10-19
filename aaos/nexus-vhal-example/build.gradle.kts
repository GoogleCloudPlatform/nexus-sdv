plugins {
    // AGP 9.0+ has built-in Kotlin support — the org.jetbrains.kotlin.android
    // plugin is no longer applied (AGP provides the Kotlin toolchain).
    id("com.android.application") version "9.2.1" apply false
    id("com.google.protobuf") version "0.10.0" apply false
}
