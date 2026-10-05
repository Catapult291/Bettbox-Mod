pluginManagement {
    val flutterSdkPath = run {
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
    id("com.android.application") version "8.12.2" apply false
    // 2.2.20 同时满足两端的 Kotlin 校验：CI 的 Flutter 3.44.9 报错线是 2.0.0、
    // 告警线 2.2.20；本机 Flutter 3.47.2 的报错线是 2.2.20、告警线 2.3.20。
    // 原先是 2.1.0，在 3.47.2 上直接构建失败（gradle.properties 里的 kotlin_version 未被使用，勿混淆）。
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
include(":core")