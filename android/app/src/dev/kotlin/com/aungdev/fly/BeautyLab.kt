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
// (smooth / white / thin / eyes / lips / blush, 0..1), stop.

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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(result)
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
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ start
    @SuppressLint("MissingPermission")
    private fun start(result: MethodChannel.Result) {
        if (running) stop()
        try {
            GPUPixel.Init(activity)
            val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            var id: String? = null
            for (cid in manager.cameraIdList) {
                val c = manager.getCameraCharacteristics(cid)
                if (c.get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_FRONT) {
                    id = cid
                    break
                }
            }
            if (id == null) id = manager.cameraIdList.firstOrNull()
            if (id == null) {
                result.error("no_camera", "No camera", null)
                return
            }
            val chars = manager.getCameraCharacteristics(id)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 270
            val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val size = chooseSize(map?.getOutputSizes(SurfaceTexture::class.java))

            val t = HandlerThread("BeautyLab").also { it.start() }
            thread = t
            val h = Handler(t.looper)
            handler = h

            // Upright (portrait) output size.
            val outW = size.height
            val outH = size.width
            val e = textures.createSurfaceTexture()
            entry = e
            e.surfaceTexture().setDefaultBufferSize(outW, outH)
            surface = Surface(e.surfaceTexture())

            val r = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            reader = r
            r.setOnImageAvailableListener({ onFrame(it) }, h)

            // GPUPixel chain on the camera thread.
            h.post { buildChain() }

            running = true
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

            result.success(mapOf("textureId" to e.id(), "width" to outW, "height" to outH))
        } catch (ex: Throwable) {
            Log.e(tag, "start failed", ex)
            stop()
            result.error("start_failed", ex.toString(), null)
        }
    }

    private fun chooseSize(choices: Array<Size>?): Size {
        if (choices == null || choices.isEmpty()) return Size(1280, 720)
        val sorted = choices.sortedByDescending { it.width.toLong() * it.height }
        return sorted.firstOrNull { it.width <= 1280 && it.height <= 720 } ?: sorted.last()
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
        reshape!!.AddSink(sink!!)
        paramsDirty = true
    }

    private fun startSession(device: CameraDevice, r: ImageReader, h: Handler) {
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(r.surface)
            @Suppress("DEPRECATION")
            device.createCaptureSession(listOf(r.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(s: CameraCaptureSession) {
                        session = s
                        builder.set(CaptureRequest.CONTROL_AF_MODE,
                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                        builder.set(CaptureRequest.CONTROL_AE_MODE,
                            CaptureRequest.CONTROL_AE_MODE_ON)
                        try {
                            s.setRepeatingRequest(builder.build(), null, h)
                        } catch (ex: Throwable) {
                            Log.e(tag, "repeating request", ex)
                        }
                    }
                    override fun onConfigureFailed(s: CameraCaptureSession) {
                        Log.e(tag, "session config failed")
                    }
                }, h)
        } catch (ex: Throwable) {
            Log.e(tag, "session", ex)
        }
    }

    private fun applyParams() {
        val p = params
        beauty?.SetProperty("skin_smoothing", (p["smooth"] ?: 0.0).toFloat())
        beauty?.SetProperty("whiteness", (p["white"] ?: 0.0).toFloat())
        // The GPUPixel demo's ranges: thin face 0..1/16, big eye 0..1/4.
        reshape?.SetProperty("thin_face", ((p["thin"] ?: 0.0) / 16.0).toFloat())
        reshape?.SetProperty("big_eye", ((p["eyes"] ?: 0.0) / 4.0).toFloat())
        lipstick?.SetProperty("blend_level", (p["lips"] ?: 0.0).toFloat())
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
            val rotation = GPUPixel.calculateRotation(activity, sensorOrientation, true)
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
        try { session?.close() } catch (_: Throwable) {}
        session = null
        try { camera?.close() } catch (_: Throwable) {}
        camera = null
        try { reader?.close() } catch (_: Throwable) {}
        reader = null
        val h = handler
        val t = thread
        if (h != null) {
            // Free GPUPixel on its own thread, then end the thread.
            h.post {
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
