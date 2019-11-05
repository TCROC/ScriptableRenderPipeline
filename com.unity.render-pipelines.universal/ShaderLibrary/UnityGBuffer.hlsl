#ifndef UNIVERSAL_GBUFFERUTIL_INCLUDED
#define UNIVERSAL_GBUFFERUTIL_INCLUDED

// inspired from [builtin_shaders]/CGIncludes/UnityGBuffer.cginc

#define kLightingInvalid  -1  // No dynamic lighting: can aliase any other material type as they are skipped using stencil
#define kLightingSimpleLit 2  // Simple lit shader
// clearcoat 3
// backscatter 4 
// skin 5

struct FragmentOutput
{
    half4 GBuffer0 : SV_Target0; // maps to GBufferPass.m_GBufferAttachments[0] on C# side
    half4 GBuffer1 : SV_Target1; // maps to GBufferPass.m_GBufferAttachments[1] on C# side
    half4 GBuffer2 : SV_Target2; // maps to GBufferPass.m_GBufferAttachments[2] on C# side
    half4 GBuffer3 : SV_Target3; // maps to DeferredPass.m_CameraColorAttachment on C# side
};

#define PACK_NORMALS_OCT 0  // TODO Debug OCT packing

// This will encode SurfaceData into GBuffer
FragmentOutput SurfaceDataAndMainLightingToGbuffer(SurfaceData surfaceData, InputData inputData, half3 globalIllumination, int lightingMode)
{
#if PACK_NORMALS_OCT
    half2 octNormalWS = PackNormalOctQuadEncode(inputData.normalWS); // values between [-1, +1]
    half2 remappedOctNormalWS = saturate(octNormalWS * 0.5 + 0.5);   // values between [ 0,  1]
    half3 packedNormalWS = PackFloat2To888(remappedOctNormalWS);
#else
    half3 packedNormalWS = inputData.normalWS * 0.5 + 0.5;   // values between [ 0,  1]
#endif

    half metallic = surfaceData.metallic;
    half packedSmoothness = surfaceData.smoothness;

    if (lightingMode == kLightingSimpleLit)
        packedSmoothness = (0.1 * log2(packedSmoothness) - 1); // See SimpleLitInput.hlsl, SampleSpecularSmoothness(): TODO pass in the original smoothness value

    FragmentOutput output;
    output.GBuffer0 = half4(surfaceData.albedo.rgb, surfaceData.occlusion);     // albedo          albedo          albedo          occlusion    (sRGB rendertarget)
    output.GBuffer1 = half4(surfaceData.specular.rgb, metallic);                // specular        specular        specular        metallic     (sRGB rendertarget)
    output.GBuffer2 = half4(packedNormalWS, packedSmoothness);                  // encoded-normal  encoded-normal  encoded-normal  packed-smoothness
    output.GBuffer3 = half4(surfaceData.emission.rgb + globalIllumination, 0);  // emission+GI     emission+GI     emission+GI     [unused]     (lighting buffer)

    return output;
}

// This decodes the Gbuffer into a SurfaceData struct
SurfaceData SurfaceDataFromGbuffer(half4 gbuffer0, half4 gbuffer1, half4 gbuffer2, int lightingMode)
{
    SurfaceData surfaceData;

    surfaceData.albedo = gbuffer0.rgb;
    surfaceData.occlusion = gbuffer0.a;
    surfaceData.specular = gbuffer1.rgb;

    half metallic = gbuffer1.a;
    half smoothness = gbuffer2.a;

    if (lightingMode == kLightingSimpleLit)
        smoothness = exp2(10.0 * smoothness + 1);

    surfaceData.metallic = metallic;
    surfaceData.alpha = 1.0; // gbuffer only contains opaque materials
    surfaceData.smoothness = smoothness;

    surfaceData.emission = (half3)0; // Note: this is not made available at lighting pass in this renderer - emission contribution is included (with GI) in the value GBuffer3.rgb, that is used as a renderTarget during lighting
    surfaceData.normalTS = (half3)0; // Note: does this normalTS member need to be in SurfaceData? It looks like an intermediate value

    return surfaceData;
}

// This will encode SurfaceData into GBuffer
FragmentOutput BRDFDataAndMainLightingToGbuffer(BRDFData brdfData, InputData inputData, half occlusion, half smoothness, half3 emission, half3 globalIllumination)
{
#if PACK_NORMALS_OCT
    half2 octNormalWS = PackNormalOctQuadEncode(inputData.normalWS); // values between [-1, +1]
    half2 remappedOctNormalWS = saturate(octNormalWS * 0.5 + 0.5);   // values between [ 0,  1]
    half3 packedNormalWS = PackFloat2To888(remappedOctNormalWS);
#else
    half3 packedNormalWS = inputData.normalWS * 0.5 + 0.5;   // values between [ 0,  1]
#endif

    FragmentOutput output;
    output.GBuffer0 = half4(brdfData.diffuse.rgb, occlusion);              // diffuse         diffuse         diffuse         occlusion    (sRGB rendertarget)
    output.GBuffer1 = half4(brdfData.specular.rgb, brdfData.reflectivity); // specular        specular        specular        metallic     (sRGB rendertarget)
    output.GBuffer2 = half4(packedNormalWS, smoothness);                   // encoded-normal  encoded-normal  encoded-normal  smoothness
    output.GBuffer3 = half4(emission.rgb + globalIllumination, 0);         // emission+GI     emission+GI     emission+GI     [unused]     (lighting buffer)

    return output;
}

// This decodes the Gbuffer into a SurfaceData struct
BRDFData BRDFDataFromGbuffer(half4 gbuffer0, half4 gbuffer1, half4 gbuffer2)
{
    half3 diffuse = gbuffer0.rgb;
    half3 specular = gbuffer1.rgb;
    half reflectivity = gbuffer1.a;
    half oneMinusReflectivity = 1.0h - reflectivity;
    half smoothness = gbuffer2.a;

    BRDFData brdfData;
    InitializeBRDFDataDirect(gbuffer0.rgb, gbuffer1.rgb, reflectivity, oneMinusReflectivity, smoothness, 1.0, brdfData);

    return brdfData;
}

InputData InputDataFromGbufferAndWorldPosition(half4 gbuffer2, float3 wsPos)
{
    InputData inputData;

    inputData.positionWS = wsPos;

    half3 packedNormalWS = gbuffer2.xyz;
#if PACK_NORMALS_OCT
    half2 remappedOctNormalWS = Unpack888ToFloat2(packedNormalWS);  // values between [ 0,  1]
    half2 octNormalWS = normalize(remappedOctNormalWS.xy * 2 - 1);  // values between [-1, +1]
    inputData.normalWS = UnpackNormalOctQuadEncode(octNormalWS);
#else
    inputData.normalWS = packedNormalWS * 2 - 1;  // values between [-1, +1]
#endif

    inputData.viewDirectionWS = normalize(GetCameraPositionWS() - wsPos.xyz);

    // TODO: pass this info?
    inputData.shadowCoord     = (float4)0;
    inputData.fogCoord        = (half  )0;
    inputData.vertexLighting  = (half3 )0;

    inputData.bakedGI = (half3)0; // Note: this is not made available at lighting pass in this renderer - bakedGI contribution is included (with emission) in the value GBuffer3.rgb, that is used as a renderTarget during lighting

    return inputData;
}

#endif // UNIVERSAL_GBUFFERUTIL_INCLUDED
