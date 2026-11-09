# Beauty Lab (9 Nov 2026): GPUPixel's native code (libgpupixel.so) calls
# back into these Java classes by name (JNI), so R8 must not rename or
# remove them in release builds. Only the dev flavor contains GPUPixel;
# this rule is harmless for prod.
-keep class com.pixpark.gpupixel.** { *; }
-dontwarn com.pixpark.gpupixel.**
