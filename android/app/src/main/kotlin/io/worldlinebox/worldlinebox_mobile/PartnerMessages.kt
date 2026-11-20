package io.worldlinebox.worldlinebox_mobile

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

private const val MESSAGES = "partner_messages"
private const val CONNECTION = "partner_connection"
private const val SERVICE_ID = 1807
private const val OPEN = "io.worldlinebox.OPEN_CHAT"

private fun channels(context: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    context.getSystemService(NotificationManager::class.java).createNotificationChannels(listOf(
        NotificationChannel(MESSAGES, "伙伴消息", NotificationManager.IMPORTANCE_HIGH).apply { enableVibration(true) },
        NotificationChannel(CONNECTION, "后台连接", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) }
    ))
}

// The existing Flutter engine keeps the authenticated SSH event stream. This
// service gives that same process foreground priority while the app is parked.
class PartnerConnectionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        channels(this)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        startForeground(SERVICE_ID, NotificationCompat.Builder(this, CONNECTION)
            .setSmallIcon(R.drawable.ic_partner_message).setContentTitle(getText(R.string.app_name))
            .setContentText("正在监听已配对电脑的伙伴消息").setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW).setSilent(true).setContentIntent(open).build())
        return START_NOT_STICKY
    }
}

class PartnerMessages(private val activity: MainActivity, private val channel: MethodChannel) {
    private val manager = NotificationManagerCompat.from(activity)
    private val service = Intent(activity, PartnerConnectionService::class.java)
    private var pending: Map<String, String>? = null
    private var running = false
    private var resumed = false
    private var enabled = false
    private val prefs = activity.getSharedPreferences("message-alerts", Context.MODE_PRIVATE)
    init {
        channels(activity)
        accept(activity.intent)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "deviceName" -> result.success(Build.MODEL.take(80))
                    "version" -> result.success(activity.packageManager.getPackageInfo(activity.packageName, 0).versionName)
                    "configure" -> { enabled = call.arguments == true; updateService(); result.success(null) }
                    "settings" -> {
                        val intent = if (Build.VERSION.SDK_INT >= 26) Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
                        activity.startActivity(intent); result.success(null)
                    }
                    "take" -> { result.success(pending); pending = null }
                    "clear" -> { manager.cancel(call.arguments as String, 1); result.success(null) }
                    "reset" -> { enabled = false; updateService(); manager.cancelAll(); pending = null; result.success(null) }
                    "message" -> {
                        if (enabled && permitted()) {
                            val room = call.argument<String>("room")!!
                            val host = call.argument<String>("host")!!
                            val uri = Uri.Builder().scheme("worldlinebox").authority("chat").appendPath(host).appendPath(room).build()
                            val intent = Intent(activity, MainActivity::class.java).setAction(OPEN).setData(uri)
                                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                            val open = PendingIntent.getActivity(activity, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                            val note = NotificationCompat.Builder(activity, MESSAGES)
                                .setSmallIcon(R.drawable.ic_partner_message)
                                .setLargeIcon(BitmapFactory.decodeResource(activity.resources, R.mipmap.ic_launcher))
                                .setContentTitle(call.argument<String>("title")).setContentText(call.argument<String>("preview"))
                                .setCategory(NotificationCompat.CATEGORY_MESSAGE).setPriority(NotificationCompat.PRIORITY_HIGH)
                                .setDefaults(NotificationCompat.DEFAULT_ALL).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                                .setNumber(call.argument<Int>("count") ?: 1).setAutoCancel(true).setContentIntent(open).build()
                            manager.notify("$host/$room", 1, note)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("notifications", error.localizedMessage, null) }
        }
    }

    private fun permitted() = manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 26 ||
        activity.getSystemService(NotificationManager::class.java).getNotificationChannel(MESSAGES)?.importance != NotificationManager.IMPORTANCE_NONE)

    private fun updateService() {
        if (enabled && resumed && Build.VERSION.SDK_INT >= 33 &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            !prefs.getBoolean("asked", false)) {
            prefs.edit().putBoolean("asked", true).apply()
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4714)
        }
        if (!enabled || !permitted()) {
            if (running) { activity.stopService(service); running = false }
        } else if (resumed && !running) {
            ContextCompat.startForegroundService(activity, service)
            running = true
        }
    }

    fun resumed(value: Boolean) { resumed = value; updateService() }
    fun accept(intent: Intent?) {
        val uri = intent?.data ?: return
        if (intent.action != OPEN || uri.scheme != "worldlinebox" || uri.host != "chat" || uri.pathSegments.size != 2) return
        pending = mapOf("host" to uri.pathSegments[0], "room" to uri.pathSegments[1])
        intent.data = null
        channel.invokeMethod("open", null)
    }
    fun close() { enabled = false; updateService(); channel.setMethodCallHandler(null) }
}
