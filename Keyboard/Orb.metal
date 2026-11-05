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
