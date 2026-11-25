plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

group = "az.smartbee"
version = "1.0.0"

// Açıq API dondurulur: hər açıq elan `public` yazılmalıdır, yoxsa yığım alınmır (təsadüfən açıq qalan sinif olmasın).
kotlin {
    explicitApi()
}

android {
    namespace = "az.smartbee.pixel"
    compileSdk = 35

    defaultConfig {
        minSdk = 21
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
        // Kitabxana Kotlin 1.9 ilə yığılan tətbiqlərdə də işləməlidir: metadata və stdlib 1.9 səviyyəsində qalır.
        languageVersion = "1.9"
        apiVersion = "1.9"
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
        unitTests.isIncludeAndroidResources = true
    }
}

// SDK-nın iş vaxtı asılılığı yoxdur: yalnız Android platforması və Kotlin stdlib.
// Plaginin öz (2.x) stdlib-i əlavə olunmur (gradle.properties); dərc olunan POM-da 1.9 versiyası göstərilir.
dependencies {
    api("org.jetbrains.kotlin:kotlin-stdlib:1.9.25")
    testImplementation("junit:junit:4.13.2")
    // Android-in org.json sinifləri JVM testlərində boşdur; real tətbiq işlədilir.
    testImplementation("org.json:json:20240303")
    testImplementation("com.networknt:json-schema-validator:1.5.6")
    // Android-ə bağlı qat (SQLite, Context) JVM-də Robolectric ilə yoxlanır.
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("androidx.test:core:1.6.1")
}

tasks.withType<Test>().configureEach {
    // Testlər topluları ortaq spesifikasiyanın sxemi və vektorları ilə yoxlayır.
    systemProperty("spec.dir", rootProject.file("../../spec").absolutePath)
    // Sxem və ya ortaq vektorlar dəyişəndə testlər yenidən işləməlidir (yoxsa Gradle nəticəni UP-TO-DATE sayar).
    inputs.dir(rootProject.file("../../spec/schema")).withPropertyName("specSchema").withPathSensitivity(PathSensitivity.RELATIVE)
    inputs.dir(rootProject.file("../../spec/vectors")).withPropertyName("specVectors").withPathSensitivity(PathSensitivity.RELATIVE)
    // Robolectric-in asılılığı (Conscrypt) türk / Azərbaycan dil ayarında öz nativ faylının adını səhv qurur
    // ("WINDOWS" -> "wındows"). Testlər neytral dil ayarı ilə işlədilir.
    jvmArgs("-Duser.language=en", "-Duser.country=US")
}

// Maven paketi: az.smartbee:pixel.
afterEvaluate {
    publishing {
        // Öz Maven repo-muz (https://c.cdnsb.net/maven): fayllar backend-in verdiyi qovluğa yazılır.
        //   ./gradlew :pixel:publishReleasePublicationToCdnRepository -PsmartbeeMavenDir=<qovluq>
        repositories {
            maven {
                name = "cdn"
                url = uri(findProperty("smartbeeMavenDir") ?: layout.buildDirectory.dir("maven").get().asFile)
            }
        }
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = "pixel"
                pom {
                    name.set("SmartBee Pixel")
                    description.set("SmartBee Pixel SDK for Android")
                    url.set("https://github.com/Smart-Bee-Azerbaijan/pixel-sdk")
                    licenses {
                        license {
                            name.set("MIT License")
                            url.set("https://opensource.org/licenses/MIT")
                        }
                    }
                    developers {
                        developer {
                            id.set("smartbee")
                            name.set("SmartBee")
                        }
                    }
                    scm {
                        url.set("https://github.com/Smart-Bee-Azerbaijan/pixel-sdk")
                        connection.set("scm:git:https://github.com/Smart-Bee-Azerbaijan/pixel-sdk.git")
                    }
                }
            }
        }
    }
}
