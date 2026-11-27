	// [cell-field 2026-11-18] PK 路径不采逐像素索引图 / enum_lut / dyn_lut，全部改成
	// cell_table 的 texelFetch（无过滤、无导数、全命中缓存）：
	//   biome / veg / cover / landform ← layer0 class（三格已在 SETUP 顶部取好，取主导格）
	//   dyns（temp/wet/snow/vitality|sea_ice）← layer1 state，连续量按 w_raw 三格混合（§3.3）
	//   fog_k ← layer2 aux.R，MID/HIGH 与 state 同式按 w_raw 三格混合（fog-k-blend 2026-11-18），
	//           LOW 仍只读主导格
	// 采样记账（方案 §3.8，陆地 program）：MID/HIGH = warp 1 + class 3 + state 3 + aux 3
	//   + edge_distance 1（沟谷 crease）+ height 1 + noise 1 + 静态材质 2 = 15；
	//   LOW = warp 1 + class 3 + state 1 + aux 1 + edge 1 + height 1 + noise 1 + 材质 1 = 10。
	//   （LOW 与 MID 的差别是 state 1↔3、aux 1↔3 与材质 1↔2；水面 program 的 aux 一直是 3。）
	// _cell_id 仍被 debug 视图引用，但本变体里它的所有消费点都已换成场函数 ⇒ 固定 -1
	// （保留定义是为了不改下游函数原型，顺带让 cell_lut_uv() 的 LUT 读取自然退化）。
	int _cell_id = -1;
	ivec2 field_dom_c = pk_cell_field_dom_offset(cell_field);
	// padding 行（南北边界之外）没有真实格：先把它们的权重清零，再在真实格之间重新
	// 归一。三格全越界时退回原始 w_raw —— 那个像素本来就在地图外，dyn_valid / fog_k
	// 会走与今天 cid < 0 一致的分支。
	float field_inb0 = pk_field_row_in_bounds(cell_field.c0);
	float field_inb1 = pk_field_row_in_bounds(cell_field.c1);
	float field_inb2 = pk_field_row_in_bounds(cell_field.c2);
	vec3 field_w_valid = cell_field.w_raw * vec3(field_inb0, field_inb1, field_inb2);
	float field_valid = field_w_valid.x + field_w_valid.y + field_w_valid.z;
#if defined(PK_QUALITY_LOW)
	// LOW 档（方案 §3.8 的 state 1 预算）：只读主导格 1 个 texel，不混合。
	vec4 dyns = pk_cell_state_at(field_dom_c);
#else
	// MID/HIGH 档：state 三格按 w_raw 混合（连续量，格界处不再有雪线/海冰硬台阶）。
	// 权重在真实格之间重新归一，padding 格的哨兵 state 不会混进来。
	vec3 field_w = (field_valid > 1e-5)
			? field_w_valid / field_valid : cell_field.w_raw;
	vec4 dyns = pk_field_blend_state(field_w,
			pk_cell_state_at(cell_field.c0),
			pk_cell_state_at(cell_field.c1),
			pk_cell_state_at(cell_field.c2));
#endif
	// fog_k：aux.R。**MID/HIGH 与 state 同式走三格 w_raw 混合**，LOW 保持主导格 1 次。
	//
	// [fog-k-blend 2026-11-18] 原来只有主导格 1 次 texelFetch（方案 §3.3 把 fog_k 归为
	// "类别量、不插值"）。但同一张 aux 表的 water_depth（water_pipeline 的 wd）一直是
	// 三格混合的，地形的 biome 材质也有 terrain_ecotone_width 交织 —— 只有 fog_k 两套
	// 都没走，于是 `fog_gray` 的纸白在格内恒定、格界跳变：**地块纹理连续、白不连续**。
	// 用 field_w_valid（padding 权重已清零）而不是 field_w，避免把 padding 行的
	// aux.R 哨兵（B_SEA_ICE）混进来；1e-5 下限保证三格全越界时不会除零，
	// 那种像素随后会被 in_bounds(主导格)=0 的 mix 换成 1.0。
	//
	// [pr10 合并] 水深 field_water_depth 与 fog_k 共用同一批 aux 取值，水面 program
	// 不必在 water_pipeline 里重复取表。LOW 取主导格 1 次，MID/HIGH 三格取一次。
#if defined(PK_QUALITY_LOW)
	vec4 dominant_aux = pk_cell_aux_at(field_dom_c);
	float field_water_depth = dominant_aux.g;
	float field_fog = mix(1.0, dominant_aux.r,
			pk_field_row_in_bounds(field_dom_c));
#else
	vec4 aux0 = pk_cell_aux_at(cell_field.c0);
	vec4 aux1 = pk_cell_aux_at(cell_field.c1);
	vec4 aux2 = pk_cell_aux_at(cell_field.c2);
#ifdef PK_WATER_ONLY
	float field_water_depth = dot(cell_field.w_raw, vec3(aux0.g, aux1.g, aux2.g));
#endif
	float field_fog_lerp = (aux0.r * field_w_valid.x
			+ aux1.r * field_w_valid.y
			+ aux2.r * field_w_valid.z)
			/ max(field_valid, 1e-5);
	float field_fog = mix(1.0, field_fog_lerp,
			pk_field_row_in_bounds(field_dom_c));
#endif
