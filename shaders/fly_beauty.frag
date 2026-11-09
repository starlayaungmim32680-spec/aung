// Fly Beauty Engine (9 Nov 2026) - runs on the phone's GPU through
// ImageFilter.shader (Impeller). Used on the Record camera AND on playback
// (feed, story viewer, upload / effects previews), so viewers see the same
// beautified video - nothing is baked into the file.
//
// Uniform order matters (lib/screens/fly_beauty.dart sets them):
//   0,1  uSize    - set by Flutter for ImageFilter.shader
//   2    uSmooth  - 0..1 skin smoothing (edge-preserving, skin only)
//   3    uBright  - 0..1 skin brightening + soft glow
//   4    uRosy    - 0..1 a little blush on the skin
//   5    uNight   - 0..1 low-light boost (shadow lift + noise cleanup)
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uSmooth;
uniform float uBright;
uniform float uRosy;
uniform float uNight;
uniform sampler2D uTexture;

out vec4 fragColor;

// How "skin-like" a colour is (0..1), from its Cr / Cb chroma.
float skinMask(vec3 c) {
  float y = dot(c, vec3(0.299, 0.587, 0.114));
  float cr = (c.r - y) * 0.713 + 0.5;
  float cb = (c.b - y) * 0.564 + 0.5;
  float dCr = abs(cr - 0.588) / 0.11;
  float dCb = abs(cb - 0.431) / 0.11;
  float m = 1.0 - max(dCr, dCb);
  // Very dark or blown-out pixels are not skin.
  m *= smoothstep(0.08, 0.2, y) * (1.0 - smoothstep(0.95, 1.0, y));
  return clamp(m, 0.0, 1.0);
}

vec3 sampleAt(vec2 uv) {
  return texture(uTexture, clamp(uv, vec2(0.0), vec2(1.0))).rgb;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = frag / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  vec4 src = texture(uTexture, uv);
  vec3 c = src.rgb;

  float strength = max(uSmooth, uNight * 0.6);
  if (strength > 0.001 || uBright > 0.001) {
    // Edge-preserving blur: 16 taps on two rings, each weighted by how
    // close its colour is to the centre (a cheap bilateral filter).
    float radius = mix(1.5, 5.5, strength) * (min(uSize.x, uSize.y) / 720.0);
    vec2 px = radius / uSize;
    float sigma = mix(0.06, 0.16, strength);
    vec3 sum = c;
    float wsum = 1.0;
    for (int i = 0; i < 8; i++) {
      float a = float(i) * 0.785398;
      vec2 d = vec2(cos(a), sin(a));
      for (int k = 1; k <= 2; k++) {
        vec3 s = sampleAt(uv + d * px * float(k));
        vec3 diff = s - c;
        float w = exp(-dot(diff, diff) / (2.0 * sigma * sigma));
        sum += s * w;
        wsum += w;
      }
    }
    vec3 blur = sum / wsum;

    float skin = skinMask(c);
    // Smooth the skin; in the dark also clean the noise everywhere a bit.
    c = mix(c, blur, clamp(skin * uSmooth + uNight * 0.45, 0.0, 1.0));

    // Low light: lift the shadows and mid-tones, keep the blacks.
    c += uNight * 0.9 * c * (1.0 - c);

    // Brighten the skin + a soft glow (screen blend with the blur).
    c += uBright * 0.35 * skin * (1.0 - c);
    c = 1.0 - (1.0 - c) * (1.0 - blur * uBright * 0.18);

    // Blush.
    c.r += uRosy * 0.07 * skin;
    c.g -= uRosy * 0.015 * skin;
  }

  fragColor = vec4(clamp(c, 0.0, 1.0) * src.a, src.a);
}
