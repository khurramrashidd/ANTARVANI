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

// A plugin that does not carry its own Kotlin plugin is compiled by Flutter's
// built-in Kotlin, which targets the JVM that is running Gradle — 21 on a
// current Flutter. tflite_flutter's own build file still asks javac for 11,
// and Kotlin refuses to build a module whose two halves disagree:
//   Inconsistent JVM-target compatibility ... (11) and ... (21)
// Nothing in android/app can change another module's build file, so the
// module's Java level is raised here to whatever Kotlin is using. Only the
// modules named below are touched: raising one whose Kotlin target is
// deliberately low would cause the same clash the other way round.
val ANTARVANI_JVM_FIX = setOf("tflite_flutter")

subprojects {
    val fixModule = {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            runCatching {
                androidExt.javaClass.methods
                    .first { it.name == "setCompileSdk" && it.parameterTypes.size == 1 }
                    .invoke(androidExt, ANTARVANI_SDK)
            }
            if (ANTARVANI_JVM_FIX.contains(project.name)) {
                runCatching {
                    val opts = androidExt.javaClass.methods
                        .first {
                            it.name == "getCompileOptions" && it.parameterTypes.isEmpty()
                        }
                        .invoke(androidExt)!!
                    // AGP has spelled these setters differently over the
                    // years (JavaVersion, String, Object), so every one-argument
                    // overload is tried with both forms until one takes.
                    val here = JavaVersion.current()
                    for (setter in listOf("setSourceCompatibility", "setTargetCompatibility")) {
                        var done = false
                        for (m in opts.javaClass.methods) {
                            if (done || m.name != setter || m.parameterTypes.size != 1) continue
                            for (arg in listOf<Any>(here, here.toString())) {
                                if (!done && runCatching { m.invoke(opts, arg) }.isSuccess) {
                                    done = true
                                }
                            }
                        }
                        if (!done) {
                            logger.lifecycle(
                                "ANTARVANI: could not raise the Java level of " +
                                    project.name + " (" + setter + ")")
                        }
                    }
                }
            }
        }
    }
    if (state.executed) fixModule() else afterEvaluate { fixModule() }
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
