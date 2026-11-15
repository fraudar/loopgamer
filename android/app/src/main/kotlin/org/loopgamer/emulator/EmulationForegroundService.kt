package org.loopgamer.emulator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

class EmulationForegroundService : Service() {

    companion object {
        private const val TAG = "LoopGamerFGS"
        private const val CHANNEL_ID = "loopgamer_emulation_playback"
        private const val NOTIFICATION_ID = 4101

        const val ACTION_START = "org.loopgamer.emulator.action.START_EMULATION_FGS"
        const val ACTION_STOP = "org.loopgamer.emulator.action.STOP_EMULATION_FGS"
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_PAUSED = "extra_paused"

        @Volatile
        var isActive: Boolean = false
            private set

        fun start(context: Context, title: String, paused: Boolean = false) {
            val appCtx = context.applicationContext
            val intent = Intent(appCtx, EmulationForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title.ifBlank { "LoopGamer" })
                putExtra(EXTRA_PAUSED, paused)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    appCtx.startForegroundService(intent)
                } else {
                    appCtx.startService(intent)
                }
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao iniciar EmulationForegroundService: ${t.message}")
            }
        }

        fun update(context: Context, title: String, paused: Boolean) {
            if (!isActive) return
            val appCtx = context.applicationContext
            val nm = appCtx.getSystemService(NotificationManager::class.java) ?: return
            ensureChannel(nm)
            val notification = buildNotification(appCtx, title.ifBlank { "LoopGamer" }, paused)
            try {
                nm.notify(NOTIFICATION_ID, notification)
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao atualizar notificação do FGS: ${t.message}")
            }
        }

        fun stop(context: Context) {
            isActive = false
            val appCtx = context.applicationContext
            try {
                appCtx.stopService(Intent(appCtx, EmulationForegroundService::class.java))
            } catch (t: Throwable) {
                Log.w(TAG, "Falha ao parar EmulationForegroundService: ${t.message}")
            }
        }

        private fun ensureChannel(nm: NotificationManager) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        CHANNEL_ID,
                        "Emulação LoopGamer",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "Mantém a sessão de emulação e áudio ativa"
                        setSound(null, null)
                        enableVibration(false)
                        setShowBadge(false)
                    }
                    nm.createNotificationChannel(channel)
                }
            }
        }

        private fun buildNotification(
            context: Context,
            title: String,
            paused: Boolean
        ): Notification {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val pendingIntent = PendingIntent.getActivity(
                context,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val statusText = if (paused) "Emulação pausada" else "Emulação em andamento"
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            return builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(statusText)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setContentIntent(pendingIntent)
                .build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java)?.let { ensureChannel(it) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            isActive = false
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE)?.ifBlank { "LoopGamer" } ?: "LoopGamer"
        val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false

        getSystemService(NotificationManager::class.java)?.let { ensureChannel(it) }
        val notification = buildNotification(this, title, paused)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isActive = true
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        isActive = false
        stopForegroundCompat()
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        isActive = false
        stopForegroundCompat()
        super.onDestroy()
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
}
