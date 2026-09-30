import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- 发布签名 ----
//
// 自动更新对签名有一条硬要求：**新包的签名必须和手机上已装的包一致**，
// 否则系统直接拒装（用户看到的是「应用未安装」，没有任何解释）。
// 所以发布包不能再用 debug 签名 —— debug keystore 是每台机器各自生成的，
// 换台电脑、重装系统，签名就变了，老用户全部卡住更新不了。
//
// 这里的做法是「有 key.properties 就用正式签名，没有就退回 debug」：
// - `android/key.properties` 不进版本库（已在 .gitignore 里），
//   内含 storeFile / storePassword / keyAlias / keyPassword 四项；
// - 没配的机器照样能 `flutter run --release`，不会因为缺密钥而构建失败。
//
// ⚠️ 一旦开始分发，**keystore 与 key.properties 要单独备份**。
// 丢了就只能让所有用户卸载重装，没有别的补救办法。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.weiyuantool.pet_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 用到了 java.time 这类 Java 8+ API，
        // 低版本 Android 上没有。不开脱糖，:app:checkReleaseAarMetadata 会直接判死：
        //   "Dependency ':flutter_local_notifications' requires core library
        //    desugaring to be enabled for :app."
        // 配套的 desugar_jdk_libs 依赖在文件底部的 dependencies 块里。
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        // 兜底值：**flavor 会覆盖它**，这里只是让不带 flavor 的
        // 临时构建也能有东西可用。真正生效的见 productFlavors。
        applicationId = "com.weiyuantool.pet_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        //
        // 这个值也是自动更新比对的依据：服务端 version.json 里的 build
        // 与这里的 versionCode 比大小，**改完代码要发新版，记得抬 pubspec 的 version**。
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 题外话：minSdk ≥ 21 时 AGP 本来就会自动开 multidex，
        // 这里写上只是为了跟 flutter_local_notifications 的官方 README 对齐。
        multiDexEnabled = true
    }

    // ---- 双市场分包 ----
    //
    // 两个包是**两个独立的应用**：不同 applicationId，能同时装在一台手机上。
    // 这样测试时不用卸载重装就能对比两区行为。
    //
    // ⚠️ cn 的 applicationId 必须保持 com.weiyuantool.pet_app 不变 ——
    // 已经装在用户手机上的包就是这个 id，改了等于换应用，老用户收不到更新。
    //
    // ⚠️ 定了 flavor 之后 **`flutter build apk` 必须带 `--flavor`**，
    // 不带会直接报「You must specify a --flavor option」。
    //
    // REGION 编译期常量没法从 Gradle 注入，必须靠
    // `--dart-define=REGION=xx`（或用 tool/build_apk.ps1 那个脚本，
    // 它把 flavor 和 REGION 绑在一起，避免漏传导致「包是 cn、行为是 intl」）。
    flavorDimensions += "market"

    productFlavors {
        create("cn") {
            dimension = "market"
            applicationId = "com.weiyuantool.pet_app"
            // 桌面图标下的名字见 src/cn/res/values/strings.xml。
            //
            // ⚠️ 别改回 resValue("string", "app_name", ...)：
            // AGP 9.0 起 flavor 里的自定义资源值**默认被禁用**，构建会直接失败：
            //   "Product Flavor cn contains custom resource values, but the
            //    feature is disabled."
            // Flutter 官方文档《Set up Flutter flavors for Android》给的替代写法，
            // 就是每个 flavor 放一份 res/values/strings.xml。
        }
        create("intl") {
            dimension = "market"
            applicationId = "com.weiyuantool.pet"
            // 同上，见 src/intl/res/values/strings.xml。
        }
    }

    buildTypes {
        release {
            // 配了 key.properties 用正式签名；没配则退回 debug（本地自测够用）。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 核心库脱糖的实现库。版本 2.1.4 是 flutter_local_notifications 官方 README
    // 指定的（AGP 7.4+ 用 2.x；再老的 AGP 才用 1.2.x）。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // MainActivity 里用 FileProvider 把下载好的 APK 交给系统安装器。
    // 它属于 androidx.core —— 虽然别的插件多半会传递依赖进来，
    // 但显式声明才不会被上游哪天改依赖树时连累（编译期找不到类比运行期报错难查得多）。
    implementation("androidx.core:core-ktx:1.13.1")
}
