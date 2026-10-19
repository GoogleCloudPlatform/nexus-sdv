import com.google.protobuf.gradle.id
import com.google.protobuf.gradle.proto
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("com.google.protobuf")
}

android {
    namespace = "io.nexussdv.vhalexample"
    compileSdk = 37 // Android 17 (API 37) — the AAOS SDV target

    defaultConfig {
        applicationId = "io.nexussdv.vhalexample"
        minSdk = 34
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
    }

    useLibrary("android.car")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_17
    }
}

// The message schema is not kept here: it is copied at build time from the repository's
// /proto directory, where the original lives (telemetry.proto, the native Nexus telemetry
// message).
val copySharedProtos = tasks.register<Copy>("copySharedProtos") {
    from("../../../proto") {
        include("telemetry.proto")
    }
    into(layout.buildDirectory.dir("shared-protos"))
}

android.sourceSets.getByName("main") {
    proto { srcDir(layout.buildDirectory.dir("shared-protos")) }
}

protobuf {
    protoc { artifact = "com.google.protobuf:protoc:4.35.1" }
    generateProtoTasks {
        all().forEach { task ->
            task.dependsOn(copySharedProtos)
            task.builtins { id("java") { option("lite") } }
        }
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("androidx.recyclerview:recyclerview:1.4.0")
    implementation("androidx.cardview:cardview:1.0.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("com.google.protobuf:protobuf-javalite:4.35.1")
    implementation("io.nats:jnats:2.26.0")

    testImplementation("junit:junit:4.13.2")
}
