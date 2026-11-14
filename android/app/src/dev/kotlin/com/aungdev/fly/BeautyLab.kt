package com.aungdev.fly

// Beauty Lab (9 Nov 2026, Fly Dev only) - a test of the GPUPixel beauty
// engine (github.com/pixpark/gpupixel v1.3.1, Apache-2.0, AAR in
// android/app/libs/gpupixel-release.aar, dev flavor only) on Ko's phone,
// to compare with TikTok before building it into the Record camera.
//
// Pipeline (all on one background thread):
//   Camera2 (front, YUV_420_888, <= 1280x720)
//   -> GPUPixel.YUV_420_888toRGBA -> rotateRgbaImage (upright)
//   -> FaceDetector.detect (face landmarks)
//   -> SourceRawData -> Lipstick -> Blusher -> BeautyFace -> FaceReshape
//   -> SinkRawData (RGBA) -> Bitmap -> drawn on a Flutter texture
//      (TextureRegistry SurfaceTexture) that lib/screens/beauty_lab_screen
//      .dart shows with a Texture widget (mirrored there for the selfie).
// Channel "fly/beauty_lab": start -> {textureId, width, height}, set
// (smooth / white / thin / eyes / lips / blush, 0..1), stop,
// startRecording {audio} / stopRecording -> mp4 path (BeautyRecorder.kt,
// 10 Nov 2026 - the beauty is baked into the file).

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.Surface
import com.pixpark.gpupixel.FaceDetector
import com.pixpark.gpupixel.GPUPixel
import com.pixpark.gpupixel.GPUPixelFilter
import com.pixpark.gpupixel.GPUPixelSinkRawData
import com.pixpark.gpupixel.GPUPixelSourceRawData
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.nio.ByteBuffer

object BeautyLabRegistrar {
    fun register(activity: Activity, engine: FlutterEngine) {
        val lab = BeautyLab(activity, engine.renderer)
        MethodChannel(engine.dartExecutor.binaryMessenger, "fly/beauty_lab")
            .setMethodCallHandler(lab)
    }
}

class BeautyLab(
    private val activity: Activity,
    private val textures: TextureRegistry,
) : MethodChannel.MethodCallHandler {

    private val tag = "BeautyLab"
    private val main = Handler(Looper.getMainLooper())

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var sensorOrientation = 270

    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null
    private var bitmap: Bitmap? = null
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)

    // GPUPixel objects - created and used only on the background thread.
    private var source: GPUPixelSourceRawData? = null
    private var lipstick: GPUPixelFilter? = null
    private var blusher: GPUPixelFilter? = null
    private var beauty: GPUPixelFilter? = null
    private var reshape: GPUPixelFilter? = null
    private var sink: GPUPixelSinkRawData? = null
    private var detector: FaceDetector? = null

    @Volatile private var params = mapOf(
        "smooth" to 0.0, "white" to 0.0, "thin" to 0.0,
        "eyes" to 0.0, "lips" to 0.0, "blush" to 0.0,
    )
    @Volatile private var paramsDirty = true
    @Volatile private var running = false
    @Volatile private var lastFps = 0.0
    private var frames = 0
    private var fpsStart = 0L
    private val recorder = BeautyRecorder()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result, call.argument<Boolean>("front") ?: true)
            "switchCamera" -> {
                val h = handler
                if (h == null || !running || recorder.isRecording) {
                    result.error("busy", "Cannot switch now", null)
                    return
                }
                h.post {
                    try {
                        closeCamera()
                        val size = openCamera(!isFront, h)
                        main.post {
                            result.success(mapOf("width" to size.height,
                                "height" to size.width, "front" to isFront))
                        }
                    } catch (e: Throwable) {
                        Log.e(tag, "switch", e)
                        main.post { result.error("switch_failed", e.toString(), null) }
                    }
                }
            }
            "setExposure" -> {
                exposure = (call.argument<Double>("value") ?: 0.0).coerceIn(-1.0, 1.0)
                handler?.post {
                    val b = builder
                    val sess = session
                    if (b != null && sess != null) {
                        try {
                            b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, aeIndex())
                            repeat(sess, b)
                        } catch (e: Throwable) {
                            Log.e(tag, "exposure", e)
                        }
                    }
                }
                result.success(null)
            }
            "set" -> {
                val m = HashMap(params)
                for (k in m.keys.toList()) {
                    call.argument<Double>(k)?.let { m[k] = it }
                }
                params = m
                paramsDirty = true
                result.success(null)
            }
            "fps" -> result.success(lastFps)
            // 13 Nov 2026: dev read-out for tuning low light on Ko's phone.
            "stats" -> result.success(mapOf(
                "fps" to lastFps, "iso" to lastIso, "isoMax" to isoMax,
                "expMs" to lastExpNs / 1_000_000.0, "low" to lowLight,
                "range" to ((if (lowLight) fpsLow ?: fpsRange else fpsRange)
                    ?.let { "${it.lower}-${it.upper}" } ?: "-"),
                "ranges" to fpsAll))
            "startRecording" -> {
                val h = handler
                val withAudio = call.argument<Boolean>("audio") ?: true
                if (h == null || !running) {
                    result.error("not_running", "Camera is not running", null)
                    return
                }
                h.post {
                    try {
                        val b = bitmap ?: throw IllegalStateException("No frame yet")
                        val out = File(activity.cacheDir,
                            "flycam_${System.currentTimeMillis()}.mp4")
                        recorder.start(b.width, b.height, out, withAudio)
                        main.post { result.success(null) }
                    } catch (e: Throwable) {
                        Log.e(tag, "record start", e)
                        main.post { result.error("record_failed", e.toString(), null) }
                    }
                }
            }
            "stopRecording" -> {
                val h = handler
                if (h == null) {
                    result.error("not_running", "Camera is not running", null)
                    return
                }
                h.post {
                    val f = try { recorder.stop() } catch (e: Throwable) { null }
                    main.post { result.success(f?.absolutePath) }
                }
            }
            // Ring light = TikTok's front flash: full screen brightness.
            "screenBright" -> {
                val on = call.argument<Boolean>("on") ?: false
                activity.runOnUiThread {
                    try {
                        val w = activity.window
                        val a = w.attributes
                        a.screenBrightness = if (on) 1f
                            else android.view.WindowManager.LayoutParams
                                .BRIGHTNESS_OVERRIDE_NONE
                        w.attributes = a
                    } catch (e: Throwable) {
                        Log.e(tag, "brightness", e)
                    }
                }
                result.success(null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ start
    // 11 Nov 2026: also used by the Record camera (gpu_camera_screen.dart)
    // - front / back camera ("start" {front}, "switchCamera") and brightness
    // ("setExposure" -1..1 = the camera's EV compensation range).
    @Volatile private var isFront = true
    private var builder: CaptureRequest.Builder? = null
    private var aeRange: android.util.Range<Int>? = null
    private var exposure = 0.0
    // 12 Nov 2026 (Ko: "TikTok is sharper, ours blurs when I move"):
    // a fixed 24-30 fps range (short shutter = no motion blur), the
    // camera's high-quality edge sharpening, and face-priority exposure.
    private var fpsRange: android.util.Range<Int>? = null
    private var facePriority = false
    // 13 Nov 2026 (Ko's dark-room test: grainy picture at a fixed 30 fps):
    // TikTok-style auto low light - when the camera's ISO stays high it goes
    // to 15..30 fps (longer shutter, brighter, less grain) with the best
    // noise reduction and no extra sharpening; back to 30 fps when it is
    // bright again.
    private var fpsLow: android.util.Range<Int>? = null
    private var isoMax = 0
    @Volatile private var lowLight = false
    private var darkFrames = 0
    @Volatile private var lastIso = 0
    private var fpsAll = "-"
    @Volatile private var lastExpNs = 0L
    private var brightFrames = 0

    @SuppressLint("MissingPermission")
    private fun start(result: MethodChannel.Result, front: Boolean) {
        if (running) stop()
        try {
            GPUPixel.Init(activity)
            val t = HandlerThread("BeautyLab").also { it.start() }
            thread = t
            val h = Handler(t.looper)
            handler = h
            val e = textures.createSurfaceTexture()
            entry = e
            surface = Surface(e.surfaceTexture())
            // GPUPixel chain on the camera thread.
            h.post { buildChain() }
            running = true
            exposure = 0.0
            val size = openCamera(front, h)
            e.surfaceTexture().setDefaultBufferSize(size.height, size.width)
            result.success(mapOf("textureId" to e.id(), "width" to size.height,
                "height" to size.width, "front" to isFront))
        } catch (ex: Throwable) {
            Log.e(tag, "start failed", ex)
            stop()
            result.error("start_failed", ex.toString(), null)
        }
    }

    /** Opens the front (or back) camera; returns the sensor-side size. */
    @SuppressLint("MissingPermission")
    private fun openCamera(front: Boolean, h: Handler): Size {
        val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val want = if (front) CameraCharacteristics.LENS_FACING_FRONT
                   else CameraCharacteristics.LENS_FACING_BACK
        var id: String? = null
        for (cid in manager.cameraIdList) {
            if (manager.getCameraCharacteristics(cid)
                    .get(CameraCharacteristics.LENS_FACING) == want) {
                id = cid
                break
            }
        }
        if (id == null) id = manager.cameraIdList.firstOrNull()
            ?: throw IllegalStateException("No camera")
        val chars = manager.getCameraCharacteristics(id)
        isFront = chars.get(CameraCharacteristics.LENS_FACING) ==
            CameraCharacteristics.LENS_FACING_FRONT
        sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION)
            ?: if (isFront) 270 else 90
        aeRange = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val fpsRanges = chars.get(
            CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        fpsRange = chooseFps(fpsRanges)
        // 14 Nov 2026: Ko's test - 8..30 gave 1/25 s but bad motion blur
        // (ISO still at max: the room is simply too dark). LOW now keeps the
        // shutter at most ~1/24 s (24..30 / 24..24) and relies on the noise
        // reduction + the Ring light (screen flash) for dark rooms.
        fpsLow = fpsRanges?.filter { it.upper <= 30 && it.lower == 24 }
            ?.maxByOrNull { it.upper } ?: fpsRange
        fpsAll = fpsRanges?.joinToString(" ") { "${it.lower}-${it.upper}" } ?: "-"
        isoMax = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            ?.upper ?: 0
        darkFrames = 0
        brightFrames = 0
        facePriority = chars.get(CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES)
            ?.contains(CameraCharacteristics.CONTROL_SCENE_MODE_FACE_PRIORITY) == true
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val size = chooseSize(map?.getOutputSizes(SurfaceTexture::class.java))
        val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
        reader = r
        r.setOnImageAvailableListener({ onFrame(it) }, h)
        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                camera = device
                startSession(device, r, h)
            }
            override fun onDisconnected(device: CameraDevice) {
                device.close()
                camera = null
            }
            override fun onError(device: CameraDevice, error: Int) {
                Log.e(tag, "camera error $error")
                device.close()
                camera = null
            }
        }, h)
        return size
    }

    private fun closeCamera() {
        try { session?.close() } catch (_: Throwable) {}
        session = null
        try { camera?.close() } catch (_: Throwable) {}
        camera = null
        try { reader?.close() } catch (_: Throwable) {}
        reader = null
        builder = null
    }

    private fun aeIndex(): Int {
        val r = aeRange ?: return 0
        return if (exposure >= 0) (exposure * r.upper).toInt()
               else (-exposure * r.lower).toInt()
    }

    private fun chooseSize(choices: Array<Size>?): Size {
        if (choices == null || choices.isEmpty()) return Size(1280, 720)
        val sorted = choices.sortedByDescending { it.width.toLong() * it.height }
        return sorted.firstOrNull { it.width <= 1280 && it.height <= 720 } ?: sorted.last()
    }

    /** 24..30 fps if the camera has it, else the steadiest range up to 30. */
    private fun chooseFps(
        ranges: Array<android.util.Range<Int>>?,
    ): android.util.Range<Int>? {
        if (ranges == null || ranges.isEmpty()) return null
        val to30 = ranges.filter { it.upper == 30 }
        return to30.firstOrNull { it.lower == 24 }
            ?: to30.filter { it.lower <= 30 }.maxByOrNull { it.lower }
    }

    private fun buildChain() {
        source = GPUPixelSourceRawData.Create()
        lipstick = GPUPixelFilter.Create(GPUPixelFilter.LIPSTICK_FILTER)
        blusher = GPUPixelFilter.Create(GPUPixelFilter.BLUSHER_FILTER)
        beauty = GPUPixelFilter.Create(GPUPixelFilter.BEAUTY_FACE_FILTER)
        reshape = GPUPixelFilter.Create(GPUPixelFilter.FACE_RESHAPE_FILTER)
        sink = GPUPixelSinkRawData.Create()
        detector = FaceDetector.Create()
        source!!.AddSink(lipstick!!)
        lipstick!!.AddSink(blusher!!)
        blusher!!.AddSink(beauty!!)
        beauty!!.AddSink(reshape!!)
        // 13 Nov 2026: a GPUPixel CONTRAST_FILTER here crashed the app as
        // the camera opened (native) - removed; only the 5 filters above.
        reshape!!.AddSink(sink!!)
        paramsDirty = true
    }

    private fun startSession(device: CameraDevice, r: ImageReader, h: Handler) {
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(r.surface)
            this.builder = builder
            @Suppress("DEPRECATION")
            device.createCaptureSession(listOf(r.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        session = s
                        builder.set(CaptureRequest.CONTROL_AF_MODE,
                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        builder.set(CaptureRequest.CONTROL_AE_MODE,
                            CaptureRequest.CONTROL_AE_MODE_ON)
                        builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION,
                            aeIndex())
                        if (facePriority) {
                            builder.set(CaptureRequest.CONTROL_MODE,
                                CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
                            builder.set(CaptureRequest.CONTROL_SCENE_MODE,
                                CaptureRequest.CONTROL_SCENE_MODE_FACE_PRIORITY)
                        }
                        repeat(s, builder)
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        Log.e(tag, "session config failed")
                    }
                }, h)
        } catch (ex: Throwable) {
            Log.e(tag, "session", ex)
        }
    }

    /** Sets the light-dependent parts (fps, sharpening, noise) and repeats. */
    private fun repeat(s: CameraCaptureSession, b: CaptureRequest.Builder) {
        try {
            val low = lowLight
            (if (low) fpsLow ?: fpsRange else fpsRange)?.let {
                b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
            }
            b.set(CaptureRequest.EDGE_MODE,
                if (low) CaptureRequest.EDGE_MODE_FAST
                else CaptureRequest.EDGE_MODE_HIGH_QUALITY)
            b.set(CaptureRequest.NOISE_REDUCTION_MODE,
                if (low) CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY
                else CaptureRequest.NOISE_REDUCTION_MODE_FAST)
            s.setRepeatingRequest(b.build(), lightWatch, handler)
        } catch (ex: Throwable) {
            Log.e(tag, "repeating request", ex)
        }
    }

    /** Watches the ISO the camera picks to switch low light on / off. */
    private val lightWatch = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(
            s: CameraCaptureSession,
            request: CaptureRequest,
            result: TotalCaptureResult,
        ) {
            val iso = result.get(CaptureResult.SENSOR_SENSITIVITY) ?: return
            val exp = result.get(CaptureResult.SENSOR_EXPOSURE_TIME) ?: 0L
            lastIso = iso
            lastExpNs = exp
            val hi = if (isoMax > 0) minOf(isoMax / 2, 1600) else 1600
            val lo = hi * 3 / 10
            // Dark = high ISO, or the shutter already at the 30 fps limit
            // (~33 ms) with a medium-high ISO.
            val dark = iso >= hi || (exp >= 28_000_000L && iso >= hi / 2)
            var change = false
            if (!lowLight) {
                darkFrames = if (dark) darkFrames + 1 else 0
                if (darkFrames >= 20) change = true
            } else {
                brightFrames = if (iso <= lo) brightFrames + 1 else 0
                if (brightFrames >= 45) change = true
            }
            if (!change) return
            lowLight = !lowLight
            darkFrames = 0
            brightFrames = 0
            Log.i(tag, "low light ${if (lowLight) "on" else "off"} (iso $iso)")
            val b = builder ?: return
            repeat(s, b)
        }
    }

    private fun applyParams() {
        val p = params
        beauty?.SetProperty("skin_smoothing", (p["smooth"] ?: 0.0).toFloat())
        // 10 Nov 2026 (Ko: "the skin is too white"): GPUPixel's whiteness is
        // strong - the slider's 100 = 0.4 of it now. Lipstick likewise 0.6.
        beauty?.SetProperty("whiteness", ((p["white"] ?: 0.0) * 0.4).toFloat())
        // The GPUPixel demo's ranges are thin face 0..1/16, big eye 0..1/4;
        // 12 Nov 2026 (Ko wants a much stronger "Glam" look) the sliders go a
        // bit further now: thin face 0..1/12, big eye 0..1/3.
        reshape?.SetProperty("thin_face", ((p["thin"] ?: 0.0) / 12.0).toFloat())
        reshape?.SetProperty("big_eye", ((p["eyes"] ?: 0.0) / 3.0).toFloat())
        lipstick?.SetProperty("blend_level", ((p["lips"] ?: 0.0) * 0.6).toFloat())
        blusher?.SetProperty("blend_level", (p["blush"] ?: 0.0).toFloat())
    }

    // ------------------------------------------------------------ frames
    private fun onFrame(r: ImageReader) {
        val image = try { r.acquireLatestImage() } catch (_: Throwable) { null } ?: return
        try {
            if (!running || source == null) return
            if (paramsDirty) {
                paramsDirty = false
                applyParams()
            }
            val w = image.width
            val h = image.height
            val rgba = GPUPixel.YUV_420_888toRGBA(image)
            val rotation = GPUPixel.calculateRotation(activity, sensorOrientation, isFront)
            val upright = GPUPixel.rotateRgbaImage(rgba, w, h, rotation)
            val ow = if (rotation == 90 || rotation == 270) h else w
            val oh = if (rotation == 90 || rotation == 270) w else h

            val landmarks = detector?.detect(upright, ow, oh, ow * 4,
                FaceDetector.GPUPIXEL_MODE_FMT_VIDEO, FaceDetector.GPUPIXEL_FRAME_TYPE_RGBA)
            if (landmarks != null && landmarks.isNotEmpty()) {
                reshape?.SetProperty("face_landmark", landmarks)
                lipstick?.SetProperty("face_landmark", landmarks)
                blusher?.SetProperty("face_landmark", landmarks)
            }
            source!!.ProcessData(upright, ow, oh, ow * 4, GPUPixelSourceRawData.FRAME_TYPE_RGBA)
            val out = sink?.GetRgbaBuffer() ?: return
            val sw = sink!!.GetWidth()
            val sh = sink!!.GetHeight()
            if (sw <= 0 || sh <= 0 || out.size < sw * sh * 4) return
            draw(out, sw, sh)
            countFps()
        } catch (ex: Throwable) {
            Log.e(tag, "frame", ex)
        } finally {
            image.close()
        }
    }

    private fun draw(rgba: ByteArray, w: Int, h: Int) {
        val s = surface ?: return
        var b = bitmap
        if (b == null || b.width != w || b.height != h) {
            b?.recycle()
            b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bitmap = b
            entry?.surfaceTexture()?.setDefaultBufferSize(w, h)
        }
        b!!.copyPixelsFromBuffer(ByteBuffer.wrap(rgba, 0, w * h * 4))
        val canvas = try {
            if (Build.VERSION.SDK_INT >= 23) s.lockHardwareCanvas() else s.lockCanvas(null)
        } catch (_: Throwable) { null } ?: return
        try {
            canvas.drawBitmap(b, null, Rect(0, 0, canvas.width, canvas.height), paint)
        } finally {
            s.unlockCanvasAndPost(canvas)
        }
        // The same beautified frame into the video file.
        if (recorder.isRecording) recorder.drawFrame(b)
    }

    private fun countFps() {
        val now = System.currentTimeMillis()
        if (fpsStart == 0L) fpsStart = now
        frames++
        if (now - fpsStart >= 1000) {
            lastFps = frames * 1000.0 / (now - fpsStart)
            frames = 0
            fpsStart = now
        }
    }

    // ------------------------------------------------------------- stop
    private fun stop() {
        running = false
        closeCamera()
        val h = handler
        val t = thread
        if (h != null) {
            // Free GPUPixel on its own thread, then end the thread.
            h.post {
                try { if (recorder.isRecording) recorder.stop() } catch (_: Throwable) {}
                try {
                    source?.Destroy(); lipstick?.Destroy(); blusher?.Destroy()
                    beauty?.Destroy(); reshape?.Destroy(); sink?.Destroy()
                    detector?.destroy()
                } catch (_: Throwable) {}
                source = null; lipstick = null; blusher = null
                beauty = null; reshape = null; sink = null; detector = null
                main.post {
                    try { surface?.release() } catch (_: Throwable) {}
                    surface = null
                    try { entry?.release() } catch (_: Throwable) {}
                    entry = null
                    bitmap?.recycle()
                    bitmap = null
                }
                t?.quitSafely()
            }
        } else {
            try { surface?.release() } catch (_: Throwable) {}
            surface = null
            try { entry?.release() } catch (_: Throwable) {}
            entry = null
        }
        handler = null
        thread = null
    }
}
