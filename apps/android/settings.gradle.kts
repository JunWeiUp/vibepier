pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "VibePier"
include(":app")

include(":installProbe")
project(":installProbe").projectDir = file("test-fixtures/install-probe")
