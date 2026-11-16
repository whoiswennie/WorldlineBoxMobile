package io.worldlinebox.worldlinebox_mobile

import android.app.Activity
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors

internal class MobileSpeech(private val activity: Activity, private val mouth: (Int, Double) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val playbackWorker = Executors.newSingleThreadExecutor()
    private val recorderWorker = Executors.newSingleThreadExecutor()
    @Volatile private var playing: Playback? = null
    @Volatile private var recorder: Recording? = null
    private class Playback(val id: Int, val stage: Int?, val track: AudioTrack) {
        @Volatile var written = 0L
        val levels = java.util.concurrent.ConcurrentLinkedQueue<Pair<Long, Double>>()
    }
    private class Recording(val input: AudioRecord) {
        @Volatile var running = true
        val bytes = ByteArrayOutputStream()
    }

    fun start(id: Int, stage: Int?) {
        stop()
        val sampleRate = 24000
        val buffer = AudioTrack.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(buffer > 0)
        val streamingBuffer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) sampleRate * 2 else 5760
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(sampleRate).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(buffer, streamingBuffer)).setTransferMode(AudioTrack.MODE_STREAM).build()
        // Dart has already buffered startup audio. Short replies can use a fraction of the track buffer.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) track.setStartThresholdInFrames(1)
        val session = Playback(id, stage, track)
        playing = session
        track.play()
        if (stage != null) meter(session)
    }

    private fun meter(session: Playback) {
        if (playing !== session) return
        val frame = session.track.playbackHeadPosition.toLong() and 0xffffffffL
        while (session.levels.peek()?.let { it.first + 480 <= frame } == true) session.levels.poll()
        val level = session.levels.peek()?.takeIf { frame >= it.first && frame < session.written }?.second ?: 0.0
        session.stage?.let { mouth(it, level) }
        main.postDelayed({ meter(session) }, 16)
    }

    fun write(id: Int, bytes: ByteArray, result: MethodChannel.Result) = background(result) {
        val session = playing?.takeIf { it.id == id } ?: return@background
        var offset = 0
        while (offset < bytes.size && playing === session) {
            val size = minOf(960, bytes.size - offset)
            var sum = 0.0
            for (index in offset until offset + size step 2) {
                val sample = ((bytes[index].toInt() and 255) or (bytes[index + 1].toInt() shl 8)) / 32768.0
                sum += sample * sample
            }
            if (session.stage != null) session.levels.add(session.written to ((kotlin.math.sqrt(sum / (size / 2)) - 0.012) * 4.8).coerceIn(0.0, 1.0))
            val written = session.track.write(bytes, offset, size, AudioTrack.WRITE_BLOCKING)
            if (playing !== session) return@background
            check(written > 0) { "AudioTrack write failed" }
            session.written += written / 2
            offset += written
        }
    }

    fun drain(id: Int, result: MethodChannel.Result) {
        fun checkPlayback() {
            val session = playing?.takeIf { it.id == id }
            if (session == null || (session.track.playbackHeadPosition.toLong() and 0xffffffffL) >= session.written) result.success(null)
            else main.postDelayed({ checkPlayback() }, 20)
        }
        checkPlayback()
    }

    fun stop(id: Int? = null) {
        val session = playing ?: return
        if (id != null && session.id != id) return
        playing = null
        session.stage?.let { mouth(it, 0.0) }
        runCatching { session.track.pause(); session.track.flush() }
        playbackWorker.execute { session.track.release() }
    }

    @Suppress("MissingPermission")
    fun record() {
        check(recorder == null)
        val min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(min > 0)
        val input = AudioRecord(MediaRecorder.AudioSource.MIC, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, 4096))
        try { input.startRecording() } catch (error: Exception) { input.release(); throw error }
        val recording = Recording(input)
        recorder = recording
        recorderWorker.execute {
            val buffer = ByteArray(4096)
            while (recording.running && recording.bytes.size() < 16000 * 2 * 119) {
                val remaining = 16000 * 2 * 119 - recording.bytes.size()
                val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                if (count <= 0) break
                recording.bytes.write(buffer, 0, count)
            }
            runCatching { input.stop() }
            input.release()
        }
    }

    fun stopRecording(result: MethodChannel.Result? = null) {
        val recording = recorder
        if (recording == null) { result?.success(null); return }
        recorder = null
        recording.running = false
        if (result == null) return
        recorderWorker.execute {
            val bytes = recording.bytes.toByteArray()
            val wav = ByteBuffer.allocate(44 + bytes.size).order(ByteOrder.LITTLE_ENDIAN)
            wav.put("RIFF".toByteArray()).putInt(36 + bytes.size).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16)
                .put("data".toByteArray()).putInt(bytes.size).put(bytes)
            activity.runOnUiThread { result.success(wav.array()) }
        }
    }

    private fun background(result: MethodChannel.Result, work: () -> Unit) {
        playbackWorker.execute {
            try { work(); activity.runOnUiThread { result.success(null) } }
            catch (error: Exception) { activity.runOnUiThread { result.error("audio", error.message, null) } }
        }
    }

    fun close() { stop(); stopRecording(); playbackWorker.shutdown(); recorderWorker.shutdown() }
}
