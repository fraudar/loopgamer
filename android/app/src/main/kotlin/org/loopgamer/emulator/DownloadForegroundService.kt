package org.loopgamer.emulator

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Foreground Service `dataSync` responsável por manter downloads de ROMs ativos
 * com WakeLock/WifiLock mesmo com a tela desligada ou o app em segundo plano.
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val TAG = "LoopGamerDownloadFGS"
        private const val CHANNEL_ID = "loopgamer_downloads_channel"
        private const val CHANNEL_NAME = "Downloads de ROMs"
        private const val NOTIFICATION_ID = 4102
        private const val COMPLETION_NOTIFICATION_ID = NOTIFICATION_ID + 1

        const val ACTION_SYNC = "org.loopgamer.emulator.action.SYNC_DOWNLOAD_FGS"
        const val ACTION_STOP = "org.loopgamer.emulator.action.STOP_DOWNLOAD_FGS"

        const val EXTRA_ACTIVE_COUNT = "activeCount"
        const val EXTRA_QUEUED_COUNT = "queuedCount"
        const val EXTRA_COMPLETED_COUNT = "completedCount"
        const val EXTRA_FAILED_COUNT = "failedCount"
        const val EXTRA_PROGRESS_PERCENT = "progressPercent"
        const val EXTRA_INDETERMINATE = "indeterminate"
        const val EXTRA_TITLE = "title"
        const val EXTRA_DETAIL = "detail"
        private const val EXTRA_STARTED_AS_FOREGROUND = "startedAsForeground"

        @Volatile
        var isActive: Boolean = false
            private set

        @Volatile
        var hasPendingOrActiveStart: Boolean = false

        fun buildSyncIntent(
            context: Context,
            activeCount: Int,
            queuedCount: Int,
            completedCount: Int,
            failedCount: Int,
            progressPercent: Int,
            indeterminate: Boolean,
            title: String,
            detail: String,
            startedAsForeground: Boolean = true
        ): Intent {
            return Intent(context.applicationContext, DownloadForegroundService::class.java).apply {
                action = ACTION_SYNC
                putExtra(EXTRA_ACTIVE_COUNT, activeCount)
                putExtra(EXTRA_QUEUED_COUNT, queuedCount)
                putExtra(EXTRA_COMPLETED_COUNT, completedCount)
                putExtra(EXTRA_FAILED_COUNT, failedCount)
                putExtra(EXTRA_PROGRESS_PERCENT, progressPercent)
                putExtra(EXTRA_INDETERMINATE, indeterminate)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_DETAIL, detail)
                putExtra(EXTRA_STARTED_AS_FOREGROUND, startedAsForeground)
            }
        }

        fun buildStopIntent(
            context: Context,
            completedCount: Int = 0,
            failedCount: Int = 0,
            title: String = "",
            detail: String = ""
        ): Intent {
            return Intent(context.applicationContext, DownloadForegroundService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_ACTIVE_COUNT, 0)
                putExtra(EXTRA_QUEUED_COUNT, 0)
                putExtra(EXTRA_COMPLETED_COUNT, completedCount)
                putExtra(EXTRA_FAILED_COUNT, failedCount)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_DETAIL, detail)
            }
        }

        fun stopNowAndNotifyCompletion(
            context: Context,
            completedCount: Int,
            failedCount: Int,
            title: String,
            detail: String
        ) {
            isActive = false
            hasPendingOrActiveStart = false
            val appCtx = context.applicationContext
            try {
                appCtx.stopService(Intent(appCtx, DownloadForegroundService::class.java))
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao parar DownloadForegroundService: ${t.message}")
            }
            val nm = appCtx.getSystemService(NotificationManager::class.java)
            if (nm != null) {
                ensureChannel(nm)
                try {
                    nm.cancel(NOTIFICATION_ID)
                } catch (_: Throwable) {
                }
                postCompletionNotificationIfNeeded(
                    context = appCtx,
                    nm = nm,
                    completedCount = completedCount,
                    failedCount = failedCount,
                    title = title,
                    detail = detail
                )
            }
        }

        private fun ensureChannel(nm: NotificationManager) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        CHANNEL_ID,
                        CHANNEL_NAME,
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "Progresso e conclusão de downloads de ROMs em segundo plano"
                        setSound(null, null)
                        enableVibration(false)
                        setShowBadge(false)
                    }
                    nm.createNotificationChannel(channel)
                }
            }
        }

        private fun createLaunchPendingIntent(context: Context, requestCode: Int): PendingIntent {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            return PendingIntent.getActivity(
                context,
                requestCode,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        private fun buildNotificationBuilder(context: Context): Notification.Builder {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
        }

        private fun buildProgressNotification(
            context: Context,
            activeCount: Int,
            queuedCount: Int,
            progressPercent: Int,
            indeterminate: Boolean,
            title: String,
            detail: String
        ): Notification {
            val resolvedTitle = title.ifBlank {
                if (activeCount > 1) "Baixando $activeCount ROMs" else "Baixando ROM"
            }
            val resolvedDetail = detail.ifBlank {
                buildString {
                    append(if (activeCount > 0) "$activeCount ativo(s)" else "Preparando download")
                    if (queuedCount > 0) {
                        append(" • ")
                        append(queuedCount)
                        append(" na fila")
                    }
                }
            }
            val clampedProgress = progressPercent.coerceIn(0, 100)
            val builder = buildNotificationBuilder(context)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(resolvedTitle)
                .setContentText(resolvedDetail)
                .setProgress(100, clampedProgress, indeterminate)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setContentIntent(createLaunchPendingIntent(context, 0))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }

        private fun canPostNotifications(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
            return ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        }

        private fun postCompletionNotificationIfNeeded(
            context: Context,
            nm: NotificationManager,
            completedCount: Int,
            failedCount: Int,
            title: String,
            detail: String
        ) {
            if (completedCount <= 0 && failedCount <= 0) return
            if (!canPostNotifications(context)) return

            val resolvedTitle = title.ifBlank {
                when {
                    failedCount > 0 && completedCount == 0 ->
                        if (failedCount == 1) "Falha no download" else "Falhas nos downloads"
                    failedCount > 0 -> "Downloads finalizados"
                    completedCount == 1 -> "Download concluído"
                    else -> "Downloads concluídos"
                }
            }
            val resolvedDetail = detail.ifBlank {
                when {
                    failedCount > 0 && completedCount > 0 ->
                        "$completedCount concluído(s), $failedCount falha(s)"
                    failedCount > 0 ->
                        if (failedCount == 1) "1 download falhou" else "$failedCount downloads falharam"
                    completedCount == 1 -> "1 ROM pronta na biblioteca"
                    else -> "$completedCount ROMs prontas na biblioteca"
                }
            }

            val notification = buildNotificationBuilder(context)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(resolvedTitle)
                .setContentText(resolvedDetail)
                .setOngoing(false)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setContentIntent(createLaunchPendingIntent(context, 1))
                .build()

            try {
                nm.notify(COMPLETION_NOTIFICATION_ID, notification)
            } catch (se: SecurityException) {
                Log.w(TAG, "Sem permissão para notificação de conclusão: ${se.message}")
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao exibir notificação de conclusão: ${t.message}")
            }
        }
    }

    private val lockSync = Any()
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java)?.let { ensureChannel(it) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm != null) {
            ensureChannel(nm)
        }

        val action = intent?.action
        val activeCount = intent?.getIntExtra(EXTRA_ACTIVE_COUNT, 0) ?: 0
        val queuedCount = intent?.getIntExtra(EXTRA_QUEUED_COUNT, 0) ?: 0
        val completedCount = intent?.getIntExtra(EXTRA_COMPLETED_COUNT, 0) ?: 0
        val failedCount = intent?.getIntExtra(EXTRA_FAILED_COUNT, 0) ?: 0
        val progressPercent = intent?.getIntExtra(EXTRA_PROGRESS_PERCENT, 0) ?: 0
        val indeterminate = intent?.getBooleanExtra(EXTRA_INDETERMINATE, false) ?: false
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: ""
        val detail = intent?.getStringExtra(EXTRA_DETAIL) ?: ""
        val startedAsForeground = intent?.getBooleanExtra(EXTRA_STARTED_AS_FOREGROUND, false) ?: false

        val hasWork = action != ACTION_STOP && (activeCount > 0 || queuedCount > 0)
        if (hasWork) {
            val notification = buildProgressNotification(
                context = this,
                activeCount = activeCount,
                queuedCount = queuedCount,
                progressPercent = progressPercent,
                indeterminate = indeterminate,
                title = title,
                detail = detail
            )
            startForegroundCompat(notification)
            acquireLocks()
            isActive = true
            hasPendingOrActiveStart = true
            return START_NOT_STICKY
        }

        if (startedAsForeground && !isActive) {
            // Cumpre o contrato de startForegroundService() antes de encerrar em caso de corrida.
            val placeholder = buildProgressNotification(
                context = this,
                activeCount = 0,
                queuedCount = 0,
                progressPercent = 100,
                indeterminate = false,
                title = title,
                detail = detail
            )
            startForegroundCompat(placeholder)
        }

        try {
            stopForegroundCompat()
            if (nm != null) {
                postCompletionNotificationIfNeeded(
                    context = this,
                    nm = nm,
                    completedCount = completedCount,
                    failedCount = failedCount,
                    title = title,
                    detail = detail
                )
            }
        } finally {
            isActive = false
            hasPendingOrActiveStart = false
            releaseLocks()
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isActive = false
        hasPendingOrActiveStart = false
        try {
            stopForegroundCompat()
        } finally {
            releaseLocks()
            super.onDestroy()
        }
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }

    private fun acquireLocks() {
        synchronized(lockSync) {
            try {
                if (wakeLock == null) {
                    val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                    wakeLock = pm?.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "loopgamer:DownloadWakeLock"
                    )?.apply {
                        setReferenceCounted(false)
                    }
                }
                if (wakeLock?.isHeld != true) {
                    wakeLock?.acquire()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao adquirir WakeLock: ${t.message}")
            }

            try {
                if (wifiLock == null) {
                    val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                    val wifiMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                    } else {
                        @Suppress("DEPRECATION")
                        WifiManager.WIFI_MODE_FULL_HIGH_PERF
                    }
                    wifiLock = wm?.createWifiLock(wifiMode, "loopgamer:DownloadWifiLock")?.apply {
                        setReferenceCounted(false)
                    }
                }
                if (wifiLock?.isHeld != true) {
                    wifiLock?.acquire()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao adquirir WifiLock: ${t.message}")
            }
            Unit
        }
    }

    private fun releaseLocks() {
        synchronized(lockSync) {
            try {
                try {
                    if (wakeLock?.isHeld == true) {
                        wakeLock?.release()
                    }
                } catch (_: Throwable) {
                } finally {
                    wakeLock = null
                }
            } finally {
                try {
                    if (wifiLock?.isHeld == true) {
                        wifiLock?.release()
                    }
                } catch (_: Throwable) {
                } finally {
                    wifiLock = null
                }
            }
        }
    }
}
