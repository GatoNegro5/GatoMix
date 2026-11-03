package com.gatonegro5.gatomix

import android.content.Context
import android.os.Build
import android.os.PowerManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.stream.AudioStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit

private const val UA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"

private val http: OkHttpClient = OkHttpClient.Builder()
    .readTimeout(30, TimeUnit.SECONDS)
    .connectTimeout(20, TimeUnit.SECONDS)
    .build()

private val npLock = Any()

@Volatile
private var newPipeReady = false

private class DL : Downloader() {
    override fun execute(request: Request): Response {
        val b = okhttp3.Request.Builder().url(request.url())
            .method(request.httpMethod(), request.dataToSend()?.toRequestBody())
            .header("User-Agent", UA)
        for ((k, vs) in request.headers()) {
            b.removeHeader(k)
            vs.forEach { b.addHeader(k, it) }
        }
        http.newCall(b.build()).execute().use { r ->
            return Response(
                r.code,
                r.message,
                r.headers.toMultimap(),
                r.body?.string(),
                r.request.url.toString(),
            )
        }
    }
}

private fun ensureNewPipe() {
    if (newPipeReady) return
    synchronized(npLock) {
        if (newPipeReady) return
        try {
            NewPipe.init(DL())
        } catch (_: IllegalStateException) {
            // El proceso ya tenía el extractor (recreación de la Activity).
        }
        newPipeReady = true
    }
}

private fun bestAudio(videoId: String): AudioStream {
    ensureNewPipe()
    val ex = ServiceList.YouTube.getStreamExtractor(
        "https://www.youtube.com/watch?v=$videoId",
    )
    ex.fetchPage()
    return ex.audioStreams.filter { it.isUrl }.maxByOrNull { it.averageBitrate }
        ?: throw IllegalStateException("Sin stream de audio con URL")
}

private fun audioMap(a: AudioStream): Map<String, Any> {
    val len = a.itagItem?.contentLength ?: -1L
    return mapOf(
        "url" to a.content,
        "itag" to a.itag,
        "mime" to (a.format?.mimeType ?: ""),
        "contentLength" to len,
    )
}

class MainActivity : AudioServiceActivity() {
    private var progressSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gatomix/thermal")
            .setMethodCallHandler { call, result ->
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                when (call.method) {
                    "status" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            result.success(null)
                        } else {
                            result.success(pm.currentThermalStatus)
                        }
                    }
                    "headroom" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val h = pm.getThermalHeadroom(10)
                        if (h.isNaN()) result.success(null) else result.success(h.toDouble())
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "gatomix/newpipe/progress",
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gatomix/newpipe")
            .setMethodCallHandler { call, result ->
                val videoId = call.argument<String>("videoId")
                if (videoId.isNullOrBlank()) {
                    result.error("NP", "Falta videoId", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "getAudioUrl" -> Thread {
                        try {
                            val payload = audioMap(bestAudio(videoId))
                            runOnUiThread { result.success(payload) }
                        } catch (e: Throwable) {
                            val msg = e.message ?: e.javaClass.simpleName
                            runOnUiThread { result.error("NP", msg, null) }
                        }
                    }.start()
                    "download" -> {
                        val destPath = call.argument<String>("destPath")
                        if (destPath.isNullOrBlank()) {
                            result.error("NP", "Falta destPath", null)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                downloadAudio(videoId, destPath)
                                runOnUiThread { result.success(null) }
                            } catch (e: Throwable) {
                                val msg = e.message ?: e.javaClass.simpleName
                                runOnUiThread { result.error("NP", msg, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun emitProgress(done: Long, total: Long) {
        val sink = progressSink ?: return
        val payload = mapOf("done" to done, "total" to total)
        runOnUiThread { sink.success(payload) }
    }

    private fun downloadAudio(videoId: String, destPath: String) {
        val a = bestAudio(videoId)
        val url = a.content
        val outFile = File(destPath)
        outFile.parentFile?.mkdirs()
        var pos = 0L
        var total = -1L
        val chunk = 1L shl 20
        FileOutputStream(outFile).use { out ->
            while (total < 0 || pos < total) {
                val req = okhttp3.Request.Builder().url(url).header("User-Agent", UA)
                    .header("Range", "bytes=$pos-${pos + chunk - 1}").build()
                http.newCall(req).execute().use { r ->
                    if (r.code != 206 && r.code != 200) {
                        throw IllegalStateException(
                            "HTTP ${r.code} en $pos/$total",
                        )
                    }
                    val cr = r.header("Content-Range")
                    if (cr != null) {
                        total = cr.substringAfter('/').toLongOrNull() ?: total
                    }
                    val bytes = r.body?.bytes()
                        ?: throw IllegalStateException("Cuerpo vacío en $pos/$total")
                    if (bytes.isEmpty()) {
                        throw IllegalStateException("EMPTY en $pos/$total")
                    }
                    out.write(bytes)
                    pos += bytes.size
                    if (r.code == 200) total = pos
                    emitProgress(pos, total)
                }
            }
        }
        if (total > 0 && pos != total) {
            throw IllegalStateException("Descarga incompleta $pos/$total")
        }
    }
}
