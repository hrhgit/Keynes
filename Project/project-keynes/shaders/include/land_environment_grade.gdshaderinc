// ─── LAND 2.4：统一环境调色 ────────────────────────────────────────────
// 温度、湿度、生态与活力先求权重，再一次性混合色相。干热、湿润和衰退
// 因而可以拉开战略辨识度，同时不会因连续乘色丢失饱和度与明度。
SurfaceParams apply_environment_color_grade(SurfaceParams surface, LandModInputs i) {
	if (i.dyn_valid <= 0.5) {
		return surface;
	}

	float temp_cold_n = 1.0 - smoothstep(0.32, 0.58, i.current_temp);
	float snow_cold_n = smoothstep(0.04, 0.42, i.dyn_snow * i.dyn_valid) * 0.88;
	float cold_n = max(temp_cold_n, snow_cold_n);
	float cold_w = cold_n * temperature_visual_strength;
	float hot_n = smoothstep(0.55, 0.78, i.current_temp);
	float hot_w = hot_n * temperature_visual_strength;
	float dry_n = 1.0 - smoothstep(0.22, 0.52, i.moist);
	float dry_w = dry_n * moisture_visual_strength;
	float wet_n = smoothstep(0.55, 0.98, i.moist);
	float wet_w = wet_n * moisture_visual_strength;

	float healthy_w = 0.0;
	float decline_w = 0.0;
	float dieback_w = 0.0;
	float foliage_w = 0.0;
	float stress_w = 0.0;
	if (i.veg != V_NONE) {
		float vitality = clamp(i.dyn_vitality, 0.0, 1.0);
		healthy_w = smoothstep(0.60, 0.90, vitality) * vitality_visual_strength;
		decline_w = (1.0 - smoothstep(0.35, 0.70, vitality)) * vitality_visual_strength;
		dieback_w = (1.0 - smoothstep(0.10, 0.35, vitality)) * vitality_visual_strength;
	}
	// eco_lut 已从主地形移除：叶量/胁迫/物候调制原先与 dyn_vitality 高度重叠，
	// 现统一走 vitality 权重（mobile 路径早已如此）。
	// 活力表示生态状态良好，不等于地表必然翠绿。健康绿必须同时获得水分支持；
	// 荒漠、盐碱地、寒漠和旱生植被始终保留沙黄/赭褐的生态身份。
	bool arid_identity = i.biome == B_DESERT || i.biome == B_SALT_FLAT
			|| i.biome == B_COLD_DESERT || i.veg == V_DESERT_SCRUB
			|| i.veg == V_XERIC_DESERT || i.veg == V_POLAR_DESERT;
	float green_water_support = smoothstep(0.30, 0.62, i.moist)
			* (arid_identity ? 0.0 : 1.0);
	wet_w *= green_water_support;
	healthy_w *= green_water_support;
	foliage_w *= mix(0.04, 1.0, green_water_support);
	// 冻原与林线不能被湿润、高活力和高叶量重新推回鲜绿。温度约 0.2 时
	// 这些绿色权重几乎退出，只留下地形纹理与后续雪盖。
	float cold_green_retention = mix(1.0, 0.08, cold_n);
	wet_w *= mix(1.0, 0.12, cold_n);
	healthy_w *= cold_green_retention;
	foliage_w *= cold_green_retention;

	dry_w *= mix(0.84, 1.16, i.pixel_noise.r);
	wet_w *= mix(0.86, 1.14, i.pixel_noise.b);
	healthy_w *= mix(0.88, 1.12, i.pixel_noise.g);
	decline_w += stress_w * 0.82;
	dieback_w += stress_w * decline_w * 0.24;

	vec3 weighted_tint =
			vec3(0.96, 1.00, 1.04) * cold_w
			+ vec3(1.10, 0.92, 0.78) * hot_w
			+ vec3(1.12, 1.04, 0.74) * dry_w
			+ vec3(0.86, 1.02, 0.88) * wet_w
			+ vec3(0.87, 1.03, 0.82) * (healthy_w + foliage_w)
			+ vec3(1.10, 0.90, 0.68) * decline_w
			+ vec3(0.56, 0.50, 0.42) * dieback_w;
	float total_w = cold_w + hot_w + dry_w + wet_w + healthy_w + foliage_w
			+ decline_w + dieback_w;
	if (total_w <= 0.001) {
		return surface;
	}

	weighted_tint /= total_w;
	float dominant_w = max(max(max(cold_w, hot_w), max(dry_w, wet_w)),
			max(max(healthy_w + foliage_w, decline_w), dieback_w));
	// 热旱同时拉满时保留更多地形底色，避免高温、干旱和衰退叠成整片橙红。
	float hot_dry_n = hot_n * dry_n;
	float coverage_cap = mix(0.85, 0.66, hot_dry_n);
	float coverage = min(clamp(dominant_w * 0.64, 0.0, 0.85), coverage_cap);
	vec3 graded = surface.base_color * mix(vec3(1.0), weighted_tint, coverage);

	// 色相强、明度稳：常温区展开色度，严寒区则转为灰蓝白。
	float value_shift = dry_w * 0.03 + hot_w * 0.01 + wet_w * 0.005
			+ (healthy_w + foliage_w) * 0.005 - cold_w * 0.03
			- decline_w * 0.04 - dieback_w * 0.12;
	value_shift = clamp(value_shift / max(total_w, 0.001), -0.12, 0.12) * coverage;
	float luma = dot(graded, vec3(0.299, 0.587, 0.114));
	float saturation_gain = 1.0 + 0.06 * coverage;
	float warm_chroma_control = clamp(hot_n * 0.85 + dry_n * 0.20, 0.0, 1.0);
	saturation_gain = mix(saturation_gain, 0.98, warm_chroma_control * 0.78);
	saturation_gain = mix(saturation_gain, 0.30, cold_n * 0.96);
	// 高活力和高湿度可以保持绿色语义，但禁止绿色通道获得额外的荧光式展开。
	// 该限制只收敛绿色主导色，不影响金黄、赭褐、岩灰和雪色。
	float green_axis = max(graded.g - max(graded.r, graded.b), 0.0);
	float green_chroma_w = smoothstep(0.08, 0.28, green_axis)
			* clamp((wet_w + healthy_w + foliage_w) / max(total_w, 0.001), 0.0, 1.0);
	saturation_gain = mix(saturation_gain, min(saturation_gain, 0.90),
			green_chroma_w * 0.92);
	graded = mix(vec3(luma), graded, saturation_gain);
	graded *= 1.0 + value_shift;
	// 乘性色无法从高饱和草地中真正移除绿色，因此极冷区再做一次受控的
	// 绝对中性色混合。目标仍由当前明度派生，山脊、坡面和地形类型不会被抹平。
	float frost_neutral_w = smoothstep(0.62, 0.96, cold_n)
			* mix(0.58, 0.70, snow_cold_n);
	float cold_luma = dot(graded, vec3(0.299, 0.587, 0.114));
	vec3 cold_neutral = mix(
			vec3(cold_luma) * vec3(0.96, 1.0, 1.04),
			vec3(0.70, 0.76, 0.80), 0.48);
	graded = mix(graded, cold_neutral, frost_neutral_w);
	surface.base_color = clamp(graded, vec3(0.0), vec3(1.0));
	surface.roughness = mix(surface.roughness, 0.92,
			clamp(dieback_w / max(total_w, 0.001), 0.0, 1.0) * 0.55);
	return surface;
}
