// stb_truetype, and a flat C ABI over it.
//
// ============================================================================
// F1 JUSTIFICATION -- recorded at the import site, as the rule requires.
//
//   WHAT IT DOES:  parses TrueType `glyf` outlines and rasterizes them to an 8-bit
//                  anti-aliased coverage bitmap. That is the whole of what we use.
//
//   WHY WE DO NOT  outline parsing plus a scanline anti-aliased fill is a real piece of
//   WRITE IT       work, it is not the game, and G3's stop rule points hard away from it.
//   OURSELVES:     The game's entire payload is prose on a black screen -- typography here
//                  is not decoration, it is the only channel the game has.
//
//   WHAT IT WOULD  delete this file, `vendor/stb_truetype.h`, `src/text.zig`, and the
//   COST TO        `addTextEngine` function in build.zig. It has ZERO transitive
//   REMOVE:        dependencies, it is vendored and pinned rather than fetched, and it is
//                  quarantined behind the rendering module (D7). An afternoon.
//
//   LICENCE:       stb_truetype v1.26, Sean Barrett. Public domain (Unlicense), per the
//                  dual-licence block at the foot of stb_truetype.h.
//
// This is the SECOND sanctioned dependency. F6 is explicit that it does not inherit the map
// SDK's blessing, and this block is the price of that.
//
// ============================================================================
// WHY THERE IS A SHIM, AND NOT A `@cImport`
//
// Zig does not ship bionic's headers, so `#include <math.h>` cannot resolve when cross-
// compiling C to an Android target without the NDK's sysroot. Making the NDK a prerequisite
// of `zig build` -- on every machine, for every developer, forever -- to type-check a phone
// file is a bad trade.
//
// So Zig never sees a C header. It declares this handful of functions as `extern fn`, exactly
// as `android.zig` declares the NDK and `gles.zig` declares GLES. The struct layout of
// `stbtt_fontinfo` stays on this side of the wall, where it belongs (D3): Zig asks how big it
// is and hands back a buffer of that size. It never needs to know what is in it.

// ============================================================================
// THESE ARE `glyphshim_*`, NOT `outbreak_*`. THAT IS NOT A STYLE CHOICE.
//
// `outbreak_*` is the C ABI -- the entire surface between the core and the phone -- and the
// way H1 is actually verified is by running `nm` on the shipped library and counting:
// there must be TEN `outbreak_*` functions and no more. What is absent is the point.
//
// Naming these eight `outbreak_font_init`, `outbreak_glyph_bitmap` and so on would have put
// eighteen `outbreak_*` symbols in the APK's .so, and the check that guards client authority
// would have started returning a number nobody could interpret. The audit would have decayed
// into "well, eight of those are font stuff" -- which is how a check dies.
//
// The ABI namespace is reserved for the ABI. Nothing else may enter it.

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

/// How many bytes Zig must allocate for one font face. Asked at runtime, so the layout of
/// `stbtt_fontinfo` never has to be mirrored -- and therefore can never drift.
size_t glyphshim_fontinfo_size(void) {
    return sizeof(stbtt_fontinfo);
}

/// Parse a TTF. Returns 0 on failure. `info` is `glyphshim_fontinfo_size()` bytes.
int glyphshim_font_init(void *info, const unsigned char *ttf) {
    return stbtt_InitFont((stbtt_fontinfo *)info, ttf, stbtt_GetFontOffsetForIndex(ttf, 0));
}

/// The factor that turns font units into pixels at a given pixel height.
float glyphshim_scale_for_pixel_height(const void *info, float pixels) {
    return stbtt_ScaleForPixelHeight((const stbtt_fontinfo *)info, pixels);
}

/// The glyph index for a codepoint, or the index for U+FFFD if the face has no such glyph.
/// Returns 0 only if the face has neither, in which case there is nothing to draw.
int glyphshim_find_glyph(const void *info, int codepoint) {
    int direct = stbtt_FindGlyphIndex((const stbtt_fontinfo *)info, codepoint);
    if (direct != 0) return direct;
    return stbtt_FindGlyphIndex((const stbtt_fontinfo *)info, 0xFFFD);
}

/// Horizontal metrics in FONT UNITS. The caller scales.
void glyphshim_glyph_hmetrics(const void *info, int glyph, int *advance, int *left_bearing) {
    stbtt_GetGlyphHMetrics((const stbtt_fontinfo *)info, glyph, advance, left_bearing);
}

/// Vertical metrics in FONT UNITS. The caller scales.
void glyphshim_font_vmetrics(const void *info, int *ascent, int *descent, int *line_gap) {
    stbtt_GetFontVMetrics((const stbtt_fontinfo *)info, ascent, descent, line_gap);
}

/// Rasterize one glyph to an 8-bit coverage bitmap. The caller MUST pass the result back to
/// `glyphshim_free_bitmap`. `x0`/`y0` are the bitmap's offset from the pen, y DOWN from the
/// baseline (so `y0` is normally negative: the glyph sits above the line).
unsigned char *glyphshim_glyph_bitmap(const void *info, float scale, int glyph,
                                     int *w, int *h, int *x0, int *y0) {
    return stbtt_GetGlyphBitmap((const stbtt_fontinfo *)info, scale, scale, glyph, w, h, x0, y0);
}

void glyphshim_free_bitmap(unsigned char *bitmap) {
    stbtt_FreeBitmap(bitmap, NULL);
}
