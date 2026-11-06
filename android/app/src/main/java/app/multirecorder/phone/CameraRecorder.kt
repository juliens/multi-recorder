package app.multirecorder.phone

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CaptureRequest
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/** A finished or running clip. Times use SystemClock.elapsedRealtimeNanos. */
data class Clip(val id: String, val file: File, val startNanos: Long)

/** Settings that need the camera to be bound again. They cannot change while recording. */
data class BindSettings(
    val front: Boolean = false,
    /** Surface.ROTATION_*: 90 is landscape for a phone. */
    val rotation: Int = Surface.ROTATION_90,
    val fps: Int = 30,
    val stabilization: Boolean = false,
    val quality: String = "fhd",
)

/** Settings applied to the running camera. They can change while recording. */
data class LiveSettings(
    val zoom: Float = 1f,
    val exposure: Int = 0,
    val whiteBalance: String = "auto",
    val exposureLock: Boolean = false,
    val whiteBalanceLock: Boolean = false,
    val torch: Boolean = false,
)

/**
 * Camera preview, video recording with audio, a small JPEG of the latest frame, and the
 * camera controls used by the Mac. Every method that touches CameraX runs on the main thread.
 */
class CameraRecorder(
    private val context: Context,
    private val owner: LifecycleOwner,
    private val previewView: PreviewView,
) {
    val clipsDir: File = File(context.getExternalFilesDir(null) ?: context.filesDir, "clips").apply { mkdirs() }

    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var recording: Recording? = null
    private var finalized: CompletableDeferred<Unit>? = null
    private var current: Clip? = null

    var bindSettings = BindSettings()
        private set
    var liveSettings = LiveSettings()
        private set

    val quality: String get() = bindSettings.quality
    val isRecording: Boolean get() = recording != null

    /** Latest preview frame as JPEG, for the Mac. */
    val latestJpeg = AtomicReference<ByteArray?>(null)
    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private var lastJpegTime = 0L

    /** Called on the main thread after any setting changed. */
    var onChange: (() -> Unit)? = null

    suspend fun start() = withContext(Dispatchers.Main) {
        provider = ProcessCameraProvider.getInstance(context).await()
        bind()
    }

    suspend fun switchCamera() = updateBind(bindSettings.copy(front = !bindSettings.front))

    // MARK: Binding

    private fun bind() {
        val provider = provider ?: return
        val settings = bindSettings
        val selector = if (settings.front && provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)) {
            CameraSelector.DEFAULT_FRONT_CAMERA
        } else {
            CameraSelector.DEFAULT_BACK_CAMERA
        }

        val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
        val recorder = Recorder.Builder()
            .setQualitySelector(
                QualitySelector.from(qualityOf(settings.quality), FallbackStrategy.lowerQualityOrHigherThan(Quality.SD))
            )
            .build()
        val captureBuilder = VideoCapture.Builder(recorder)
            .setTargetRotation(settings.rotation)
            .setVideoStabilizationEnabled(settings.stabilization)
        if (settings.fps != 30) {
            captureBuilder.setTargetFrameRate(Range(settings.fps, settings.fps))
        }
        val capture = captureBuilder.build()
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(Size(640, 360), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)
                    )
                    .build()
            )
            .setTargetRotation(settings.rotation)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .build()
        analysis.setAnalyzer(analysisExecutor) { image ->
            val now = SystemClock.elapsedRealtime()
            if (now - lastJpegTime >= 120) {
                lastJpegTime = now
                latestJpeg.set(toJpeg(image.toBitmap(), image.imageInfo.rotationDegrees))
            }
            image.close()
        }

        provider.unbindAll()
        camera = try {
            provider.bindToLifecycle(owner, selector, *listOf<UseCase>(preview, capture, analysis).toTypedArray())
        } catch (error: Exception) {
            // Some phones cannot run three use cases together: drop the small preview for the Mac then.
            Log.w(TAG, "Binding with analysis failed, trying without", error)
            provider.unbindAll()
            latestJpeg.set(null)
            provider.bindToLifecycle(owner, selector, preview, capture)
        }
        meteringFactory = SurfaceOrientedMeteringPointFactory(1f, 1f, analysis)
        videoCapture = capture
        applyLive(liveSettings)
    }

    /** Applies settings that need a new binding. Refused while recording. */
    suspend fun updateBind(settings: BindSettings) = withContext(Dispatchers.Main) {
        if (settings == bindSettings) return@withContext
        check(!isRecording) { "Stop the recording to change the camera, orientation, frame rate or stabilization." }
        val previous = bindSettings
        bindSettings = settings
        try {
            bind()
        } catch (error: Exception) {
            Log.w(TAG, "Binding failed, going back", error)
            bindSettings = previous
            bind()
            throw IllegalStateException("The phone does not support this setting.")
        }
        onChange?.invoke()
    }

    // MARK: Live settings

    suspend fun updateLive(settings: LiveSettings) = withContext(Dispatchers.Main) {
        applyLive(settings)
        onChange?.invoke()
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun applyLive(requested: LiveSettings) {
        val camera = camera ?: return
        val info = camera.cameraInfo
        val control = camera.cameraControl

        val zoomState = info.zoomState.value
        val zoom = if (zoomState != null) requested.zoom.coerceIn(zoomState.minZoomRatio, zoomState.maxZoomRatio) else 1f
        control.setZoomRatio(zoom)

        val exposureState = info.exposureState
        var exposure = 0
        if (exposureState.isExposureCompensationSupported) {
            val range = exposureState.exposureCompensationRange
            exposure = requested.exposure.coerceIn(range.lower, range.upper)
            control.setExposureCompensationIndex(exposure)
        }

        val torch = requested.torch && info.hasFlashUnit()
        control.enableTorch(torch)

        Camera2CameraControl.from(control).captureRequestOptions = CaptureRequestOptions.Builder()
            .setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, whiteBalanceMode(requested.whiteBalance))
            .setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, requested.exposureLock)
            .setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, requested.whiteBalanceLock)
            .build()

        liveSettings = requested.copy(zoom = zoom, exposure = exposure, torch = torch)
    }

    // MARK: Focus

    private var meteringFactory: SurfaceOrientedMeteringPointFactory? = null
    var focusPoint: Pair<Float, Float>? = null
        private set

    /**
     * Focuses and meters on a point of the preview JPEG (0...1, origin at the top left).
     * The point stays until `resetFocus`.
     */
    suspend fun focus(x: Float, y: Float) = withContext(Dispatchers.Main) {
        val camera = camera ?: error("The camera is not ready.")
        val factory = meteringFactory ?: error("The camera is not ready.")
        // The JPEG is rotated by the analysis rotation: go back to buffer coordinates.
        val degrees = rotationDegrees()
        val (u, v) = when (degrees) {
            90 -> y to 1 - x
            180 -> 1 - x to 1 - y
            270 -> 1 - y to x
            else -> x to y
        }
        val point = factory.createPoint(u.coerceIn(0f, 1f), v.coerceIn(0f, 1f))
        val action = FocusMeteringAction.Builder(
            point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE or FocusMeteringAction.FLAG_AWB
        ).disableAutoCancel().build()
        camera.cameraControl.startFocusAndMetering(action)
        focusPoint = x to y
        onChange?.invoke()
    }

    suspend fun resetFocus() = withContext(Dispatchers.Main) {
        camera?.cameraControl?.cancelFocusAndMetering()
        focusPoint = null
        onChange?.invoke()
    }

    /** Rotation applied to the analysis frames, which the JPEG undoes. */
    @Volatile private var lastRotationDegrees = 0
    private fun rotationDegrees() = lastRotationDegrees

    // MARK: State

    fun state(): JSONObject {
        val camera = camera
        val info = camera?.cameraInfo
        val zoom = info?.zoomState?.value
        val exposure = info?.exposureState
        val frameRates = JSONArray()
        val rates = info?.supportedFrameRateRanges?.filter { it.lower == it.upper }?.map { it.upper }?.toSortedSet()
        (rates?.takeIf { it.isNotEmpty() } ?: sortedSetOf(30)).forEach { frameRates.put(it) }
        val stabilizationSupported = info?.let {
            runCatching { Recorder.getVideoCapabilities(it).isStabilizationSupported }.getOrDefault(false)
        } ?: false

        return JSONObject()
            .put("front", bindSettings.front)
            .put("hasFront", provider?.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA) ?: false)
            .put("orientation", orientationName(bindSettings.rotation))
            .put("fps", bindSettings.fps)
            .put("frameRates", frameRates)
            .put("stabilization", bindSettings.stabilization)
            .put("hasStabilization", stabilizationSupported)
            .put("quality", bindSettings.quality)
            .put("zoom", liveSettings.zoom.toDouble())
            .put("minZoom", (zoom?.minZoomRatio ?: 1f).toDouble())
            .put("maxZoom", (zoom?.maxZoomRatio ?: 1f).toDouble())
            .put("exposure", liveSettings.exposure)
            .put("minExposure", if (exposure?.isExposureCompensationSupported == true) exposure.exposureCompensationRange.lower else 0)
            .put("maxExposure", if (exposure?.isExposureCompensationSupported == true) exposure.exposureCompensationRange.upper else 0)
            .put("exposureStep", exposure?.exposureCompensationStep?.toFloat()?.toDouble() ?: 0.0)
            .put("whiteBalance", liveSettings.whiteBalance)
            .put("exposureLock", liveSettings.exposureLock)
            .put("whiteBalanceLock", liveSettings.whiteBalanceLock)
            .put("torch", liveSettings.torch)
            .put("hasTorch", info?.hasFlashUnit() ?: false)
            .put("focusSet", focusPoint != null)
            .put("recording", isRecording)
    }

    /** Applies the fields present in `changes`. Returns the new state. */
    suspend fun apply(changes: JSONObject): JSONObject {
        var bind = bindSettings
        if (changes.has("front")) bind = bind.copy(front = changes.getBoolean("front"))
        if (changes.has("orientation")) bind = bind.copy(rotation = rotationOf(changes.getString("orientation")))
        if (changes.has("fps")) bind = bind.copy(fps = changes.getInt("fps"))
        if (changes.has("stabilization")) bind = bind.copy(stabilization = changes.getBoolean("stabilization"))
        if (changes.has("quality")) bind = bind.copy(quality = changes.getString("quality"))
        if (bind != bindSettings) {
            updateBind(bind)
            // A new camera starts without the focus point.
            focusPoint = null
        }

        var live = liveSettings
        if (changes.has("zoom")) live = live.copy(zoom = changes.getDouble("zoom").toFloat())
        if (changes.has("exposure")) live = live.copy(exposure = changes.getInt("exposure"))
        if (changes.has("whiteBalance")) live = live.copy(whiteBalance = changes.getString("whiteBalance"))
        if (changes.has("exposureLock")) live = live.copy(exposureLock = changes.getBoolean("exposureLock"))
        if (changes.has("whiteBalanceLock")) {
            live = live.copy(whiteBalanceLock = changes.getBoolean("whiteBalanceLock"))
        }
        if (changes.has("torch")) live = live.copy(torch = changes.getBoolean("torch"))
        if (live != liveSettings) updateLive(live)
        return withContext(Dispatchers.Main) { state() }
    }

    // MARK: Recording

    /** Starts a clip and returns once the recording really started. */
    @SuppressLint("MissingPermission")
    suspend fun startRecording(requestedQuality: String?): Clip = withContext(Dispatchers.Main) {
        check(!isRecording) { "Already recording." }
        if (requestedQuality != null && requestedQuality != bindSettings.quality) {
            bindSettings = bindSettings.copy(quality = requestedQuality)
            bind()
        }
        val capture = videoCapture ?: error("The camera is not ready.")
        val id = "clip_" + System.currentTimeMillis()
        val file = File(clipsDir, "$id.mp4")
        val started = CompletableDeferred<Long>()
        val done = CompletableDeferred<Unit>()

        recording = capture.output
            .prepareRecording(context, FileOutputOptions.Builder(file).build())
            .withAudioEnabled()
            .start(ContextCompat.getMainExecutor(context)) { event ->
                when (event) {
                    is VideoRecordEvent.Start -> started.complete(SystemClock.elapsedRealtimeNanos())
                    is VideoRecordEvent.Finalize -> {
                        if (event.hasError() && event.error != VideoRecordEvent.Finalize.ERROR_NONE) {
                            Log.w(TAG, "Recording ended with error ${event.error}", event.cause)
                        }
                        started.completeExceptionally(IllegalStateException("The recording did not start."))
                        done.complete(Unit)
                    }
                }
            }
        finalized = done
        try {
            val startNanos = withTimeout(5_000) { started.await() }
            Clip(id, file, startNanos).also { current = it; onChange?.invoke() }
        } catch (error: Exception) {
            recording?.stop()
            recording = null
            throw error
        }
    }

    /** Stops the clip and returns once the file is complete. */
    suspend fun stopRecording(): Clip = withContext(Dispatchers.Main) {
        val active = recording ?: error("Not recording.")
        val clip = current ?: error("Not recording.")
        active.stop()
        withTimeout(30_000) { finalized?.await() }
        recording = null
        finalized = null
        current = null
        onChange?.invoke()
        clip
    }

    fun clipFile(id: String): File? {
        if (!CLIP_ID.matches(id)) return null
        return File(clipsDir, "$id.mp4").takeIf { it.isFile }
    }

    fun close() {
        recording?.stop()
        analysisExecutor.shutdown()
    }

    private fun toJpeg(bitmap: Bitmap, rotation: Int): ByteArray {
        lastRotationDegrees = rotation
        val rotated = if (rotation == 0) bitmap else Bitmap.createBitmap(
            bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(rotation.toFloat()) }, true
        )
        val out = ByteArrayOutputStream()
        rotated.compress(Bitmap.CompressFormat.JPEG, 70, out)
        return out.toByteArray()
    }

    companion object {
        private const val TAG = "CameraRecorder"
        private val CLIP_ID = Regex("clip_[0-9]+")

        fun qualityOf(name: String): Quality = when (name) {
            "uhd" -> Quality.UHD
            "hd" -> Quality.HD
            else -> Quality.FHD
        }

        fun rotationOf(name: String): Int = when (name) {
            "portrait" -> Surface.ROTATION_0
            "landscapeFlipped" -> Surface.ROTATION_270
            "portraitFlipped" -> Surface.ROTATION_180
            else -> Surface.ROTATION_90
        }

        fun orientationName(rotation: Int): String = when (rotation) {
            Surface.ROTATION_0 -> "portrait"
            Surface.ROTATION_270 -> "landscapeFlipped"
            Surface.ROTATION_180 -> "portraitFlipped"
            else -> "landscape"
        }

        fun whiteBalanceMode(name: String): Int = when (name) {
            "daylight" -> CaptureRequest.CONTROL_AWB_MODE_DAYLIGHT
            "cloudy" -> CaptureRequest.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
            "shade" -> CaptureRequest.CONTROL_AWB_MODE_SHADE
            "incandescent" -> CaptureRequest.CONTROL_AWB_MODE_INCANDESCENT
            "fluorescent" -> CaptureRequest.CONTROL_AWB_MODE_FLUORESCENT
            else -> CaptureRequest.CONTROL_AWB_MODE_AUTO
        }
    }
}

/** Waits for a ListenableFuture without blocking the main thread. */
private suspend fun <T> com.google.common.util.concurrent.ListenableFuture<T>.await(): T {
    val result = CompletableDeferred<T>()
    addListener({
        try {
            result.complete(get())
        } catch (error: Exception) {
            result.completeExceptionally(error)
        }
    }, Runnable::run)
    return result.await()
}
