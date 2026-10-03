plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.junweiup.vibepier.remote"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.junweiup.vibepier.remote"
        testInstrumentationRunner = "io.github.junweiup.vibepier.remote.BindingSyncInstrumentation"
        minSdk = 33
        targetSdk = 35
        versionCode = rootProject.file("../../VERSION_CODE").readText().trim().toInt()
        versionName = rootProject.file("../../VERSION").readText().trim()
        buildConfigField("boolean", "DESIGN_REVIEW", "false")
    }

    testBuildType = "designReview"
    sourceSets.getByName("androidTest").assets.srcDir(layout.buildDirectory.dir("apk-probe-assets"))

    sourceSets.getByName("release").java.srcDir("src/production/java")
    sourceSets.getByName("debug").java.srcDir("src/production/java")
    sourceSets.getByName("test").resources.srcDir(rootProject.file("../../protocol/fixtures"))

    buildFeatures { buildConfig = true }

    val releaseKeystore = providers.environmentVariable("ANDROID_KEYSTORE_PATH").orNull
    if (!releaseKeystore.isNullOrBlank()) {
        signingConfigs.create("publicRelease") {
            storeFile = file(releaseKeystore)
            storePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").get()
            keyAlias = providers.environmentVariable("ANDROID_KEY_ALIAS").get()
            keyPassword = providers.environmentVariable("ANDROID_KEY_PASSWORD").get()
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Without release credentials, local release builds remain unsigned.
            signingConfig = signingConfigs.findByName("publicRelease")
        }
    }
    buildTypes.create("designReview") {
        initWith(buildTypes.getByName("release"))
        applicationIdSuffix = ".review"
        versionNameSuffix = "-review"
        isDebuggable = true
        signingConfig = signingConfigs.getByName("debug")
        buildConfigField("boolean", "DESIGN_REVIEW", "true")
        matchingFallbacks += listOf("release")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // JVM-only JSON reader for shared wire fixtures; the app uses Android's platform JSON.
    testImplementation("org.json:json:20250517")
}

// Reproducible PackageInstaller fixture; included only in the instrumentation APK.
val prepareApkProbeAssets by tasks.registering(Sync::class) {
    dependsOn(":installProbe:assembleDebug")
    from(project(":installProbe").layout.buildDirectory.dir("outputs/apk/debug")) {
        include("*.apk")
        rename { "apk-probe.apk" }
    }
    into(layout.buildDirectory.dir("apk-probe-assets"))
}
tasks.matching { it.name == "mergeDesignReviewAndroidTestAssets" }.configureEach { dependsOn(prepareApkProbeAssets) }
