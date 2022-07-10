Shader "Skybox/AtomsphereScattering_no_lut"
{
    Properties
    {
        r_inner("r_inner", float) = 6.0
        r_width("R_Width", float) = 3.0
        slope_ray("slope_ray", float) = 0.2
        slope_mie("slope_mie", float) = 0.1   
        ray_ColorAdjust("ray_ColorAdjust", Color) = (5.0, 15.0, 5.0, 0)
        mie_ColorAdjust("mie_ColorAdjust", Color) = (20.0, 20.0, 20.0, 0)
        mie_Adjust("mie_Adjust", float) = 1.2
    }
    SubShader
    {
        Pass
        {
                Cull off
                Blend One OneMinusSrcColor

                HLSLPROGRAM
                #pragma vertex vert
                #pragma fragment frag

                #include "UnityCG.cginc"
              
                struct appdata
                {
                        float4 vertex : POSITION;
                        float2 uv : TEXCOORD0;
                };

                struct v2f
                {
                        float2 uv : TEXCOORD0;
                        float4 vertex : SV_POSITION;
                        float4 campos : TEXCOORD1;
                };

                float r_inner;
                float r_width;
                float R;
                float3 ObjectPosition;

                //色彩调节
                float3 ray_ColorAdjust;
                float3 mie_ColorAdjust;
                //mie强度调节
                float mie_Adjust;

                //调节大气衰减值
                float slope_ray;
                float slope_mie;

                #define PI  3.1415926536
                #define OUT_SCATTER_COUNT 6
                #define IN_SCATTER_COUNT  100

                v2f vert (appdata v) {
                        v2f o;
                        o.vertex = UnityObjectToClipPos(v.vertex);
                        o.campos = mul(v.vertex, unity_ObjectToWorld);
                        o.uv = v.uv;
                        return o;
                }


                //Mie H-G相位函数
                //                1 - g^2
                //F = ----------------------------------
                //     4pi * ( 1 + g^2 - 2g * cos)^(3/2)
                //这个函数非常简单易用， 他可以很好地体现mie散射的向前峰值的主要特征， 但是不能正确模拟向后散射，为了克服这个缺陷，就用了 双 H-G相位函数


                // 改编自 Henyey-Greenstein 函数， 双 Henyey-Greenstein相位函数 的 单参数版 (原双相位函数拥有3个参数, 要确定3个参数非常复杂)
                // g : ( -0.75, -0.999 )
                //      3 * ( 1 - g^2 )               1 + cos^2
                // F = ----------------- * -------------------------------
                //      <4pi> * 2 * ( 2 + g^2 )     ( 1 + g^2 - 2 * g * cos )^(3/2)
                  
                // 4 * PI  

                #define MA_VERSION_0

                float Equation_mie(float g, float cos, float cosSquare) {

                        float gg = g * g;

                #if defined(MA_VERSION_2)

                        //H-G相位函数
                        float M = (1.0 - gg) / (4.0 * PI * ( 1 + gg - 2 * g * cos));
                        M = pow(M, 1.5);
                        return M; 

                #elif defined(MA_VERSION_1)

                        //双相位函数 某个老外的版本
                        float FMA = (1.0 - gg) * (1.0 + cosSquare);
                        float FMB_L = 2.0 + gg;
                        float FMB_R = 1.0 + gg - 2.0 * g * cos;
                        FMB_R *= sqrt(FMB_R) * FMB_L;
                        return (3.0 / 8.0 / PI) * FMA / FMB_R; 
                    
                #else
                        //双相位函数 标准实现
                        float MA = (1.0 - gg) * (1 + cosSquare);
                        float MB_L = 2.0 + gg;
                        float MB_R = 1.0 + gg - 2.0 * g * cos;
                        MB_R = pow(MB_R, 1.5) * MB_L;
                        return (3.0  / 8.0 / PI ) * (MA / MB_R);
                        
                #endif
                }

                // Ray
                // g : 0
                // F = 3/16PI * ( 1 + c^2 )
                float Equation_ray(float cc) {
                        return (0.1875 / PI) * (1.0 + cc);
                }

                float Density(float3 p, float ph) {
                        return exp(-max(length(p) - r_inner, 0.0) / ph);
                }

            
                float OutScatter(float3 pSource, float3 pTarget, float ph) {

                        float sum = 0.0;

                        float3 step = (pTarget - pSource) / float(OUT_SCATTER_COUNT);
                        float3 pCurrent = pSource;
 
                        for (int i = 0; i < OUT_SCATTER_COUNT; i++) {
                                sum += Density(pCurrent, ph);
                                pCurrent += step;
                        }

                        sum *= length(step);
                        return sum; 
                }

                float2 RaySphereIntersection(float3 rayOrigin, float3 rayDir, float3 sphereCenter, float sphereRadius) {

                        rayOrigin -= sphereCenter;

                        float a = dot(rayDir, rayDir);
                        float b = 2.0 * dot(rayOrigin, rayDir);
                        float c = dot(rayOrigin, rayOrigin) - (sphereRadius * sphereRadius);

                        float d = b * b - 4 * a * c;

                        if (d < 0){
                                return -1;
                        }else{
                                d = sqrt(d);
                                return float2(-b - d, -b + d) / (2 * a);
                        }
                }

                float3 InnerScatter(float3 eyePos, float3 viewDir, float2 e, float3 lightDir) {
                    
                        float3 sum_ray = float3(0.0, 0.0, 0.0);
                        float3 sum_mie = float3(0.0, 0.0, 0.0);

                        float n_ray0 = 0.0;
                        float n_mie0 = 0.0;

                        float stepLen = (e.y - e.x) / float(IN_SCATTER_COUNT);
                        float3 step = viewDir * stepLen;
                        float3 currentPoint = eyePos + viewDir * (e.x);

                        for (int i = 0; i < IN_SCATTER_COUNT; i++, currentPoint += step) {

                                float currentStep_rayValue = Density(currentPoint, slope_ray) * stepLen;
                                float currentStep_mieValue = Density(currentPoint, slope_mie) * stepLen;
                                
                                float2 pIntersection = RaySphereIntersection(currentPoint, lightDir, ObjectPosition, R);
                                float3 point_PlanetEdgeinLightDirfromCurrentPoint = currentPoint + lightDir * pIntersection.y; // 当前点  沿着光线方向 与  大气层最边缘 的交点
                                
                                //内散射
                                n_ray0 += currentStep_rayValue; 
                                n_mie0 += currentStep_mieValue;

                                //外散射
                                float n_ray1 = OutScatter(currentPoint, point_PlanetEdgeinLightDirfromCurrentPoint, slope_ray);
                                float n_mie1 = OutScatter(currentPoint, point_PlanetEdgeinLightDirfromCurrentPoint, slope_mie);

                                float3 attribute = exp(-(n_ray0 + n_ray1)  * ray_ColorAdjust  - ((n_mie0 + n_mie1) * mie_ColorAdjust)  * mie_Adjust);

                                sum_ray += currentStep_rayValue * attribute;
                                sum_mie += currentStep_mieValue * attribute;
                        }

                        float cos = dot(-lightDir, viewDir); //相位函数描述了"角度"向相机方向散射多少光
                        float cosSquare = cos * cos;
                    
                        float3 res = sum_ray * ray_ColorAdjust * Equation_ray(cosSquare) + sum_mie * mie_ColorAdjust * Equation_mie(-0.78, cos, cosSquare);
                        return res * 10;
                }

                float4 frag(v2f i) : SV_Target {

                        R = r_inner + r_width;
                        
                        ObjectPosition = mul(unity_ObjectToWorld, float4(0, 0, 0, 1)).xyz;

                        float3 lightDir = normalize(_WorldSpaceLightPos0);
                
                        float3 viewDir = normalize(i.campos - _WorldSpaceCameraPos);
                        float3 eyePos = _WorldSpaceCameraPos;


                        float2 pIntersection = RaySphereIntersection(eyePos, viewDir, ObjectPosition, R);
     
                        if (pIntersection.y <= 0 && pIntersection.x <= 0) {
                                return float4(0.0, 0.0, 0.0, 0.0);
                        }

                        pIntersection.y = max(pIntersection.y, 0);
                        pIntersection.x = max(pIntersection.x, 0);

                        float3 res = pow(InnerScatter(eyePos, viewDir, pIntersection, lightDir), (1.0 / 2.2));
                        return float4(res, 1.0);
                }
                ENDHLSL
        }
    }
}
