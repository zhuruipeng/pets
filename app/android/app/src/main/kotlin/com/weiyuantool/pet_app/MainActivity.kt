package com.weiyuantool.pet_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新的原生侧：把下载好的 APK 交给系统安装器。
 *
 * Dart 侧做不了这件事，只能走平台通道：
 * 1. 拉起安装界面需要 Intent，Dart 没有对应能力；
 * 2. Android 7.0 起必须把文件包成 content:// URI（FileProvider），
 *    直接用 file:// 会抛 FileUriExposedException。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.weiyuantool.pet_app/installer"

        /** APK 的 MIME 类型。装包必须带它，否则系统不知道该由谁处理。 */
        const val APK_MIME = "application/vnd.android.package-archive"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        result.success(path != null && installApk(path))
                    }

                    "openInstallSettings" -> {
                        openInstallSettings()
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 返回 false 表示**没能拉起安装器**（缺授权或文件不在），
     * Dart 侧收到 false 会提示用户去系统设置授权。
     */
    private fun installApk(path: String): Boolean {
        return try {
            // Android 8.0+ 的「安装未知应用」是按应用单独授权的。
            // 没授权就 startActivity，系统会静默丢弃这个 Intent，
            // 用户只看到「点了没反应」—— 所以这里必须先查、先引导。
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                openInstallSettings()
                return false
            }

            val file = File(path)
            if (!file.exists()) return false

            // authority 必须与 AndroidManifest 里声明的完全一致，
            // 拼错会抛 IllegalArgumentException，表现同样是「点了没反应」。
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 跳到本应用的「安装未知应用」授权页。 */
    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (_: Exception) {
            // 个别 ROM 没有这个页面，忽略即可 —— 用户也能自己去设置里找。
        }
    }
}
