# Beauty Lab (9 Nov 2026): GPUPixel's native code (libgpupixel.so) calls
# back into these Java classes by name (JNI), so R8 must not rename or
# remove them in release builds. Both flavors (dev and prod) contain
# GPUPixel since 14 Nov 2026 - this rule is required for both.
-keep class com.pixpark.gpupixel.** { *; }
-dontwarn com.pixpark.gpupixel.**
