pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "smartbee-pixel-android"
include(":pixel")

// React Native körpüsünün Android kodunun yığıldığını yoxlamaq üçün (buradan dərc olunmur).
include(":rn-bridge")
project(":rn-bridge").projectDir = file("../react-native/android")
