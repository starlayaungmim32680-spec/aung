allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Works around a known upstream bug in the `camera` plugin's CameraX
// dependency: camera-core 1.5.x references a type-annotation class from
// androidx.concurrent:concurrent-futures that isn't on the compile
// classpath by default, causing every plugin subproject (not just
// camera_android_camerax) to fail to compile. withPlugin() fires as soon
// as each subproject applies the Android plugin, regardless of whether
// that's already happened or happens later - unlike afterEvaluate, this
// never fails with "already evaluated".
subprojects {
    pluginManager.withPlugin("com.android.library") {
        dependencies.add(
            "implementation",
            "androidx.concurrent:concurrent-futures:1.2.0"
        )
    }
    pluginManager.withPlugin("com.android.application") {
        dependencies.add(
            "implementation",
            "androidx.concurrent:concurrent-futures:1.2.0"
        )
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}