package com.aungdev.fly

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine

// Prod: the Beauty Lab (GPUPixel test) does not exist in the real app -
// see src/dev/kotlin/com/aungdev/fly/BeautyLab.kt. Same class name so
// MainActivity can call it in both flavors.
object BeautyLabRegistrar {
    fun register(activity: Activity, engine: FlutterEngine) {}
}
