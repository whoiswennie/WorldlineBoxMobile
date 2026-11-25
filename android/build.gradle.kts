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
    if (name == "image_picker_android") {
        plugins.withId("com.android.library") {
            extensions.getByType<com.android.build.api.variant.LibraryAndroidComponentsExtension>().finalizeDsl {
                // AGP 9.3.1's CommentDetector crashes parsing this plugin's JavaDoc.
                it.lint.disable.addAll(setOf("EasterEgg", "StopShip"))
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
