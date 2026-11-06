package app.multirecorder.phone

import android.os.Build
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import kotlin.concurrent.thread

/**
 * A small HTTP server driven by the Mac app.
 *
 * GET  /info          name, model, recording state
 * GET  /time          the phone clock (elapsedRealtimeNanos), to measure the clock offset
 * POST /start         starts a clip, body {"quality": "uhd" | "fhd" | "hd"}; returns id and start time
 * POST /stop          stops the clip; returns id, size and start time once the file is complete
 * GET  /clips/<id>    the clip file (mp4)
 * GET  /preview.jpg   the latest small frame
 * GET  /camera        camera settings and what the phone supports
 * POST /camera        changes settings, body with any field of GET /camera that can be set
 * POST /focus         {"x", "y"} in 0...1 of the preview picture; an empty body goes back to auto
 */
class PhoneServer(
    private val recorder: CameraRecorder,
    private val onEvent: (String) -> Unit,
) {
    private val socket = ServerSocket(0)
    val port: Int get() = socket.localPort
    @Volatile private var running = true

    fun start() {
        thread(name = "server", isDaemon = true) {
            while (running) {
                val client = try {
                    socket.accept()
                } catch (error: SocketException) {
                    break
                }
                thread(name = "client", isDaemon = true) { handle(client) }
            }
        }
    }

    fun close() {
        running = false
        socket.close()
    }

    private fun handle(client: Socket) {
        client.use {
            try {
                client.tcpNoDelay = true
                val input = BufferedInputStream(client.getInputStream())
                val requestLine = readLine(input) ?: return
                val parts = requestLine.split(" ")
                if (parts.size < 2) return
                val method = parts[0]
                val path = parts[1].substringBefore("?")

                var contentLength = 0
                while (true) {
                    val header = readLine(input) ?: break
                    if (header.isEmpty()) break
                    val name = header.substringBefore(":").trim().lowercase()
                    if (name == "content-length") contentLength = header.substringAfter(":").trim().toIntOrNull() ?: 0
                }
                val body = if (contentLength > 0) String(readBytes(input, contentLength)) else ""
                route(method, path, body, client.getOutputStream())
            } catch (error: Exception) {
                Log.w(TAG, "Request failed", error)
            }
        }
    }

    private fun route(method: String, path: String, body: String, out: OutputStream) {
        when {
            method == "GET" && path == "/time" ->
                json(out, JSONObject().put("t", SystemClock.elapsedRealtimeNanos()))

            method == "GET" && path == "/info" ->
                json(
                    out,
                    JSONObject()
                        .put("version", 1)
                        .put("name", Build.MODEL)
                        .put("manufacturer", Build.MANUFACTURER)
                        .put("recording", recorder.isRecording)
                        .put("quality", recorder.quality)
                        .put("preview", recorder.latestJpeg.get() != null)
                )

            method == "POST" && path == "/start" -> {
                val quality = runCatching { JSONObject(body).optString("quality", "") }.getOrDefault("")
                try {
                    val clip = runBlocking { recorder.startRecording(quality.ifEmpty { null }) }
                    onEvent("Recording")
                    json(out, clipJson(clip))
                } catch (error: Exception) {
                    json(out, JSONObject().put("error", error.message ?: "Cannot start."), 409)
                }
            }

            method == "POST" && path == "/stop" -> {
                try {
                    val clip = runBlocking { recorder.stopRecording() }
                    onEvent("Stopped, ${clip.file.length() / 1_000_000} MB")
                    json(out, clipJson(clip))
                } catch (error: Exception) {
                    json(out, JSONObject().put("error", error.message ?: "Cannot stop."), 409)
                }
            }

            method == "GET" && path == "/camera" ->
                json(out, runBlocking { withContext(Dispatchers.Main) { recorder.state() } })

            method == "POST" && path == "/camera" -> {
                try {
                    val changes = if (body.isBlank()) JSONObject() else JSONObject(body)
                    json(out, runBlocking { recorder.apply(changes) })
                } catch (error: Exception) {
                    json(out, JSONObject().put("error", error.message ?: "Cannot change the camera."), 409)
                }
            }

            method == "POST" && path == "/focus" -> {
                try {
                    val point = if (body.isBlank()) JSONObject() else JSONObject(body)
                    runBlocking {
                        if (point.has("x") && point.has("y")) {
                            recorder.focus(point.getDouble("x").toFloat(), point.getDouble("y").toFloat())
                        } else {
                            recorder.resetFocus()
                        }
                    }
                    json(out, runBlocking { withContext(Dispatchers.Main) { recorder.state() } })
                } catch (error: Exception) {
                    json(out, JSONObject().put("error", error.message ?: "Cannot focus."), 409)
                }
            }

            method == "GET" && path == "/clips" -> {
                val list = JSONArray()
                recorder.clipsDir.listFiles()?.sortedBy { it.name }?.forEach {
                    list.put(JSONObject().put("id", it.nameWithoutExtension).put("size", it.length()))
                }
                json(out, JSONObject().put("clips", list))
            }

            method == "GET" && path.startsWith("/clips/") -> {
                val file = recorder.clipFile(path.removePrefix("/clips/").removeSuffix(".mp4"))
                if (file == null) {
                    json(out, JSONObject().put("error", "No such clip."), 404)
                } else {
                    onEvent("Sending ${file.name}")
                    header(out, 200, "video/mp4", file.length())
                    file.inputStream().use { it.copyTo(out, 1 shl 16) }
                    out.flush()
                    onEvent("Sent ${file.name}")
                }
            }

            method == "GET" && path == "/preview.jpg" -> {
                val jpeg = recorder.latestJpeg.get()
                if (jpeg == null) {
                    json(out, JSONObject().put("error", "No preview."), 404)
                } else {
                    header(out, 200, "image/jpeg", jpeg.size.toLong())
                    out.write(jpeg)
                    out.flush()
                }
            }

            else -> json(out, JSONObject().put("error", "Not found."), 404)
        }
    }

    private fun clipJson(clip: Clip) = JSONObject()
        .put("id", clip.id)
        .put("startNanos", clip.startNanos)
        .put("size", clip.file.length())

    private fun json(out: OutputStream, value: JSONObject, status: Int = 200) {
        val bytes = value.toString().toByteArray()
        header(out, status, "application/json", bytes.size.toLong())
        out.write(bytes)
        out.flush()
    }

    private fun header(out: OutputStream, status: Int, type: String, length: Long) {
        val reason = when (status) {
            200 -> "OK"
            404 -> "Not Found"
            409 -> "Conflict"
            else -> "Error"
        }
        out.write(
            ("HTTP/1.1 $status $reason\r\nContent-Type: $type\r\nContent-Length: $length\r\n" +
                "Connection: close\r\n\r\n").toByteArray()
        )
    }

    private fun readLine(input: InputStream): String? {
        val line = StringBuilder()
        while (true) {
            val byte = input.read()
            if (byte < 0) return if (line.isEmpty()) null else line.toString()
            if (byte == '\n'.code) return line.toString().trimEnd('\r')
            line.append(byte.toChar())
            if (line.length > 8192) return null
        }
    }

    private fun readBytes(input: InputStream, count: Int): ByteArray {
        val bytes = ByteArray(minOf(count, 1 shl 20))
        var read = 0
        while (read < bytes.size) {
            val n = input.read(bytes, read, bytes.size - read)
            if (n < 0) break
            read += n
        }
        return bytes.copyOf(read)
    }

    companion object {
        private const val TAG = "PhoneServer"
    }
}
