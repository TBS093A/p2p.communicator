package com.p2pcommunicator.p2p_communicator

import android.app.Activity
import android.content.Intent
import com.google.android.play.core.appupdate.AppUpdateInfo
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Play build: asks Google Play whether a newer version is published and
 * starts Play's own update screen. No download or install code of our own
 * (Play policy forbids it).
 */
class StoreUpdater(private val activity: Activity, @Suppress("unused") private val channel: MethodChannel) {
    private val manager = AppUpdateManagerFactory.create(activity)
    private var lastInfo: AppUpdateInfo? = null

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "store" -> result.success("play")
            "playCheck" -> manager.appUpdateInfo
                .addOnSuccessListener { info ->
                    lastInfo = info
                    val available = info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE ||
                        info.updateAvailability() == UpdateAvailability.DEVELOPER_TRIGGERED_UPDATE_IN_PROGRESS
                    result.success(
                        mapOf(
                            "available" to available,
                            "code" to info.availableVersionCode().toLong(),
                            "immediate" to info.isUpdateTypeAllowed(AppUpdateType.IMMEDIATE),
                        ),
                    )
                }
                // Sideloaded copies, no Play account, no Play services: just
                // "nothing to report".
                .addOnFailureListener { e -> result.error("play-unavailable", e.message, null) }
            "playUpdate" -> {
                val info = lastInfo
                if (info == null) {
                    result.error("no-check", "check first", null)
                } else {
                    val started = manager.startUpdateFlowForResult(
                        info,
                        activity,
                        AppUpdateOptions.defaultOptions(AppUpdateType.IMMEDIATE),
                        REQUEST_CODE,
                    )
                    result.success(started)
                }
            }
            else -> return false
        }
        return true
    }

    fun onNewIntent(@Suppress("UNUSED_PARAMETER") intent: Intent) {}

    fun dispose() {}

    companion object {
        private const val REQUEST_CODE = 4711
    }
}
