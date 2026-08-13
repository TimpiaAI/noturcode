#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

[[ stitchable ]] half4 fluidMarble(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    half4 primary,
    half4 secondary
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float2 centered = uv - 0.5;

    float slow = time * 0.72;
    float warpX = sin((uv.y * 5.1) + slow) * 0.17
        + sin((uv.x + uv.y) * 7.3 - slow * 0.71) * 0.085;
    float warpY = cos((uv.x * 4.7) - slow * 0.83) * 0.16
        + sin((uv.x - uv.y) * 6.2 + slow * 0.54) * 0.075;
    float2 fluidUV = uv + float2(warpX, warpY);

    float flow = sin(fluidUV.x * 5.8 - fluidUV.y * 4.6 + slow * 0.74);
    flow += cos((fluidUV.x + fluidUV.y) * 4.2 - slow * 0.51);
    flow = smoothstep(-0.72, 0.72, flow);

    half3 darkPrimary = primary.rgb * half3(0.72, 0.76, 0.84);
    half3 brightSecondary = min(secondary.rgb * half3(1.14, 1.10, 1.08), half3(1.0));
    half3 color = mix(darkPrimary, brightSecondary, half(flow));
    float ribbon = pow(1.0 - abs(sin((fluidUV.x * 6.4) + (fluidUV.y * 4.7) - slow)), 7.0);
    color = mix(color, half3(1.0), half(ribbon * 0.20));
    float2 highlightCenter = float2(0.30, 0.23)
        + float2(sin(slow * 0.43), cos(slow * 0.37)) * 0.075;
    float pearl = exp(-dot(uv - highlightCenter, uv - highlightCenter) * 38.0);
    float depth = smoothstep(0.72, 0.08, length(centered));
    color = mix(color * half(0.82 + depth * 0.24), half3(1.0), half(pearl * 0.52));

    return half4(color * currentColor.a, currentColor.a);
}
