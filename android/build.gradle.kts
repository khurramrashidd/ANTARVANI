allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ANTARVANI plugin compileSdk override
// Every Flutter plugin carries its own compileSdk, hardcoded by the plugin's
// author — geocoding_android pins 33, while the AndroidX libraries it needs
// require 34 or later. Nothing in android/app can change that, so raise it
// for every module here. Remove this block and the build fails with
// "requires ... compile against version 34 or later of the Android APIs".
val ANTARVANI_SDK = 36
subprojects {
    val raiseCompileSdk = {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            runCatching {
                androidExt.javaClass.methods
                    .first { it.name == "setCompileSdk" && it.parameterTypes.size == 1 }
                    .invoke(androidExt, ANTARVANI_SDK)
            }
        }
    }
    if (state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
