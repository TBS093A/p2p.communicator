package com.p2pcommunicator.p2p_communicator

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * GitHub build: installs an update APK the app downloaded and checksummed.
 *
 * Before handing it to the system it checks the APK is this app, newer, and
 * signed with the same certificate (Android would refuse otherwise anyway,
 * but this gives a clear message instead of a generic failure). The system
 * then always asks the user to confirm.
 */
class StoreUpdater(private val activity: Activity, private val channel: MethodChannel) {

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "store" -> result.success("github")
            "canInstall" -> result.success(canInstall())
            "openInstallSettings" -> {
                if (Build.VERSION.SDK_INT >= 26) {
                    activity.startActivity(
                        Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}"),
                        ),
                    )
                }
                result.success(null)
            }
            "install" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad-args", "path missing", null)
                } else {
                    try {
                        install(File(path))
                        result.success(null)
                    } catch (e: UpdateRejected) {
                        result.error(e.code, e.message, null)
                    } catch (e: Exception) {
                        result.error("install-failed", e.message, null)
                    }
                }
            }
            else -> return false
        }
        return true
    }

    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()

    private class UpdateRejected(val code: String, message: String) : Exception(message)

    private fun install(apk: File) {
        if (!apk.isFile) throw UpdateRejected("missing", "update file is gone")
        checkSameApp(apk)
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(activity.packageName)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("update.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val status = Intent(activity, MainActivity::class.java).setAction(ACTION_STATUS)
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            // The system adds the status extras, so it must be mutable.
            if (Build.VERSION.SDK_INT >= 31) flags = flags or PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getActivity(activity, id, status, flags)
            session.commit(pending.intentSender)
        }
    }

    /** Same package, newer version, same signing certificate. */
    private fun checkSameApp(apk: File) {
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else 0
        @Suppress("DEPRECATION")
        val archive = pm.getPackageArchiveInfo(apk.path, flags)
            ?: throw UpdateRejected("not-apk", "not an Android package")
        if (archive.packageName != activity.packageName) {
            throw UpdateRejected("other-app", "the file is a different app")
        }
        val installed = pm.getPackageInfo(activity.packageName, flags)
        val newCode = if (Build.VERSION.SDK_INT >= 28) archive.longVersionCode else {
            @Suppress("DEPRECATION")
            archive.versionCode.toLong()
        }
        val oldCode = if (Build.VERSION.SDK_INT >= 28) installed.longVersionCode else {
            @Suppress("DEPRECATION")
            installed.versionCode.toLong()
        }
        if (newCode <= oldCode) throw UpdateRejected("not-newer", "not newer than this version")
        // Older Android cannot read signatures from an archive reliably; the
        // installer still enforces a matching key there.
        if (Build.VERSION.SDK_INT >= 28) {
            val want = installed.signingInfo?.apkContentsSigners?.map { sha256(it.toByteArray()) }?.toSet()
            val got = archive.signingInfo?.apkContentsSigners?.map { sha256(it.toByteArray()) }?.toSet()
            if (want.isNullOrEmpty() || got.isNullOrEmpty() || want != got) {
                throw UpdateRejected("bad-signature", "signed with a different key")
            }
        }
    }

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    fun onNewIntent(intent: Intent) {
        if (intent.action != ACTION_STATUS) return
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm != null) activity.startActivity(confirm)
                channel.invokeMethod("installStatus", mapOf("status" to "confirm"))
            }
            PackageInstaller.STATUS_SUCCESS ->
                channel.invokeMethod("installStatus", mapOf("status" to "done"))
            else -> channel.invokeMethod(
                "installStatus",
                mapOf(
                    "status" to if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "cancelled" else "failed",
                    "message" to intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
                ),
            )
        }
    }

    fun dispose() {}

    companion object {
        private const val ACTION_STATUS = "com.p2pcommunicator.INSTALL_STATUS"
    }
}
