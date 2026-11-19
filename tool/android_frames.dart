// The Kotlin that setup writes into android/app. Kept here so the Dart and
// the native halves of frame extraction live beside each other.
//
// Why native at all: Speak records a three-second video and then reads the
// mouth out of that file, which is the same thing the collector screen
// records, so recognition sees exactly what training saw. Flutter cannot
// decode frames from an .mp4 on its own, and the ffmpeg packages that used to
// do it are retired, so the frames are pulled with Android's own
// MediaMetadataRetriever and handed back as luminance.

const String kFrameExtractorKt = r'''
package com.silentvoice.silent_voice_recorder

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Arrays

/**
 * Pulls evenly spaced frames out of a recorded video as NV21 bytes.
 *
 * Only the luminance is real; the colour half is filled with the neutral
 * value, because everything downstream - the face detector and the model -
 * works in grey. That keeps each frame to a third less data and the
 * conversion to one pass over the pixels.
 */
class FrameExtractor(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "antarvani/frames"
    }

    private var retriever: MediaMetadataRetriever? = null
    private var outWidth = 0
    private var outHeight = 0
    private var startUs = 0L
    private var stepUs = 0L
    private var frameCount = 0

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> open(call, result)
                "frame" -> frame(call, result)
                "close" -> {
                    release()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            release()
            result.error("frames", e.message, null)
        }
    }

    private fun release() {
        try {
            retriever?.release()
        } catch (e: Throwable) {
            // Nothing useful to do; the next open() makes a new one.
        }
        retriever = null
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        release()
        val path = call.argument<String>("path")
        val count = call.argument<Int>("count") ?: 48
        val stepMs = call.argument<Int>("stepMs") ?: 62
        val startMs = call.argument<Int>("startMs") ?: 0
        val maxWidth = call.argument<Int>("maxWidth") ?: 480
        if (path == null) {
            result.error("frames", "no path", null)
            return
        }

        val r = MediaMetadataRetriever()
        r.setDataSource(path)
        val srcW = r.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val srcH = r.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rotation = r.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        val durationMs = r.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        if (srcW <= 0 || srcH <= 0) {
            r.release()
            result.error("frames", "could not read the video size", null)
            return
        }

        // The retriever reports the size before rotation; a portrait video
        // comes back from getFrameAtTime already turned upright.
        val upright = rotation == 90 || rotation == 270
        val w = if (upright) srcH else srcW
        val h = if (upright) srcW else srcH

        val scale = if (w > maxWidth) maxWidth.toDouble() / w else 1.0
        outWidth = Math.max(2, (w * scale).toInt() / 2 * 2)
        outHeight = Math.max(2, (h * scale).toInt() / 2 * 2)

        retriever = r
        frameCount = count
        startUs = startMs * 1000L
        stepUs = stepMs * 1000L

        val info = HashMap<String, Any>()
        info["width"] = outWidth
        info["height"] = outHeight
        info["rotation"] = rotation
        info["durationMs"] = durationMs
        info["count"] = count
        result.success(info)
    }

    private fun frame(call: MethodCall, result: MethodChannel.Result) {
        val r = retriever
        if (r == null) {
            result.error("frames", "open() was not called", null)
            return
        }
        val index = call.argument<Int>("index") ?: 0
        val at = startUs + index * stepUs
        var bmp: Bitmap? = r.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST)
        if (bmp == null) {
            // Past the end, or a frame the decoder would not give up: the
            // last readable one is better than nothing.
            bmp = r.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        }
        if (bmp == null) {
            result.error("frames", "no frame at ${at / 1000} ms", null)
            return
        }
        val scaled =
            if (bmp.width == outWidth && bmp.height == outHeight) bmp
            else Bitmap.createScaledBitmap(bmp, outWidth, outHeight, true)
        val bytes = toNv21(scaled)
        if (scaled !== bmp) scaled.recycle()
        bmp.recycle()
        result.success(bytes)
    }

    /** Luminance from ARGB, with the colour half left neutral. */
    private fun toNv21(bmp: Bitmap): ByteArray {
        val w = bmp.width
        val h = bmp.height
        val pixels = IntArray(w * h)
        bmp.getPixels(pixels, 0, w, 0, 0, w, h)
        val uvW = (w + 1) / 2
        val uvH = (h + 1) / 2
        val out = ByteArray(w * h + 2 * uvW * uvH)
        var i = 0
        val n = w * h
        while (i < n) {
            val p = pixels[i]
            val red = (p shr 16) and 0xFF
            val green = (p shr 8) and 0xFF
            val blue = p and 0xFF
            out[i] = (((77 * red + 150 * green + 29 * blue) shr 8) and 0xFF).toByte()
            i++
        }
        Arrays.fill(out, n, out.size, 128.toByte())
        return out
    }
}
''';

const String kMainActivityKt = r'''
package com.silentvoice.silent_voice_recorder

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FrameExtractor.CHANNEL
        ).setMethodCallHandler(FrameExtractor(applicationContext))
    }
}
''';
