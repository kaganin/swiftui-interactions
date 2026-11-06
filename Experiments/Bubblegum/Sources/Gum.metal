#include <metal_stdlib>
using namespace metal;

// Same 32-byte layout as the Swift renderer. No textures or external assets.
struct Parameters {
    float2 resolution; float inflation; float strain;
    float agitation; float phase; float burstTime; float burstEvent; // 0=intact; 1=reference; otherwise seed+1
};
struct Raster { float4 position [[position]]; float2 uv; };

vertex Raster gumVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return { float4(p * 2.0 - 1.0, 0, 1), p };
}

float ellipsoid(float3 p, float3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 0.0001);
}

float smoothUnion(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// Smooth material-space noise: irregular thickness, without repeated beach-ball seams.
float hash31(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

float tissueNoise(float3 p) {
    float3 cell = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(hash31(cell), hash31(cell + float3(1,0,0)), f.x);
    float b = mix(hash31(cell + float3(0,1,0)), hash31(cell + float3(1,1,0)), f.x);
    float c = mix(hash31(cell + float3(0,0,1)), hash31(cell + float3(1,0,1)), f.x);
    float d = mix(hash31(cell + float3(0,1,1)), hash31(cell + float3(1,1,1)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

float3 gumRadii(float inflation) {
    float radius = mix(0.29, 1.12, inflation);
    return radius * float3(1.03, mix(0.78, 1.0, smoothstep(0.0, 0.45, inflation)), 0.87);
}

// One profile is chosen for each inflation cycle and remains stable as it grows.
float2 shapeBias(float variation) {
    return sin(float2(variation * 6.2831853, variation * 11.938052));
}

float weakShoulder(float3 local, float variation = 0.0) {
    float2 bias = shapeBias(variation);
    float2 centre = (local.xy - float2(0.43 + 0.16 * bias.x, 0.34 + 0.09 * bias.y))
                  / float2(0.62, 0.46);
    return exp(-dot(centre, centre) * 1.5) * smoothstep(-0.35, 0.45, local.z);
}

// Shared inverse deformation: silhouette, pigment and thickness use one map.
float3 gumCoordinates(float3 p, float inflation, float strain, float variation = 0.0, float sway = 0.0) {
    float radius = mix(0.29, 1.12, inflation);
    float opened = smoothstep(0.0, 0.45, inflation);
    float taut = smoothstep(0.45, 1.0, strain);
    float opening = smoothstep(0.18, 0.72, inflation);
    float2 bias = shapeBias(variation);
    float3 q = p - float3(0, radius * (0.78 + 0.22 * opened) - 0.88, 0);
    float height = saturate((p.y + 0.90) / (2.0 * radius));
    q.x -= radius * (0.12 * height * height + 0.045 * sin(height * 3.7));
    q.x -= radius * 0.085 * bias.x * opening * height * height;
    q.x -= sway * smoothstep(-0.84, -0.16, p.y);
    q.z += radius * 0.055 * height
         - (0.31 + 0.018 * bias.y) * smoothstep(0.55, 0.90, inflation);
    q.x *= 1.0 - 0.045 * taut * smoothstep(0.2, 0.9, height);
    q.x *= 1.0 + 0.085 * bias.y * opening;
    q.z *= 1.0 + 0.035 * taut * height;
    q.y += radius * (0.045 + 0.024 * bias.y * opening)
         * sin(q.x / radius * 2.1 + 0.8 + 0.35 * bias.x * opening);
    float3 local = q / gumRadii(inflation);
    float limitLoad = smoothstep(0.65, 1.0, strain);
    // A weak patch starts yielding as the wad opens, then becomes the larger
    // pre-rupture shoulder. Geometry, area stretch and pigment share this map.
    float weakLoad = 0.06 * smoothstep(0.05, 0.42, inflation) + 0.09 * limitLoad;
    return local * (1.0 - weakLoad * weakShoulder(local, variation));
}

float areaStretch(float3 p, float inflation, float strain, float variation = 0.0, float sway = 0.0) {
    float e = mix(0.29, 1.12, inflation) * 0.002;
    float3 q = gumCoordinates(p, inflation, strain, variation, sway);
    float3 dx = (gumCoordinates(p + float3(e,0,0), inflation, strain, variation, sway) - q) / e;
    float3 dy = (gumCoordinates(p + float3(0,e,0), inflation, strain, variation, sway) - q) / e;
    float3 dz = (gumCoordinates(p + float3(0,0,e), inflation, strain, variation, sway) - q) / e;
    float3 normal = normalize(q + float3(0,0.00001,0));
    // For inverse deformation J, surface area = |J^T n| / |det J|.
    float worldArea = length(float3(dot(dx,normal), dot(dy,normal), dot(dz,normal)))
                    / max(abs(dot(dx, cross(dy,dz))), 0.00001);
    float3 restRadii = gumRadii(0.0);
    float restArea = restRadii.x * restRadii.y * restRadii.z * length(normal / restRadii);
    return max(1.0, worldArea / restArea);
}

float membraneThickness(float3 p, float inflation, float strain, float variation = 0.0, float sway = 0.0) {
    float3 local = gumCoordinates(p, inflation, strain, variation, sway);
    float stretched = smoothstep(0.15, 0.95, strain);
    float patch = tissueNoise(local * 3.5 + float3(4.1, 1.7, 0));
    float3 fibrePosition = local * float3(14, 5, 6) + float3(2, 8, 4);
    fibrePosition.x += sin(local.y * 4.0) * 0.65;
    float ridges = pow(smoothstep(0.50, 0.82, tissueNoise(fibrePosition)), 3.0);
    float rootThickness = 1.0 - smoothstep(-0.94, -0.78, local.y);
    // Retained material belongs to the small attachment, not a horizontal slab
    // across both walls of the inflated dome. Keep this matched on the CPU.
    float2 rootXZ = (p.xz - float2(-0.025, 0)) / float2(0.14, 0.13);
    float rootExtra = rootThickness * 0.004 * exp(-dot(rootXZ, rootXZ));
    float2 bias = shapeBias(variation);
    float2 shoulder = (local.xy - float2(0.20 + 0.12 * bias.x,
                                         0.30 + 0.07 * bias.y)) * float2(1.5, 1.2);
    float thinShoulder = exp(-dot(shoulder, shoulder));
    float material = (0.55 + patch * 1.15 + ridges * stretched * 0.12)
                   * (1.0 - thinShoulder * stretched * 0.55);
    float limitLoad = smoothstep(0.65, 1.0, strain);
    float weak = weakShoulder(local, variation);
    // Local necking makes the late-stage film visibly finer than the retained rim.
    // This is an authored strain-softening approximation, not a rupture solver.
    // Both dome walls thin faster than the grazing perimeter and retained root.
    // This reveals the background through the film while keeping a pink rim.
    float dome = pow(saturate(abs(local.z)), 3.0) * smoothstep(-0.70, -0.15, local.y);
    float stretch = areaStretch(p, inflation, strain, variation, sway);
    // The inflated caps thin ahead of the grazing edge, starting during the
    // first inflation rather than only near rupture. The narrow attachment
    // retains material while grazing rays still travel farther through the film.
    float thinCap = pow(saturate(abs(local.z)), 1.5) * smoothstep(-0.99, -0.72, local.y);
    float capThinning = mix(1.0, pow(stretch, -1.10), thinCap);
    float necking = mix(1.0, 0.62, limitLoad) * (1.0 - 0.60 * limitLoad * dome)
                  * (1.0 - 0.48 * limitLoad * weak);
    // Opening redistributes the wad into a film before the delayed strain
    // response catches up; the mouth attachment retains its local material.
    float startingThickness = mix(0.052, 0.023, smoothstep(0.01, 0.18, inflation));
    float earlyOpening = smoothstep(0.16, 0.30, inflation)
                       * (1.0 - smoothstep(0.38, 0.70, inflation));
    startingThickness *= 1.0 - 0.50 * earlyOpening;
    // A tiny residual layer prevents zero thickness without flattening the
    // material-space thickness variation across the taut dome.
    return 0.00004 + max(0.00003, startingThickness / stretch * material * necking * capThinning)
         + rootExtra;
}

// Inflation unfolds the gum; strain is a delayed response to the applied stretch.
float surface(float3 p, float inflation, float strain, float variation = 0.0, float sway = 0.0) {
    float radius = mix(0.29, 1.12, inflation);
    float3 radii = gumRadii(inflation);
    float3 q = gumCoordinates(p, inflation, strain, variation, sway) * radii;
    float body = ellipsoid(q, radii);
    float3 direction = normalize(q + float3(0, 0.0001, 0));
    // The free shoulder unfolds before the retained folds near the attachment.
    float localExtension = strain * mix(0.72, 1.22, smoothstep(-0.8, 0.6, direction.y));
    float slack = (1.0 - smoothstep(0.02, 0.85, localExtension))
                * (1.0 - 0.55 * smoothstep(0.05, 0.25, inflation));
    float limitLoad = smoothstep(0.65, 1.0, strain);
    float foldRegion = 1.0 - 0.85 * smoothstep(-0.70, -0.20, direction.y);
    float folds = sin(direction.x * 13.0 + direction.y * 4.0)
                * sin(direction.z * 11.0 - direction.y * 5.0) * foldRegion;
    float lower = 1.0 - smoothstep(-0.88, -0.57, direction.y);
    body += radius * (0.012 * slack * folds + 0.014 * lower * slack
                      * sin(direction.x * 24.0 + direction.z * 8.0));
    body += radius * mix(0.018, 0.004, limitLoad) * sin(direction.x * 3.2 + 1.1)
                    * sin(direction.y * 4.0 - direction.z * 2.0);
    // A narrow mouth attachment lets the expanding body emerge as a tapered tip.
    float root = ellipsoid(p - float3(-0.025, -0.88, 0), float3(0.10, 0.075, 0.10));
    // The matching CPU field supplies the torn sheet's exact contact surface.
    return max(smoothUnion(body, root, 0.08), p.z - 1.20);
}

float3 normalAt(float3 p, float inflation, float strain, float variation = 0.0, float sway = 0.0) {
    const float e = 0.001;
    return normalize(float3(
        surface(p + float3(e,0,0), inflation, strain, variation, sway) - surface(p - float3(e,0,0), inflation, strain, variation, sway),
        surface(p + float3(0,e,0), inflation, strain, variation, sway) - surface(p - float3(0,e,0), inflation, strain, variation, sway),
        surface(p + float3(0,0,e), inflation, strain, variation, sway) - surface(p - float3(0,0,e), inflation, strain, variation, sway)
    ));
}

struct MembranePath {
    float3 rear;
    float3 rearNormal;
    float3 cavityRay;
    float frontLength;
    bool reachedRear;
};

MembranePath traceMembrane(float3 p, float3 ray, float3 n, float inflation, float strain,
                           float variation = 0.0, float sway = 0.0) {
    const float indexOfRefraction = 1.47;
    float3 inGum = refract(ray, n, 1.0 / indexOfRefraction);
    float thickness = membraneThickness(p, inflation, strain, variation, sway);
    // On a taut dome the film is thin enough to hold the front sample's
    // thickness across this crossing. Keep the full field for the thick wad,
    // where it changes substantially over the same travel distance.
    float low = 0.0;
    float high = thickness / max(abs(dot(inGum, n)), 0.15) * 2.5 + 0.002;
    bool crossed = false;
    for (int i = 0; i < 10; ++i) {
        float mid = (low + high) * 0.5;
        float3 sample = p + inGum * mid;
        float inner = surface(sample, inflation, strain, variation, sway)
                    + (inflation > 0.8 ? thickness
                                       : membraneThickness(sample, inflation, strain, variation, sway));
        if (inner > 0.0) low = mid;
        else { high = mid; crossed = true; }
    }
    float3 innerPoint = p + inGum * high;
    float3 innerNormal = normalAt(innerPoint, inflation, strain, variation, sway);
    float3 cavity = refract(inGum, innerNormal, indexOfRefraction);
    if (!crossed || dot(cavity, cavity) < 0.1) cavity = ray;
    cavity = normalize(cavity);
    // Trace backwards from beyond the object to hit its actual deformed rear.
    float radius = mix(0.29, 1.12, inflation);
    float reach = 3.5 * radius + 0.35;
    float3 origin = innerPoint + cavity * reach;
    float travel = 0;
    float3 rear = innerPoint;
    bool reachedRear = false;
    for (int i = 0; i < 48; ++i) {
        rear = origin - cavity * travel;
        float d = surface(rear, inflation, strain, variation, sway);
        if (d < 0.00007) { reachedRear = true; break; }
        travel += max(d * 0.70, 0.0003);
        if (travel > reach - 0.002) break;
    }
    if (!reachedRear) rear = p;
    return { rear, normalAt(rear, inflation, strain, variation, sway), cavity,
             crossed ? high : thickness / max(abs(dot(inGum,n)), 0.15), reachedRear };
}

// Analytic studio softboxes, reflected in the actual surface normal.
float3 studio(float3 direction) {
    float key = exp(-pow((direction.x + 0.44) / 0.24, 4.0)
                    -pow((direction.y - 0.54) / 0.40, 4.0));
    float fill = exp(-pow((direction.x - 0.78) / 0.13, 2.0)
                     -pow((direction.y - 0.28) / 0.20, 2.0));
    float overhead = pow(saturate(direction.y), 12.0);
    return float3(1.0,0.93,0.89) * key * 1.4
         + float3(0.74,0.82,1.0) * fill * 0.65 + overhead * 0.13;
}

// A wet dielectric reflection with roughness controlled by membrane extension.
float wetReflection(float3 n, float3 view, float3 light, float roughness) {
    float3 halfVector = normalize(view + light);
    float nv = max(dot(n, view), 0.04);
    float nl = max(dot(n, light), 0.0);
    float nh = saturate(dot(n, halfVector));
    float vh = saturate(dot(view, halfVector));
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denominator = nh * nh * (alpha2 - 1.0) + 1.0;
    float distribution = alpha2 / max(M_PI_F * denominator * denominator, 0.00001);
    float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float masking = nv / (nv * (1.0 - k) + k) * nl / (nl * (1.0 - k) + k);
    float fresnel = 0.035 + 0.965 * pow(1.0 - vh, 5.0);
    return distribution * masking * fresnel / max(4.0 * nv, 0.001);
}

// Lighter powder/rose palette, decoded from sRGB (#F9CAD9 and #F1A9C3).
// This is the material's pigment, not a screen-space color overlay. Lighting,
// optical path length and the moisture layer still determine the visible color.
float3 gumPigment(float3 local) {
    float tone = smoothstep(-0.85, 0.85, dot(local.xy, float2(0.65, -0.76)));
    return mix(float3(0.94731, 0.59062, 0.69387),
               float3(0.87962, 0.39676, 0.54572), 0.12 + tone * 0.30);
}

float3 gumAbsorption() {
    // Art-calibrated rose absorption, shared by the closed dome and torn sheet.
    // Longer paths remain denser; stretching still reduces the actual thickness.
    return float3(22.0, 68.0, 49.0);
}

// Translate the camera image in screen space, preserving the existing material view.
float2 gumFraming(float aspect, float inflation, float variation) {
    float portrait = 1.0 - smoothstep(0.65, 0.90, aspect);
    float base = max(1.7, 1.35 / max(aspect, 0.1));
    // Approach until the dome meets the sides. Then hold its projected width
    // inside the frame while its height continues growing toward the top.
    float sideContact = smoothstep(0.65, 0.78, inflation);
    float2 bias = shapeBias(variation);
    float radius = mix(0.29, 1.12, inflation);
    float halfSpan = radius * (1.13 - 0.10 * bias.y + 0.02 * abs(bias.x));
    float horizontal = max(base * (1.0 - 0.25 * portrait * sideContact),
                           halfSpan / (max(aspect, 0.1) * 0.985));
    float vertical = base * (1.0 - 0.64 * portrait * smoothstep(0.65, 0.95, inflation));
    return float2(horizontal, vertical);
}

float gumHorizontalCentre(float inflation, float variation, float sway) {
    float radius = mix(0.29, 1.12, inflation);
    return radius * (0.09 + 0.04 * shapeBias(variation).x) + sway * 0.5;
}

float bottomShift(float framing) {
    // Keep the mouth attachment below the lower display edge throughout growth.
    return 1.03 - 1.0 / framing;
}

float emergenceShift(float inflation) {
    // The small lobe begins below the display edge and grows into view. This
    // offset is gone before the glass-contact and connected tear stages.
    return 0.11 * (1.0 - smoothstep(0.015, 0.35, inflation));
}

float4 shadeGum(Raster in, constant Parameters &u, float2 motion) {
    float2 uv = (in.uv - 0.5) * 2.0;
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    uv.x *= aspect;
    float3 origin = float3(0, 0.12, 4.8);
    float2 framing = gumFraming(aspect, u.inflation, motion.x);
    uv.x += gumHorizontalCentre(u.inflation, motion.x, motion.y) / framing.x;
    uv.y += bottomShift(framing.y) + emergenceShift(u.inflation);
    float3 ray = normalize(float3(uv * framing, -4.8));
    // Linear equivalent of SwiftUI's sRGB #F2F2F2. The render target encodes sRGB.
    float3 background = float3(0.887923);
    float distance = 0;
    float3 p = origin;
    bool hit = false;
    for (int i = 0; i < 80; ++i) {
        p = origin + distance * ray;
        float step = surface(p, u.inflation, u.strain, motion.x, motion.y);
        if (step < 0.00007) { hit = true; break; }
        distance += max(step * 0.8, 0.0003);
        if (distance > 7.0) break;
    }
    if (!hit) return float4(background, 1);

    float3 geometricNormal = normalAt(p, u.inflation, u.strain, motion.x, motion.y);
    float3 n = geometricNormal;
    float3 local = gumCoordinates(p, u.inflation, u.strain, motion.x, motion.y);
    float stretched = smoothstep(0.15, 0.95, u.strain);
    float localThickness = membraneThickness(p, u.inflation, u.strain, motion.x, motion.y);
    float film = stretched * (1.0 - smoothstep(0.0015, 0.010, localThickness));
    // Fine material relief alters reflections. Its amplitude falls as the film
    // stretches; it is anchored to the gum rather than animated screen noise.
    float3 frequency = float3(32, 17, 25);
    float relief = tissueNoise(local * frequency);
    const float e = 0.008;
    float3 reliefGradient = float3(
        tissueNoise((local + float3(e,0,0)) * frequency),
        tissueNoise((local + float3(0,e,0)) * frequency),
        tissueNoise((local + float3(0,0,e)) * frequency)
    ) - relief;
    reliefGradient /= e;
    reliefGradient -= n * dot(reliefGradient, n);
    n = normalize(n - reliefGradient * mix(0.0022, 0.00035, film));
    // Breath/input-driven tension ripples affect the wet reflection, not the
    // whole silhouette. They decay after release; there is no perpetual wobble.
    float load = smoothstep(0.72, 1.0, u.strain);
    float ripple = sin(local.x * 23.0 + local.y * 11.0 - u.phase * 18.0)
                 * sin(local.y * 17.0 - local.x * 8.0 + u.phase * 11.0);
    float3 tangent = cross(n, float3(0,1,0));
    tangent *= rsqrt(max(dot(tangent,tangent), 0.000001));
    n = normalize(n + tangent * ripple * u.agitation * load * film * 0.006);
    float3 view = -ray;
    float facing = max(dot(n, view), 0.025);
    float3 light = normalize(float3(-1.0, 0.45, 0.55));
    float diffuse = saturate((dot(n, light) + 0.38) / 1.38);
    MembranePath path = traceMembrane(p, ray, geometricNormal, u.inflation, u.strain, motion.x, motion.y);
    float rearThickness = membraneThickness(path.rear, u.inflation, u.strain, motion.x, motion.y);
    float opticalDepth = path.frontLength;
    if (path.reachedRear) {
        float3 rearInGum = refract(path.cavityRay, -path.rearNormal, 1.0 / 1.47);
        opticalDepth += rearThickness / max(abs(dot(path.rearNormal, rearInGum)), 0.12);
    }
    float3 transmission = exp(-gumAbsorption() * opticalDepth);
    float3 pigment = gumPigment(local);
    // Broad studio bounce lifts the underside while following its real normals.
    // Retain thickness and fold shading instead of painting a flat pink bottom.
    float bounce = saturate((dot(n, normalize(float3(0.0, -0.65, 0.76))) + 0.5) / 1.5);
    float3 scattering = pigment * (0.07 + diffuse * 0.70 + bounce * 0.13);
    // Rear illumination contributes scattered light according to optical depth.
    // A thinning cavity also reveals more of the studio background through it.
    float backlight = saturate(dot(path.rearNormal, normalize(float3(-0.9,0.30,-0.45))));
    float backScatter = (1.0 - exp(-opticalDepth * 23.0)) * backlight * 0.18;
    float3 color = scattering * (1.0 - transmission) + background * transmission
                 + pigment * backScatter;
    float fresnel = 0.035 + 0.965 * pow(1.0 - facing, 5.0);
    float3 reflected = studio(reflect(ray, n));
    float roughness = mix(0.44, 0.16, stretched) - film * 0.045
                    + (relief - 0.5) * mix(0.055, 0.015, film);
    color += reflected * (mix(0.02, 0.075, stretched) + fresnel * 0.32);
    color += float3(1.0,0.90,0.87) * wetReflection(n, view, light, roughness) * 1.35;
    float3 fillLight = normalize(float3(0.85, 0.25, 0.55));
    color += float3(1.0,0.94,0.91)
           * wetReflection(n, view, fillLight, max(roughness, 0.24)) * 0.32;
    // Sparse tiny inclusions/wet pits, stable in material space. Keep them
    // subservient to the membrane; no glitter, repeating dots or iridescence.
    float2 poreUV = local.xy * 48.0 + local.z * float2(2.3, 1.7);
    float2 poreCell = floor(poreUV);
    float seed = hash31(float3(poreCell, 3.1));
    float2 centre = float2(hash31(float3(poreCell, 6.7)), hash31(float3(poreCell, 9.2))) * 0.6 + 0.2;
    float2 pore = fract(poreUV) - centre;
    float poreRadius = mix(0.05, 0.15, hash31(float3(poreCell, 12.8)));
    float poreDistance = length(pore) / poreRadius;
    float inclusion = exp(-poreDistance * poreDistance * 2.0) * step(0.973, seed);
    color += float3(1.0,0.85,0.93) * inclusion * stretched * (1.0 - film * 0.65) * (0.03 + diffuse * 0.22);
    float grain = tissueNoise(local * float3(130, 50, 90));
    color *= 1.0 + (grain - 0.5) * mix(0.035, 0.008, stretched);
    // Compress only light above the studio background. Compressing transmitted
    // background itself made a nearly clear, stretched film look grey and opaque.
    float3 excess = max(color - background, 0.0);
    float3 headroom = 1.0 - background;
    color = min(color, background) + headroom * (1.0 - exp(-excess / headroom));
    // A new bubble emerges from the mouth instead of displaying a resting wad.
    return float4(mix(background, color, smoothstep(0.005, 0.08, u.inflation)), 1);
}

// At rupture the same sampled surface is drawn as one deformable sheet.
// No six-site screen mask and no delayed hard removal of an unrelated dome.
fragment float4 gumFragment(Raster in [[stage_in]], constant Parameters &u [[buffer(0)]],
                            constant float2 &motion [[buffer(2)]]) {
    return u.burstEvent > 0.5 ? float4(float3(0.887923), 1) : shadeGum(in, u, motion);
}

// Rupture when visible film crosses three-fifths of the display height.
// Side proximity alone does not trigger it.
kernel void gumVisibleBurstLine(device atomic_uint *hit [[buffer(0)]],
                                constant Parameters &u [[buffer(1)]],
                                constant float2 &motion [[buffer(2)]],
                                uint id [[thread_position_in_grid]]) {
    if (id >= 256) return;
    float x = (float(id) + 0.5) / 256.0;
    float y = 0.60;
    Raster sample = { float4(0), float2(x, y) };
    float3 color = shadeGum(sample, u, motion).rgb;
    if (color.r - color.g > 0.035) {
        atomic_store_explicit(hit, 1u, memory_order_relaxed);
    }
}

struct MembraneVertex {
    float4 position;
    float4 normalThickness;
    float4 material;
    float4 source;
};
struct MembraneRaster {
    float4 position [[position]];
    float3 normal;
    float thickness;
    float4 material;
    float height;
    float reveal;
    float3 world;
    float3 source;
    float restThickness;
    float4 intact;
};

vertex MembraneRaster membraneVertex(uint id [[vertex_id]],
    const device MembraneVertex *vertices [[buffer(0)]], constant Parameters &u [[buffer(1)]],
    constant float2 &motion [[buffer(2)]]) {
    MembraneVertex v = vertices[id];
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    // Exactly the intact dome camera, including its portrait framing and origin.
    float2 framing = gumFraming(aspect, u.inflation, motion.x);
    float cameraX = gumHorizontalCentre(u.inflation, motion.x, motion.y);
    float w = 1.0 - v.position.z / 4.8;
    float4 intact = float4(float3(0.887923), 1);
    if (u.burstTime < 0.045) {
        float sourceW = 1.0 - v.source.z / 4.8;
        float2 originalUV = float2(v.source.x / aspect, v.source.y - 0.12) / (framing * sourceW);
        originalUV.x -= cameraX / (aspect * framing.x);
        originalUV.y -= bottomShift(framing.y);
        Raster sourceRaster = { float4(0), originalUV * 0.5 + 0.5 };
        intact = shadeGum(sourceRaster, u, motion);
    }
    return { float4((v.position.x - cameraX * w) / (aspect * framing.x),
                    (v.position.y - 0.12) / framing.y - bottomShift(framing.y) * w, 0, w),
             v.normalThickness.xyz, v.normalThickness.w, v.material,
             max(1.20 - v.position.z, 0.0), v.position.w, v.position.xyz, v.source.xyz, v.source.w, intact };
}

fragment float4 membraneFragment(MembraneRaster in [[stage_in]], constant Parameters &u [[buffer(0)]],
                                 constant float2 &motion [[buffer(2)]]) {
    float contact = saturate(in.material.w);
    float3 n = normalize(in.normal);
    if (n.z < 0.0) n = -n;
    n = normalize(mix(n, float3(0, 0, 1), contact * 0.15));
    // Subtle gathered folds keep compressed film from reading as flat cutouts.
    float2 fold = float2(sin(in.material.x * 19.0 + in.material.z * 3.0),
                         sin(in.material.y * 17.0 - in.material.z * 2.0));
    n = normalize(n + float3(fold * contact * 0.14, 0));
    // Compressed material has relief both at a free lip and on the glass.
    // Its actual thickness gradient bends the reflection across gathered folds.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 framing = gumFraming(aspect, u.inflation, motion.x);
    float surfaceHeight = 0.015 * (1.0 - exp(-in.thickness / 0.015));
    float2 slope = float2(dfdx(surfaceHeight), -dfdy(surfaceHeight))
                 * u.resolution.y / (2.0 * framing);
    float compression = smoothstep(1.4, 4.0, in.thickness / max(in.restThickness, 1e-5));
    float reliefWeight = max(contact, 0.35 * compression * (1.0 - contact));
    n = normalize(n + float3(clamp(-slope * 0.25, -0.18, 0.18) * reliefWeight, 0));
    float3 view = normalize(float3(0, 0.12, 4.8) - in.world);
    float3 light = normalize(float3(-0.65, 0.8, 1.0));
    float patch = tissueNoise(in.source * float3(7, 4, 6) + 3.1);
    float thickness = in.thickness / max(abs(dot(n, view)), 0.18);
    thickness *= mix(0.85, 1.15, patch);
    float3 transmission = exp(-gumAbsorption() * thickness);
    float alpha = max(1.0 - transmission.g, 0.015);
    // A soft, wrapped pigment lobe under a separate thin moisture coating.
    // This keeps the body waxy instead of treating the whole sheet as glossy plastic.
    float diffuse = saturate((dot(n, light) + 0.6) / 1.6);
    float3 pigment = gumPigment(gumCoordinates(in.source, u.inflation, u.strain, motion.x, motion.y));
    // Scatter only the energy removed in each wavelength. Scaling red scatter
    // by green opacity made overlapping film look fluorescent/cellophane-like.
    float3 scattered = pigment * (1.0 - transmission) * (0.30 + diffuse * 0.70);
    float3 tint = float3(0.887923) * (transmission - (1.0 - alpha));
    float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, view)), 5.0);
    float3 reflection = studio(reflect(-view, n)) * fresnel * 0.10;
    reflection += float3(1, 0.94, 0.91) * wetReflection(n, view, light, 0.50) * 0.07;
    // Irregular local wet patches catch small highlights only after contact.
    // No continuous bright rim or animated glitter across the film.
    float moisture = smoothstep(0.58, 0.77,
        tissueNoise(float3(in.material.xy * float2(5, 9), in.material.z * 2)));
    float coating = contact * exp(-in.height * 18.0);
    float2 wetCentre = float2(0.48, 0.40)
        + float2(0.20, 0.16) * sin(float2(in.material.z * 7.1, in.material.z * 11.3));
    float2 wetUV = (in.material.xy - wetCentre) * float2(3, 5);
    float capillary = exp(-dot(wetUV, wetUV) * 2.0);
    float3 wetNormal = normalize(n + float3(wetUV * capillary * 0.65, capillary * 0.08));
    reflection += float3(1, 0.97, 0.95) * wetReflection(wetNormal, view, light, 0.24)
                * moisture * coating * 0.22;
    float4 film = float4(max(tint + scattered + reflection, 0.0), alpha);
    // Carry intact optical appearance through the start of the geometric tear.
    // As the cavity opens, actual folded layers replace the closed-cavity trace.
    // This interpolates optical state on persistent material, never two shapes.
    // Release closed-cavity shading before the slit widens; otherwise the
    // opaque rear-wall handoff visually fills the opening and hides its bridges.
    float released = smoothstep(0.0, 0.045, u.burstTime);
    if (released < 1.0) {
        film = mix(in.intact, film, released);
    }
    return film * in.reveal;
}
