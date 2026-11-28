// 三格 state（layer1 的四个通道都是连续量）按权重混合。
// hex_cell_field 的 pk_field_blend_channel 只按 class 的单通道选择，state 需要整
// vec4 一起混，所以在这里镜像一份（与 pk_field_blend_channel 逐项同式）。
vec4 pk_field_blend_state(vec3 weights, vec4 s0, vec4 s1, vec4 s2) {
	return s0 * weights.x + s1 * weights.y + s2 * weights.z;
}

// 该 offset 行是否落在真实地图内。row 越界（南北边界之外）的 texel 是 padding
// 哨兵（pk_cell_table_fetch 只把 R 填成 B_SEA_ICE，其余通道为 0），连续量按它混合
// 会得到 0.08 这种假温度/假雪。返回 0/1，供权重遮罩与 dyn_valid 使用。
float pk_field_row_in_bounds(ivec2 c) {
	return step(0.0, float(c.y)) * step(float(c.y), float(pk_cell_map_h - 1));
}

// 解析岸线占比（方案 §3.7）：把「edge_distance.BA 的 8 邻域水 / 湖格占比」换成
// 「对偶三角形三格里水格 / 湖格占的权重」。水判定与 pk_cell_field_is_water_dom 共用
// terrain_static_biome_is_water，所以岸线占比与水陆分支不会各说各话。
// 用 w_raw：岸线占比是连续量（方案 §3.3）。
vec2 pk_cell_field_shore_frac(HexCellField f, vec4 e0, vec4 e1, vec4 e2) {
	int b0 = pk_byte_of(e0.r);
	int b1 = pk_byte_of(e1.r);
	int b2 = pk_byte_of(e2.r);
	float w0 = terrain_static_biome_is_water(b0) ? f.w_raw.x : 0.0;
	float w1 = terrain_static_biome_is_water(b1) ? f.w_raw.y : 0.0;
	float w2 = terrain_static_biome_is_water(b2) ? f.w_raw.z : 0.0;
	float l0 = (b0 == B_LAKE) ? f.w_raw.x : 0.0;
	float l1 = (b1 == B_LAKE) ? f.w_raw.y : 0.0;
	float l2 = (b2 == B_LAKE) ? f.w_raw.z : 0.0;
	return vec2(w0 + w1 + w2, l0 + l1 + l2);
}

// offset (col,row) → 该格中心的世界坐标（pointy-top / odd-r，对 §3.1 的分数 axial
// 做**逆运算**，与 pk_axial_to_offset 是两条独立表达式）：
//   q = col - (row - (row & 1)) / 2,  r = row        （pk_axial_to_offset 的逆）
//   x = √3·s·(q + r/2),              y = 1.5·s·r      （分数 axial 定义的逆）
// 只给 debug 视图 18 的独立复核用：把「重心 argmax」与「世界距离最近」两条路径
// 对撞，任何 offset 换算 / 回绕 / padding 的错都会立刻变红。
vec2 pk_offset_hex_center(ivec2 c) {
	int q = c.x - (c.y - (c.y & 1)) / 2;
	float r = float(c.y);
	return hex_size * vec2(PK_FIELD_SQRT3 * (float(q) + r * 0.5), 1.5 * r);
}
