#include <metal_stdlib>
using namespace metal;

// Taki's voice orb: a ~1M-vertex sphere generated entirely on the GPU (no vertex buffers, so it costs the
// memory-limited keyboard almost nothing). Each vertex is pushed along its normal by layered noise ("liquid")
// whose strength comes from the voice spectrum (low / mid / high energy each drive one lobe field).

struct OrbUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float time;
    float level;     // smoothed loudness 0…1
    float speaking;  // smoothed voice gate 0…1
    float calm;      // 1 while finishing up: the orb settles
    uint cols;
    uint rows;
    float motion;    // 1 normally, lower with Reduce Motion
    float dark;      // 1 in dark mode: adds a faint violet rim so the edge reads on a dark keyboard
};

struct VOut {
    float4 position [[position]];
    float3 world;
    float displacement;
    float energy;
};

// Simplex noise, Ashima Arts / Stefan Gustavson (MIT).
static float3 mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 mod289(float4 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
static float4 permute(float4 x) { return mod289(((x * 34.0) + 10.0) * x); }
static float4 taylorInvSqrt(float4 r) { return 1.79284291400159 - 0.85373472095314 * r; }

static float snoise(float3 v) {
    const float2 C = float2(1.0 / 6.0, 1.0 / 3.0);
    const float4 D = float4(0.0, 0.5, 1.0, 2.0);
    float3 i = floor(v + dot(v, C.yyy));
    float3 x0 = v - i + dot(i, C.xxx);
    float3 g = step(x0.yzx, x0.xyz);
    float3 l = 1.0 - g;
    float3 i1 = min(g.xyz, l.zxy);
    float3 i2 = max(g.xyz, l.zxy);
    float3 x1 = x0 - i1 + C.xxx;
    float3 x2 = x0 - i2 + C.yyy;
    float3 x3 = x0 - D.yyy;
    i = mod289(i);
    float4 p = permute(permute(permute(i.z + float4(0.0, i1.z, i2.z, 1.0)) + i.y + float4(0.0, i1.y, i2.y, 1.0)) + i.x + float4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    float3 ns = n_ * D.wyz - D.xzx;
    float4 j = p - 49.0 * floor(p * ns.z * ns.z);
    float4 x_ = floor(j * ns.z);
    float4 y_ = floor(j - 7.0 * x_);
    float4 x = x_ * ns.x + ns.yyyy;
    float4 y = y_ * ns.x + ns.yyyy;
    float4 h = 1.0 - abs(x) - abs(y);
    float4 b0 = float4(x.xy, y.xy);
    float4 b1 = float4(x.zw, y.zw);
    float4 s0 = floor(b0) * 2.0 + 1.0;
    float4 s1 = floor(b1) * 2.0 + 1.0;
    float4 sh = -step(h, float4(0.0));
    float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    float3 p0 = float3(a0.xy, h.x);
    float3 p1 = float3(a0.zw, h.y);
    float3 p2 = float3(a1.xy, h.z);
    float3 p3 = float3(a1.zw, h.w);
    float4 norm = taylorInvSqrt(float4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3)));
    p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
    float4 m = max(0.5 - float4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
    m = m * m;
    return 105.0 * dot(m * m, float4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

vertex VOut orb_vertex(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       constant OrbUniforms &u [[buffer(0)]],
                       constant float3 &voice [[buffer(1)]]) {
    // One triangle strip per latitude row; instance = row.
    uint col = vid >> 1;
    uint row = iid + (vid & 1);
    float lon = float(col) / float(u.cols) * 2.0 * M_PI_F;
    float lat = float(row) / float(u.rows) * M_PI_F;
    float3 n = float3(sin(lat) * cos(lon), cos(lat), sin(lat) * sin(lon));

    // Only big, slow lobes (David's reference: 4–6 broad bumps, never wrinkles). Each voice range drives
    // its own lobe field: lows swell the widest lobes, mids and highs the slightly smaller ones.
    float t = u.time;
    float wide = snoise(n * 0.95 + float3(0.0, t * 0.30, t * 0.18));
    float mid = snoise(n * 1.3 + float3(t * 0.40, -t * 0.25, t * 0.22) + 7.3);
    float tight = snoise(n * 1.7 + float3(-t * 0.50, t * 0.35, -t * 0.30) + 13.1);

    float idle = 0.075 * wide + 0.035 * mid;
    float speech = u.speaking * (0.13 * voice.x * wide + 0.09 * voice.y * mid + 0.06 * voice.z * tight)
                 + 0.04 * u.level;
    float d = (idle + speech * u.motion) * (1.0 - 0.6 * u.calm);
    float e = u.speaking * (voice.x + voice.y + voice.z) / 3.0;

    float4 world = u.model * float4(n * (1.0 + d), 1.0);
    VOut out;
    out.position = u.viewProjection * world;
    out.world = world.xyz;
    out.displacement = d;
    out.energy = e * u.speaking;
    return out;
}

// Glossy deep-purple blob (David's reference): dark valleys, lighter violet on the peaks, soft wet highlights.
fragment float4 orb_fragment(VOut in [[stage_in]], constant OrbUniforms &u [[buffer(0)]]) {
    float3 eye = float3(0.0, 0.0, 4.3);
    float3 v = normalize(eye - in.world);
    float3 nrm = normalize(cross(dfdx(in.world), dfdy(in.world)));
    if (dot(nrm, v) < 0.0) nrm = -nrm;

    float3 light = normalize(float3(-0.45, 0.75, 0.8));
    float3 fill = normalize(float3(0.6, -0.2, 0.7));
    float ndl = saturate(dot(nrm, light) * 0.75 + 0.25);
    float ndf = saturate(dot(nrm, fill));
    float ndv = saturate(dot(nrm, v));
    float3 h = normalize(light + v);

    const float3 shadow = float3(0.07, 0.0, 0.14);    // #12002a
    const float3 base = float3(0.235, 0.02, 0.376);   // #3c0560
    const float3 peak = float3(0.42, 0.06, 0.68);     // #6b0fad
    float3 color = mix(shadow, base, ndl);
    float rise = saturate(in.displacement * 5.0 + 0.35);
    color = mix(color, peak, rise * ndl * (0.45 + 0.35 * in.energy));
    color += base * ndf * 0.18;
    color *= mix(0.55, 1.0, saturate(in.displacement * 6.0 + 0.6));   // valleys pool shadow
    color *= mix(0.6, 1.0, ndv);                                        // edges fall off like the reference

    float spec = pow(saturate(dot(nrm, h)), 18.0) * 0.14 + pow(saturate(dot(nrm, h)), 60.0) * 0.12;
    color += float3(0.95, 0.9, 1.0) * spec;
    color += float3(0.45, 0.25, 0.75) * pow(1.0 - ndv, 3.0) * 0.5 * u.dark;
    color *= 1.0 - 0.2 * u.calm;
    return float4(color, 1.0);
}

// Taki's idle mic bar: a 2D lava lamp. Wax pools along the top and bottom edges, mounds rise and drip,
// and droplets pinch off, travel across, and merge into the opposite pool (smooth-min metaballs).
// The field is turned into a dome height map so it's lit with the same glossy purple as the voice orb.
struct LavaUniforms {
    float2 size;   // points
    float time;
    float scale;   // pixels per point
};

struct LavaOut { float4 position [[position]]; };

vertex LavaOut lava_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    LavaOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

static float lavaSmin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

static float lavaCapsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float k = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * k) - r;
}

static float lavaHash(float n) { return fract(sin(n * 127.1) * 43758.5453); }

/// Signed distance (points) to the wax; negative inside.
/// Triangle wave with sin's period and range: everything moves at a constant speed instead of easing.
static float lavaWave(float x) {
    return 1.0 - 4.0 * abs(fract(x / 6.2831853 + 0.25) - 0.5);
}

static float lavaField(float2 p, float2 size, float t) {
    float w = size.x, h = size.y;
    float bottom = 4.5;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float dx = (p.x - w * (fi + 0.5) / 4.0 - lavaWave(t * 0.09 + fi) * 20.0) / 22.0;
        bottom += h * (0.05 + 0.04 * lavaWave(t * 0.3 + fi * 1.3)) * exp(-dx * dx);
    }
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float dx = (p.x - w * (fi + 0.5) / 6.0 - lavaWave(t * 0.13 + fi * 1.7) * w * 0.035) / 11.0;
        bottom += h * 0.1 * (0.6 + 0.4 * lavaWave(t * 0.45 + fi * 2.3)) * exp(-dx * dx);
    }
    float d = min((h - bottom) - p.y, p.y - 5.5);
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float cx = w * (fi + 0.5) / 6.0 + lavaWave(t * 0.13 + fi * 1.7) * w * 0.035;
        float r = 5.5 + 2.0 * lavaHash(fi + 3.0);
        float rise = h * (0.3 + 0.22 * lavaWave(t * 0.45 + fi * 2.3));
        d = lavaSmin(d, lavaCapsule(p, float2(cx, h - 2.0), float2(cx, h - 5.0 - max(rise - r, 0.0)), r), 8.0);
    }
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float cx = w * (0.2 + 0.3 * fi) + lavaWave(t * 0.11 + fi * 2.9) * w * 0.05;
        float r = 4.5 + 1.5 * lavaHash(fi + 7.0);
        float drip = h * (0.12 + 0.1 * lavaWave(t * 0.37 + fi * 1.9));
        d = lavaSmin(d, lavaCapsule(p, float2(cx, 2.0), float2(cx, 5.5 + max(drip - r, 0.0)), r), 6.0);
    }
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float speed = 0.065;
        float phase = fract(t * speed + lavaHash(fi + 23.0));
        bool rising = i != 1;
        float y = rising ? mix(h + 2.0, -2.0, phase) : mix(-2.0, h + 2.0, phase);
        float x = w * (0.08 + 0.84 * lavaHash(fi + 37.0)) + lavaWave(t * 0.3 + fi * 4.1) * 6.0;
        float r = 4.0 + 2.5 * lavaHash(fi + 51.0);
        d = lavaSmin(d, length(p - float2(x, y)) - r, 6.0);
    }
    return d;
}

static float waxHeight(float2 p, float2 size, float t) {
    const float dome = 7.0;
    float s = clamp(-lavaField(p, size, t) / dome, 0.0, 1.0);
    return dome * sqrt(1.0 - (1.0 - s) * (1.0 - s));
}

fragment float4 lava_fragment(LavaOut in [[stage_in]], constant LavaUniforms &u [[buffer(0)]]) {
    float2 p = in.position.xy / u.scale;
    float d = lavaField(p, u.size, u.time);
    float e = 0.6;
    float hx = waxHeight(p + float2(e, 0), u.size, u.time) - waxHeight(p - float2(e, 0), u.size, u.time);
    float hy = waxHeight(p + float2(0, e), u.size, u.time) - waxHeight(p - float2(0, e), u.size, u.time);
    float3 n = normalize(float3(-hx / (2.0 * e), -hy / (2.0 * e), 1.0));

    float3 light = normalize(float3(-0.35, -0.75, 0.55));
    float diffuse = max(dot(n, light), 0.0);
    float spec = pow(max(dot(n, normalize(light + float3(0, 0, 1))), 0.0), 18.0);
    float rim = pow(1.0 - n.z, 2.0);

    float3 deep = float3(0.34, 0.15, 0.68);
    float3 base = float3(0.63, 0.40, 0.98);
    float3 wax = mix(deep, base, 0.3 + 0.7 * diffuse) + rim * float3(0.40, 0.32, 0.55) + spec * float3(1.0, 0.94, 1.0) * 0.55;

    float3 background = mix(float3(0.05, 0.02, 0.10), float3(0.20, 0.07, 0.36), smoothstep(0.1, 1.0, p.y / u.size.y));
    float coverage = clamp(0.5 - d * u.scale, 0.0, 1.0);
    return float4(mix(background, wax, coverage), 1.0);
}

// The hand-off between the lava bar and the voice orb: the bar's mound tips and drips pinch off as droplets,
// arc down across the keyboard, grow and merge into one ball the size of the orb (run backwards to return).
// Lit like the lava at the start and like the orb at the end so both ends match the real views exactly.
struct MorphUniforms {
    float2 size;      // points, whole keyboard
    float scale;      // pixels per point
    float lavaTime;   // same clock as the bar
    float progress;   // 0 = lava bar, 1 = orb
    float calm;       // the orb's settle amount (it shrinks and dims while finishing)
    float dark;
    float pad;
    float4 bar;       // bar rect in points: x, y, width, height
    float2 center;    // orb centre, points
    float radius;     // orb silhouette radius, points
    float corner;     // bar corner radius
};

static float morphBox(float2 p, float4 rect, float r) {
    float2 q = abs(p - (rect.xy + rect.zw * 0.5)) - rect.zw * 0.5 + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

/// Tip (local xy, radius) of the bar's six rising mounds and three drips, exactly as `lavaField` places them.
static float3 morphSource(int i, float2 size, float t) {
    float w = size.x, h = size.y;
    if (i < 6) {
        float fi = float(i);
        float cx = w * (fi + 0.5) / 6.0 + lavaWave(t * 0.13 + fi * 1.7) * w * 0.035;
        float r = 5.5 + 2.0 * lavaHash(fi + 3.0);
        float rise = h * (0.3 + 0.22 * lavaWave(t * 0.45 + fi * 2.3));
        return float3(cx, h - 5.0 - max(rise - r, 0.0), r);
    }
    float fi = float(i - 6);
    float cx = w * (0.2 + 0.3 * fi) + lavaWave(t * 0.11 + fi * 2.9) * w * 0.05;
    float r = 4.5 + 1.5 * lavaHash(fi + 7.0);
    float drip = h * (0.12 + 0.1 * lavaWave(t * 0.37 + fi * 1.9));
    return float3(cx, 5.5 + max(drip - r, 0.0), r);
}

static float morphField(float2 p, constant MorphUniforms &u) {
    float k = u.progress;
    float blend = mix(6.0, 0.25 * u.radius, 4.0 * k * (1.0 - k));
    float d = 1e4;
    float box = morphBox(p, u.bar, u.corner);
    if (box < 12.0 && k < 0.6) {
        d = max(lavaField(p - u.bar.xy, u.bar.zw, u.lavaTime) + 24.0 * smoothstep(0.0, 0.45, k), box);
    }
    for (int i = 0; i < 9; i++) {
        float3 s = morphSource(i, u.bar.zw, u.lavaTime);
        float2 a = u.bar.xy + s.xy;
        float delay = 0.03 * float(i % 6) + 0.12 * lavaHash(float(i) + 61.0);
        float f = smoothstep(delay, delay + 0.6, k);
        float2 end = u.center + (float2(lavaHash(float(i) + 71.0), lavaHash(float(i) + 83.0)) - 0.5) * u.radius * 0.5;
        float2 ctrl = float2(mix(a.x, u.center.x, 0.2), mix(a.y, u.center.y, 0.85));
        float2 c = mix(mix(a, ctrl, f), mix(ctrl, end, f), f);
        float r = mix(s.z, 0.42 * u.radius, f);
        d = lavaSmin(d, length(p - c) - r, blend);
    }
    float core = u.radius * smoothstep(0.35, 0.92, k);
    if (core > 0.5) d = lavaSmin(d, length(p - u.center) - core, blend);
    return d;
}

static float morphHeight(float2 p, constant MorphUniforms &u, float dome) {
    float s = clamp(-morphField(p, u) / dome, 0.0, 1.0);
    return dome * sqrt(1.0 - (1.0 - s) * (1.0 - s));
}

fragment float4 morph_fragment(LavaOut in [[stage_in]], constant MorphUniforms &u [[buffer(0)]]) {
    float2 p = in.position.xy / u.scale;
    float k = u.progress;

    float box = morphBox(p, u.bar, u.corner);
    float barAlpha = (1.0 - smoothstep(0.05, 0.4, k)) * clamp(0.5 - box * u.scale, 0.0, 1.0);
    float3 background = mix(float3(0.05, 0.02, 0.10), float3(0.20, 0.07, 0.36),
                            smoothstep(0.1, 1.0, (p.y - u.bar.y) / u.bar.w));

    float d = morphField(p, u);
    float coverage = clamp(0.5 - d * u.scale, 0.0, 1.0);
    if (coverage <= 0.0) return float4(background * barAlpha, barAlpha);

    float dome = mix(7.0, u.radius, smoothstep(0.25, 1.0, k));
    float e = 0.6;
    float hx = morphHeight(p + float2(e, 0), u, dome) - morphHeight(p - float2(e, 0), u, dome);
    float hy = morphHeight(p + float2(0, e), u, dome) - morphHeight(p - float2(0, e), u, dome);
    float3 n = normalize(float3(-hx / (2.0 * e), -hy / (2.0 * e), 1.0));

    // Lava bar look (matches lava_fragment).
    float3 light = normalize(float3(-0.35, -0.75, 0.55));
    float diffuse = max(dot(n, light), 0.0);
    float spec = pow(max(dot(n, normalize(light + float3(0, 0, 1))), 0.0), 18.0);
    float rim = pow(1.0 - n.z, 2.0);
    float3 lava = mix(float3(0.34, 0.15, 0.68), float3(0.63, 0.40, 0.98), 0.3 + 0.7 * diffuse)
                + rim * float3(0.40, 0.32, 0.55) + spec * float3(1.0, 0.94, 1.0) * 0.55;

    // Orb look (matches orb_fragment at rest; screen y points down).
    float3 orbLight = normalize(float3(-0.45, -0.75, 0.8));
    float3 orbFill = normalize(float3(0.6, 0.2, 0.7));
    float ndl = saturate(dot(n, orbLight) * 0.75 + 0.25);
    float ndf = saturate(dot(n, orbFill));
    float ndv = saturate(n.z);
    float3 h = normalize(orbLight + float3(0, 0, 1));
    const float3 shadow = float3(0.07, 0.0, 0.14);
    const float3 base = float3(0.235, 0.02, 0.376);
    const float3 peak = float3(0.42, 0.06, 0.68);
    float3 orb = mix(shadow, base, ndl);
    orb = mix(orb, peak, 0.35 * ndl * 0.45);
    orb += base * ndf * 0.18;
    orb *= 0.82;
    orb *= mix(0.6, 1.0, ndv);
    orb += float3(0.95, 0.9, 1.0) * (pow(saturate(dot(n, h)), 18.0) * 0.14 + pow(saturate(dot(n, h)), 60.0) * 0.12);
    orb += float3(0.45, 0.25, 0.75) * pow(1.0 - ndv, 3.0) * 0.5 * u.dark;
    orb *= 1.0 - 0.2 * u.calm;

    float3 wax = mix(lava, orb, smoothstep(0.25, 0.9, k));
    float under = barAlpha * (1.0 - coverage);
    return float4(wax * coverage + background * under, coverage + under);
}
