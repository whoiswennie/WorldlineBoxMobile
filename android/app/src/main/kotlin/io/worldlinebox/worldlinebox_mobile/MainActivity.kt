package io.worldlinebox.worldlinebox_mobile

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.content.Context
import android.graphics.Color
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

class MainActivity : FlutterActivity() {
    private data class SaveRequest(val source: File, val result: MethodChannel.Result)
    private var pending: SaveRequest? = null
    private val saveDocument = 4712
    private val stages = mutableMapOf<Int, WebView>()
    private var recordPermission: MethodChannel.Result? = null
    private var speech: MobileSpeech? = null
    private var ringtone: MediaPlayer? = null

    private fun stopRingtone() {
        ringtone?.release()
        ringtone = null
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "worldlinebox/pet-ringtone").setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    stopRingtone()
                    val track = call.arguments
                    val fallback = if (track == "dafeiyu") "dafeiyu.ogg" else "common.wav"
                    try {
                        val player = MediaPlayer()
                        ringtone = player
                        val original = when (track) {
                            "dafeiyu" -> "pet-private-ringtones/dafeiyu.wav"
                            "phoebe" -> "pet-private-ringtones/phoebe.wav"
                            else -> null
                        }
                        val source = original?.let { file ->
                            try { assets.openFd(file) } catch (_: java.io.FileNotFoundException) { null }
                        } ?: assets.openFd("pet-ringtones/$fallback")
                        source.use { descriptor ->
                            player.setDataSource(descriptor.fileDescriptor, descriptor.startOffset, descriptor.length)
                        }
                        player.setAudioAttributes(AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                        player.isLooping = true
                        player.setVolume(0.55f, 0.55f)
                        player.setOnPreparedListener { if (ringtone === it) it.start() }
                        player.setOnErrorListener { failed, _, _ ->
                            if (ringtone === failed) stopRingtone()
                            true
                        }
                        player.prepareAsync()
                        result.success(null)
                    } catch (error: Exception) {
                        stopRingtone()
                        result.error("ringtone_unavailable", error.message, null)
                    }
                }
                "stop" -> { stopRingtone(); result.success(null) }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "worldlinebox/pet-textures").setMethodCallHandler { call, result ->
            if (call.method == "catalog") {
                val catalog = try {
                    assets.open("pet-models/models.json").bufferedReader().use { it.readText() }
                } catch (_: java.io.FileNotFoundException) { null }
                result.success(catalog)
                return@setMethodCallHandler
            }
            if (call.method == "copyBundled") {
                val path = call.argument<String>("asset")
                val target = call.argument<String>("path")?.let { File(it).canonicalFile }
                val cache = File(filesDir, "pet-model-files").canonicalFile
                if (path == null || !Regex("^(?:live2dcubismcore\\.min\\.js|model/[0-9]+(?:\\.[a-zA-Z0-9]+)+)$").matches(path) ||
                    target == null || target.parentFile != cache) {
                    result.error("invalid_asset", "Invalid local model asset.", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        assets.open("pet-models/$path").use { source ->
                            target.outputStream().use { source.copyTo(it) }
                        }
                        runOnUiThread { result.success(null) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("bundled_asset", error.message, null) }
                    }
                }.start()
                return@setMethodCallHandler
            }
            if (call.method == "memoryLimit") {
                val manager = getSystemService(ActivityManager::class.java)
                val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
                result.success(if (manager.isLowRamDevice || memory.totalMem < 5L * 1024 * 1024 * 1024) 4096 else 16384)
                return@setMethodCallHandler
            }
            if (call.method != "prepare") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val source = call.argument<String>("path")?.let { File(it).canonicalFile }
            val target = call.argument<String>("output")?.let { File(it).canonicalFile }
            val limit = call.argument<Int>("limit")
            val cache = File(filesDir, "pet-model-files").canonicalFile
            if (source == null || source.parentFile != cache || !source.isFile ||
                target == null || target.parentFile != cache || target == source ||
                limit == null || limit !in 1024..16384
            ) {
                result.error("invalid_texture", "Invalid model texture.", null)
                return@setMethodCallHandler
            }
            Thread {
                try {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(source.path, bounds)
                    check(bounds.outWidth > 0 && bounds.outHeight > 0) { "Could not read the texture dimensions." }
                    val longest = maxOf(bounds.outWidth, bounds.outHeight)
                    if (longest <= limit) {
                        runOnUiThread { result.success(false) }
                        return@Thread
                    }
                    val width = maxOf(1, (bounds.outWidth.toLong() * limit / longest).toInt())
                    val height = maxOf(1, (bounds.outHeight.toLong() * limit / longest).toInt())
                    val sample = Integer.highestOneBit(longest / limit)
                    val bitmap = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply {
                        inSampleSize = sample
                        inPreferredConfig = Bitmap.Config.ARGB_8888
                    }) ?: error("Could not decode the texture.")
                    val scaled = Bitmap.createScaledBitmap(bitmap, width, height, true)
                    try {
                        target.outputStream().use {
                            check(scaled.compress(Bitmap.CompressFormat.PNG, 100, it)) { "Texture encode failed." }
                        }
                    } finally {
                        if (scaled !== bitmap) scaled.recycle()
                        bitmap.recycle()
                    }
                    runOnUiThread { result.success(true) }
                } catch (error: OutOfMemoryError) {
                    runOnUiThread { result.error("texture_memory", "Insufficient memory to prepare the texture.", null) }
                } catch (error: Exception) {
                    runOnUiThread { result.error("texture_failed", error.message, null) }
                }
            }.start()
        }
        engine.platformViewsController.registry.registerViewFactory(
            "worldlinebox/pet-stage",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, id: Int, args: Any?): PlatformView {
                    val url = (args as? Map<*, *>)?.get("url") as? String ?: error("Missing stage address")
                    require(Regex("^http://127\\.0\\.0\\.1:[0-9]{1,5}/[0-9a-f-]{36}/$").matches(url))
                    val channel = MethodChannel(messenger, "worldlinebox/pet-stage/$id")
                    val web = WebView(context).apply {
                        setBackgroundColor(Color.TRANSPARENT)
                        settings.javaScriptEnabled = true
                        settings.allowFileAccess = false
                        settings.allowContentAccess = false
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                                !request.url.toString().startsWith(url)
                        }
                        addJavascriptInterface(object {
                            @JavascriptInterface fun postMessage(status: String) {
                                runOnUiThread { channel.invokeMethod("status", status) }
                            }
                            @JavascriptInterface fun reportFigure(x: Double, y: Double, width: Double, height: Double) {
                                val bounds = listOf(x, y, width, height)
                                if (bounds.all { it.isFinite() } && width > 0 && height > 0) {
                                    runOnUiThread { channel.invokeMethod("figure", bounds) }
                                }
                            }
                        }, "PetStatus")
                    }
                    stages[id] = web
                    channel.setMethodCallHandler { call, result ->
                        if (call.method == "cue" && call.arguments is String) {
                            val json = org.json.JSONObject.quote(call.arguments as String)
                            web.evaluateJavascript("window.petCue?.(JSON.parse($json));", null)
                            result.success(null)
                        } else if (call.method == "presence" && call.arguments in listOf("idle", "waiting", "speaking")) {
                            val value = org.json.JSONObject.quote(call.arguments as String)
                            web.evaluateJavascript("window.petPresence?.($value);", null)
                            result.success(null)
                        } else if (call.method == "fullBody" && call.arguments is Boolean) {
                            web.evaluateJavascript("window.petFullBody?.(${call.arguments});", null)
                            result.success(null)
                        } else if (call.method == "bodyShape" && call.arguments is Number) {
                            val value = (call.arguments as Number).toDouble()
                            if (value.isFinite()) web.evaluateJavascript("window.petBodyShape?.($value);", null)
                            result.success(null)
                        } else result.notImplemented()
                    }
                    web.loadUrl(url)
                    return object : PlatformView {
                        override fun getView(): View = web
                        override fun dispose() {
                            stages.remove(id)
                            channel.setMethodCallHandler(null)
                            web.removeJavascriptInterface("PetStatus")
                            web.destroy()
                        }
                    }
                }
            }
        )
        val audio = MobileSpeech(this) { id, level -> stages[id]?.evaluateJavascript("window.petAudio?.($level);", null) }
        speech = audio
        MethodChannel(engine.dartExecutor.binaryMessenger, "worldlinebox/pet-voice").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> { audio.start(call.argument<Int>("id")!!, call.argument<Int>("stage")); result.success(null) }
                    "pcm" -> audio.write(call.argument<Int>("id")!!, call.argument<ByteArray>("bytes")!!, result)
                    "drain" -> audio.drain(call.arguments as Int, result)
                    "stop" -> { audio.stop(call.arguments as? Int); result.success(null) }
                    "record" -> {
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) { audio.record(); result.success(null) }
                        else if (recordPermission != null) result.error("microphone", "正在等待麦克风权限。", null)
                        else { recordPermission = result; requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 4713) }
                    }
                    "record.stop" -> audio.stopRecording(result)
                    "record.cancel" -> { recordPermission?.error("cancelled", "录音已取消。", null); recordPermission = null; audio.stopRecording(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) { result.error("audio", error.message, null) }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "worldlinebox/mobile-files").setMethodCallHandler { call, result ->
            if (call.method != "save") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name")
            val source = call.argument<String>("path")?.let { File(it).canonicalFile }
            if (name.isNullOrBlank() || source == null || !source.isFile ||
                !source.path.startsWith(cacheDir.canonicalPath + File.separator)) {
                result.error("invalid_file", "Invalid local attachment.", null)
                return@setMethodCallHandler
            }
            if (pending != null) {
                result.error("busy", "Another save is in progress.", null)
                return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = call.argument<String>("mimeType") ?: "application/octet-stream"
                putExtra(Intent.EXTRA_TITLE, name)
            }
            pending = SaveRequest(source, result)
            try {
                startActivityForResult(intent, saveDocument)
            } catch (error: Exception) {
                pending = null
                result.error("save_unavailable", "No document provider is available.", null)
            }
        }
    }

    @Deprecated("Android activity results are delivered by FlutterActivity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveDocument) return
        val request = pending ?: return
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null) {
            pending = null
            request.result.success(false)
            return
        }
        Thread {
            try {
                val output = contentResolver.openOutputStream(destination, "w") ?: error("Missing document output")
                output.use { sink -> request.source.inputStream().use { input -> input.copyTo(sink) } }
                runOnUiThread {
                    pending = null
                    request.result.success(true)
                }
            } catch (error: Exception) {
                runOnUiThread {
                    pending = null
                    request.result.error("save_failed", "Unable to save the document.", null)
                }
            }
        }.start()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 4713) return
        val pending = recordPermission ?: return
        recordPermission = null
        if (grantResults.firstOrNull() != PackageManager.PERMISSION_GRANTED) { pending.error("microphone", "未授权麦克风。", null); return }
        try { speech?.record(); pending.success(null) }
        catch (error: Exception) { pending.error("microphone", error.message, null) }
    }

    override fun onDestroy() {
        stopRingtone()
        speech?.close()
        speech = null
        super.onDestroy()
    }
}
