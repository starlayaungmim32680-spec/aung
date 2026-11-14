package com.aungdev.fly

// Beauty Lab recorder (10 Nov 2026, Fly Dev only) - writes the GPUPixel
// (beautified) frames + the microphone into an mp4, so the beauty is
// baked into the video file itself.
//
//   video: every processed frame is drawn (hardware Canvas) onto the
//          input Surface of a MediaCodec H.264 encoder (6 Mbps, 30 fps,
//          1 s key frames) - same Bitmap that goes to the preview.
//   audio: AudioRecord 44.1 kHz mono PCM -> MediaCodec AAC-LC 128 kbps,
//          on its own thread.
//   both -> MediaMuxer (starts once both tracks are known). Timestamps
//          come from one clock (System.nanoTime) relative to the start.
//
// Used by BeautyLab.kt: start(w, h, file) on the camera thread, then
// drawFrame(bitmap) for each frame, then stop() -> the file.

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Rect
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import android.view.Surface
import java.io.File

class BeautyRecorder {
    private val tag = "BeautyRecorder"

    private var muxer: MediaMuxer? = null
    private var video: MediaCodec? = null
    private var audio: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var inputSurface: Surface? = null
    private var audioThread: Thread? = null

    private var videoTrack = -1
    private var audioTrack = -1
    @Volatile private var muxerStarted = false
    private val muxLock = Object()

    @Volatile private var recording = false
    private var startNs = 0L
    private var lastVideoUs = -1L
    private var lastAudioUs = -1L
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    var file: File? = null
        private set

    val isRecording get() = recording

    @SuppressLint("MissingPermission")
    fun start(width: Int, height: Int, out: File, withAudio: Boolean) {
        file = out
        // Encoders want even sizes.
        val w = width and 1.inv()
        val h = height and 1.inv()
        val vf = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val v = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        v.configure(vf, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = v.createInputSurface()
        v.start()
        video = v

        muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        videoTrack = -1
        audioTrack = -1
        muxerStarted = false
        lastVideoUs = -1L
        lastAudioUs = -1L
        startNs = System.nanoTime()
        recording = true

        if (withAudio) {
            try {
                startAudio()
            } catch (e: Throwable) {
                Log.e(tag, "audio off: $e")
                audio = null
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun startAudio() {
        val rate = 44100
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.CAMCORDER, rate,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minBuf * 2, 8192))
        val af = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val a = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        a.configure(af, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        a.start()
        audio = a
        audioRecord = rec
        rec.startRecording()
        audioThread = Thread({ audioLoop(rec, a) }, "BeautyAudio").also { it.start() }
    }

    private fun audioLoop(rec: AudioRecord, a: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        val chunk = ByteArray(4096)
        try {
            while (true) {
                val stop = !recording
                val inIdx = a.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val buf = a.getInputBuffer(inIdx)!!
                    buf.clear()
                    val n = if (stop) 0 else rec.read(chunk, 0, minOf(chunk.size, buf.capacity()))
                    val pts = (System.nanoTime() - startNs) / 1000
                    if (stop) {
                        a.queueInputBuffer(inIdx, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    } else if (n > 0) {
                        buf.put(chunk, 0, n)
                        a.queueInputBuffer(inIdx, 0, n, pts, 0)
                    } else {
                        a.queueInputBuffer(inIdx, 0, 0, pts, 0)
                    }
                }
                if (drain(a, info, isVideo = false, wait = false)) break
                if (stop) {
                    // Finish the remaining output, then end.
                    var tries = 0
                    while (!drain(a, info, isVideo = false, wait = true) && tries++ < 50) {}
                    break
                }
            }
        } catch (e: Throwable) {
            Log.e(tag, "audio loop", e)
        }
    }

    /** Draws one processed frame into the video (camera thread). */
    fun drawFrame(bitmap: Bitmap) {
        if (!recording) return
        val s = inputSurface ?: return
        try {
            val c = if (Build.VERSION.SDK_INT >= 23) s.lockHardwareCanvas() else return
            try {
                c.drawBitmap(bitmap, null, Rect(0, 0, c.width, c.height), paint)
            } finally {
                s.unlockCanvasAndPost(c)
            }
            video?.let { drain(it, MediaCodec.BufferInfo(), isVideo = true, wait = false) }
        } catch (e: Throwable) {
            Log.e(tag, "frame", e)
        }
    }

    /** Moves encoded data into the muxer. Returns true at end of stream. */
    private fun drain(codec: MediaCodec, info: MediaCodec.BufferInfo, isVideo: Boolean,
                      wait: Boolean): Boolean {
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, if (wait) 10_000 else 0)
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> return false
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    synchronized(muxLock) {
                        val m = muxer ?: return false
                        if (isVideo) videoTrack = m.addTrack(codec.outputFormat)
                        else audioTrack = m.addTrack(codec.outputFormat)
                        val needAudio = audio != null
                        if (!muxerStarted && videoTrack >= 0 && (!needAudio || audioTrack >= 0)) {
                            m.start()
                            muxerStarted = true
                        }
                    }
                }
                idx >= 0 -> {
                    val data = codec.getOutputBuffer(idx)
                    val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    if (data != null && info.size > 0 && !config) {
                        synchronized(muxLock) {
                            if (muxerStarted) {
                                val track = if (isVideo) videoTrack else audioTrack
                                // Video buffers carry the Surface clock (ns of
                                // System.nanoTime) - make both relative.
                                var pts = if (isVideo)
                                    info.presentationTimeUs - startNs / 1000
                                else info.presentationTimeUs
                                if (pts < 0) pts = 0
                                val last = if (isVideo) lastVideoUs else lastAudioUs
                                if (pts <= last) pts = last + 1
                                if (isVideo) lastVideoUs = pts else lastAudioUs = pts
                                info.presentationTimeUs = pts
                                data.position(info.offset)
                                data.limit(info.offset + info.size)
                                muxer?.writeSampleData(track, data, info)
                            }
                        }
                    }
                    codec.releaseOutputBuffer(idx, false)
                    if (eos) return true
                }
                else -> return false
            }
        }
    }

    /** Ends the recording (camera thread). Returns the mp4, or null. */
    fun stop(): File? {
        if (!recording) return null
        recording = false
        try {
            video?.let { v ->
                v.signalEndOfInputStream()
                val info = MediaCodec.BufferInfo()
                var tries = 0
                while (!drain(v, info, isVideo = true, wait = true) && tries++ < 100) {}
            }
        } catch (e: Throwable) {
            Log.e(tag, "video end", e)
        }
        try { audioThread?.join(2000) } catch (_: Throwable) {}
        try { audioRecord?.stop() } catch (_: Throwable) {}
        try { audioRecord?.release() } catch (_: Throwable) {}
        try { audio?.stop() } catch (_: Throwable) {}
        try { audio?.release() } catch (_: Throwable) {}
        try { video?.stop() } catch (_: Throwable) {}
        try { video?.release() } catch (_: Throwable) {}
        try { inputSurface?.release() } catch (_: Throwable) {}
        var ok = muxerStarted
        try {
            if (muxerStarted) muxer?.stop()
        } catch (e: Throwable) {
            Log.e(tag, "muxer stop", e)
            ok = false
        }
        try { muxer?.release() } catch (_: Throwable) {}
        audioRecord = null; audio = null; video = null; inputSurface = null
        muxer = null; audioThread = null; muxerStarted = false
        return if (ok) file else null
    }
}
