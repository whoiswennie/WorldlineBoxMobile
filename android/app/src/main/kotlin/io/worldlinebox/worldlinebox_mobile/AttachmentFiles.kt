package io.worldlinebox.worldlinebox_mobile

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import java.io.ByteArrayOutputStream
import java.io.File

object AttachmentFiles {
    fun pdfPage(file: File, index: Int): Map<String, Any> {
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                renderer.openPage(index).use { page ->
                    val scale = 1800.0 / maxOf(page.width, page.height)
                    val bitmap = Bitmap.createBitmap(maxOf(1, (page.width * scale).toInt()),
                        maxOf(1, (page.height * scale).toInt()), Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val output = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                        return mapOf("bytes" to output.toByteArray(), "count" to renderer.pageCount)
                    } finally { bitmap.recycle() }
                }
            }
        }
    }

    @android.annotation.TargetApi(29)
    fun saveDownload(context: Context, file: File, name: String, mime: String): String {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/WorldlineBox")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = checkNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values))
        try {
            checkNotNull(resolver.openOutputStream(uri)).use { output -> file.inputStream().use { it.copyTo(output) } }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            check(resolver.update(uri, values, null, null) == 1)
            val actual = resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) it.getString(0) else null
            } ?: name
            return "Download/WorldlineBox/$actual"
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
