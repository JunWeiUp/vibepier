import java.util.Random
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

plugins { id("com.android.application") }

abstract class GenerateProbePayload : DefaultTask() {
    @get:Input abstract val fixtureSeed: Property<Long>
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty
    @TaskAction fun generate() {
        val directory = outputDirectory.get().asFile.apply { mkdirs() }
        // Incompressible synthetic bytes ensure the resume probe spans multiple 1 MiB binary durable writes.
        val bytes = ByteArray(3 * 1024 * 1024)
        Random(fixtureSeed.get()).nextBytes(bytes)
        directory.resolve("synthetic-payload.bin").writeBytes(bytes)
    }
}
val generatePayload by tasks.registering(GenerateProbePayload::class) {
    fixtureSeed.set(7351L)
    outputDirectory.set(layout.buildDirectory.dir("generated/probe-assets"))
}
android {
    namespace = "io.github.junweiup.vibepier.installprobe"
    compileSdk = 35
    defaultConfig {
        applicationId = "io.github.junweiup.vibepier.installprobe"
        minSdk = 33
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }
}
androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(generatePayload, GenerateProbePayload::outputDirectory)
    }
}
