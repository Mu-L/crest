﻿// Crest Ocean System

// This file is subject to the MIT License as seen in the root of this folder structure (LICENSE)

// Adds Gestner waves to world

Shader "Hidden/Crest/Inputs/Animated Waves/Gerstner Global"
{
	SubShader
	{
		// Additive blend everywhere
		Blend One One
		ZWrite Off
		ZTest Always
		Cull Off

		Pass
		{
			CGPROGRAM
			#pragma vertex Vert
			#pragma fragment Frag
			//#pragma enable_d3d11_debug_symbols

			#include "UnityCG.cginc"

			#include "../../OceanGlobals.hlsl"
			#include "../../OceanInputsDriven.hlsl"
			#include "../../OceanHelpersNew.hlsl"
			#include "../../FullScreenTriangle.hlsl"

			Texture2DArray _WaveBuffer;
			Texture2D _PaintedWavesData;

			CBUFFER_START(CrestPerOceanInput)
			int _WaveBufferSliceIndex;
			float _Weight;
			float _AverageWavelength;
			float _AttenuationInShallows;
			float2 _AxisX;
			float _RespectShallowWaterAttenuation;
			half _MaximumAttenuationDepth;
			float _PaintedWavesSize;
			float2 _PaintedWavesPosition;
			CBUFFER_END

			struct Attributes
			{
				uint VertexID : SV_VertexID;
			};

			struct Varyings
			{
				float4 positionCS : SV_POSITION;
				float4 uv_uvWaves : TEXCOORD0;
				float2 worldPosXZ : TEXCOORD1;
				float2 worldPosScaled : TEXCOORD2;
			};

			Varyings Vert(Attributes input)
			{
				Varyings o;
				o.positionCS = GetFullScreenTriangleVertexPosition(input.VertexID);

				o.uv_uvWaves.xy = GetFullScreenTriangleTexCoord(input.VertexID);

				o.worldPosXZ = UVToWorld( o.uv_uvWaves.xy, _LD_SliceIndex, _CrestCascadeData[_LD_SliceIndex] );
				const float waveBufferSize = 0.5f * (1 << _WaveBufferSliceIndex);
				o.worldPosScaled = o.worldPosXZ / waveBufferSize;

				// UV coordinate into wave buffer
				float2 wavePos = float2( dot(o.worldPosXZ, _AxisX), dot(o.worldPosXZ, float2(-_AxisX.y, _AxisX.x)) );
				o.uv_uvWaves.zw = wavePos / waveBufferSize;

				return o;
			}

			half4 Frag( Varyings input ) : SV_Target
			{
				float wt = _Weight;

				// Attenuate if depth is less than half of the average wavelength
				const half2 terrainHeight_seaLevelOffset =
					_LD_TexArray_SeaFloorDepth.SampleLevel(LODData_linear_clamp_sampler, float3(input.uv_uvWaves.xy, _LD_SliceIndex), 0.0).xy;
				const half depth = _OceanCenterPosWorld.y - terrainHeight_seaLevelOffset.x + terrainHeight_seaLevelOffset.y;
				half depth_wt = saturate(2.0 * depth / _AverageWavelength);
				if (_MaximumAttenuationDepth < CREST_OCEAN_DEPTH_BASELINE)
				{
					depth_wt = lerp(depth_wt, 1.0, saturate(depth / _MaximumAttenuationDepth));
				}
				const float attenuationAmount = _AttenuationInShallows * _RespectShallowWaterAttenuation;
				wt *= attenuationAmount * depth_wt + (1.0 - attenuationAmount);




				float4 disp_variance = 0.0;

				if (_PaintedWavesSize > 0.0)
				{
					float2 paintUV = (input.worldPosXZ - _PaintedWavesPosition) / _PaintedWavesSize + 0.5;
					// Check if in bounds
					if (all(saturate(paintUV) == paintUV))
					{
						float2 axis = _PaintedWavesData.Sample(LODData_linear_clamp_sampler, paintUV).xy;
						axis.x += 0.00001;

						// Quantize wave direction and interpolate waves
						float axisHeading = atan2(axis.y, axis.x) + 2.0 * 3.141592654;
						const float dTheta = 0.5 * 0.314159265;
						float angle0 = axisHeading;
						const float rem = fmod(angle0, dTheta);
						angle0 -= rem;
						const float angle1 = angle0 + dTheta;

						float2 axisX0; sincos(angle0, axisX0.y, axisX0.x);
						float2 axisX1; sincos(angle1, axisX1.y, axisX1.x);
						float2 axisZ0; axisZ0.x = -axisX0.y; axisZ0.y = axisX0.x;
						float2 axisZ1; axisZ1.x = -axisX1.y; axisZ1.y = axisX1.x;

						const float2 uv0 = float2(dot(input.worldPosScaled.xy, axisX0), dot(input.worldPosScaled.xy, axisZ0));
						const float2 uv1 = float2(dot(input.worldPosScaled.xy, axisX1), dot(input.worldPosScaled.xy, axisZ1));

						// Sample displacement, rotate into frame
						float4 disp_variance0 = _WaveBuffer.SampleLevel(sampler_Crest_linear_repeat, float3(uv0, _WaveBufferSliceIndex), 0);
						float4 disp_variance1 = _WaveBuffer.SampleLevel(sampler_Crest_linear_repeat, float3(uv1, _WaveBufferSliceIndex), 0);
						disp_variance0.xz = disp_variance0.x * axisX0 + disp_variance0.z * axisZ0;
						disp_variance1.xz = disp_variance1.x * axisX1 + disp_variance1.z * axisZ1;
						const float alpha = rem / dTheta;
						disp_variance = length(axis) * lerp(disp_variance0, disp_variance1, alpha);
					}
				}
				else
				{
					// Sample displacement, rotate into frame
					disp_variance = _WaveBuffer.SampleLevel(sampler_Crest_linear_repeat, float3(input.uv_uvWaves.zw, _WaveBufferSliceIndex), 0);
					disp_variance.xz = disp_variance.x * _AxisX + disp_variance.z * float2(-_AxisX.y, _AxisX.x);
				}





				// The large waves are added to the last two lods. Don't write cumulative variances for these - cumulative variance
				// for the last fitting wave cascade captures everything needed.
				const float minWavelength = _AverageWavelength / 1.5;
				if( minWavelength > _CrestCascadeData[_LD_SliceIndex]._maxWavelength )
				{
					disp_variance.w = 0.0;
				}

				return wt * disp_variance;
			}
			ENDCG
		}
	}
}
