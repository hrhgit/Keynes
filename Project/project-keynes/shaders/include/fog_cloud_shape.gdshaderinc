// 把域缩放微调到「环绕周期恰好等于 4 的整数倍个噪声格」。
//
// 可平铺噪声靠的是把晶格 x 坐标对周期取模，前提是周期必须是**整数**格；再取 4 的
// 倍数，是为了让 1/2、1/4 频率的域扭曲层也落在整数格上。不做这件事，东西向环绕的
// 接缝处就是一条明显的竖线。缩放被改动的幅度通常 < 1%，云团大小的变化看不出来。
//
// 返回 vec2(修正后的缩放, 周期格数)；周期 0 表示地图不环绕。
vec2 fog_tileable_scale(float base_scale) {
	if (wrap_period_x <= 0.0001) {
		return vec2(base_scale, 0.0);
	}
	float cells = max(8.0, round(wrap_period_x * base_scale * 0.25) * 4.0);
	return vec2(cells / wrap_period_x, cells);
}

// 时间演化的可平铺梯度噪声。与单纯给 p 加偏移不同，这里让每个晶格角点的梯度
// 以不同速度和方向旋转，因此等值线会原地生成、消散和重组；先折叠 x 晶格坐标，
// 仍能保证东西向周期完全一致。seed 只改变旋转速率，t=0 时保持静态场原貌。
#include "res://shaders/include/fog_lattice.gdshaderinc"

#ifdef PK_FOG_LATTICE
uniform sampler2D fog_gradient_lattice : filter_linear, repeat_disable;
uniform float fog_gradient_blend = 0.0;
#endif

vec4 fog_vertical_gradients(float x, float y, float t, int band) {
#ifdef PK_FOG_LATTICE
	ivec2 pos = ivec2(int(x) & (FOG_LATTICE_SIDE - 1),
		band * FOG_LATTICE_SIDE + ((int(y) + FOG_LATTICE_Y_BIAS) & (FOG_LATTICE_SIDE - 1)));
	vec2 uv = (vec2(pos * ivec2(2, 1)) + vec2(0.5 + fog_gradient_blend, 0.5))
		/ vec2(float(FOG_LATTICE_SIDE * 2), float(FOG_LATTICE_SIDE * 10));
	return (textureLod(fog_gradient_lattice, uv, 0.0) - 0.5) * 3.0;
#else
	vec2 evolution = FOG_BANDS[band];
	float clock = t * evolution.x;
	return vec4(fog_evolving_gradient(vec2(x, y), clock, evolution.y),
		fog_evolving_gradient(vec2(x, y + 1.0), clock, evolution.y));
#endif
}


vec3 fog_grad_noise_tiled_evolve_d(vec2 p, float period_x, float t, int band) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_x >= 1.0) {
		x0 = mod(x0, period_x);
		x1 = mod(x1, period_x);
	}
	vec4 left = fog_vertical_gradients(x0, i.y, t, band);
	vec4 right = fog_vertical_gradients(x1, i.y, t, band);
	vec2 ga = left.xy;
	vec2 gb = right.xy;
	vec2 gc = left.zw;
	vec2 gd = right.zw;
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float k1 = vb - va;
	float k2 = vc - va;
	float k3 = va - vb - vc + vd;
	float n = va + k1 * u.x + k2 * u.y + k3 * u.x * u.y;
	vec2 dn = ga + u.x * (gb - ga) + u.y * (gc - ga)
		+ u.x * u.y * (ga - gb - gc + gd)
		+ du * vec2(k1 + k3 * u.y, k2 + k3 * u.x);
	return vec3(0.5 + 0.5 * n, 0.5 * dn);
}

float fog_grad_noise_tiled_evolve(vec2 p, float period_x, float t, int band) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float x0 = i.x;
	float x1 = i.x + 1.0;
	if (period_x >= 1.0) {
		x0 = mod(x0, period_x);
		x1 = mod(x1, period_x);
	}
	vec4 left = fog_vertical_gradients(x0, i.y, t, band);
	vec4 right = fog_vertical_gradients(x1, i.y, t, band);
	vec2 ga = left.xy;
	vec2 gb = right.xy;
	vec2 gc = left.zw;
	vec2 gd = right.zw;
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	return 0.5 + 0.5 * (
		va + u.x * (vb - va) + u.y * (vc - va)
		+ u.x * u.y * (va - vb - vc + vd)
	);
}

// 域扭曲：让 FBM 从"各向同性的糊团"变成有卷曲、有走向的云。
//
// 频率必须取 2 的负幂（1/2、1/4），否则子频率下的周期不再是整数格，接缝就回来了。
// q3 叠第二层，扭曲的扭曲 —— 这是云缘出现撕扯、翻卷的来源。
vec2 fog_domain_warp(vec2 p, float t, float period_n, int q) {
	float w0 = fog_grad_noise_tiled_evolve(
		p * 0.5 + vec2(0.0, t * 0.05), period_n * 0.5, t, 0
	);
	float w1 = fog_grad_noise_tiled_evolve(
		p * 0.5 + vec2(5.2, 1.3 - t * 0.04), period_n * 0.5, t, 1
	);
	vec2 pw = p + (vec2(w0, w1) - vec2(0.5)) * (2.0 * warp_amount);
	if (q >= 3) {
		float w2 = fog_grad_noise_tiled_evolve(
			pw * 0.25 + vec2(-3.1, 8.4), period_n * 0.25, t, 2
		);
		float w3 = fog_grad_noise_tiled_evolve(
			pw * 0.25 + vec2(11.9, -2.6), period_n * 0.25, t, 3
		);
		pw += (vec2(w2, w3) - vec2(0.5)) * (1.6 * warp_amount);
	}
	return pw;
}

struct FogCloudShape {
	float macro;
	float deck;
	float body;
	float top;
	float veil;
	float height;
	float thickness;
	vec2 broad_grad;
	vec2 detail_grad;
};

float fog_octave_fade(float lod_px, float frequency) {
	return 1.0 - smoothstep(0.30, 0.65, lod_px * frequency);
}

// 主形状由低频建立云丘，高频侵蚀边缘。法线明确拆成宽缓宏观坡向与低振幅锐利细节。
FogCloudShape fog_sample_shape(
	vec2 p, float t, float period_n, float lod_px, float cover, int q, vec2 parallax_p
) {
	vec2 drift = vec2(t * 0.12, -t * 0.08);
	// 每个频段使用不同方向/振幅的周期摆动。线性 drift 只会让整张场平移；
	// 相对 wobble 才会持续改变 octave 干涉关系，使云团内部翻卷、合并和分裂。
	vec2 wobble = vec2(sin(t * 0.55), cos(t * 0.43)) * 0.34;
	vec2 cross_wobble = vec2(-wobble.y, wobble.x);
	float f0 = fog_octave_fade(lod_px, 0.5);
	float f1 = fog_octave_fade(lod_px, 1.0);
	float f2 = fog_octave_fade(lod_px, 2.0);
	float f3 = (q >= 2) ? fog_octave_fade(lod_px, 4.0) : 0.0;

	vec3 n0 = fog_grad_noise_tiled_evolve_d(
		p * 0.5 + drift * 0.42 + vec2(7.1, -3.4),
		period_n * 0.5, t, 4
	);
	vec3 n1 = fog_grad_noise_tiled_evolve_d(
		p + drift * 0.76 + cross_wobble * 0.10 + vec2(-11.8, 5.6),
		period_n, t, 5
	);
	vec3 n2 = fog_grad_noise_tiled_evolve_d(
		p * 2.0 + drift * 1.16 - wobble * 0.30 + vec2(19.7, 13.2),
		period_n * 2.0, t, 6
	);
	vec3 n3 = vec3(0.5, 0.0, 0.0);
	if (q >= 2 && f3 > 0.002) {
		n3 = fog_grad_noise_tiled_evolve_d(
			p * 4.0 - drift * 1.42 + (wobble - cross_wobble) * 0.34
				+ vec2(-31.4, 22.9),
			period_n * 4.0, t, 7
		);
	}

	float w0 = 0.56 * f0;
	float w1 = 0.32 * f1;
	float w2 = 0.10 * f2;
	float w3 = 0.02 * f3;
	float norm = max(w0 + w1 + w2 + w3, 0.0001);
	float macro = (n0.x * w0 + n1.x * w1 + n2.x * w2 + n3.x * w3) / norm;

	float detail_norm = max(f2 * 0.78 + f3 * 0.22, 0.0001);
	float detail = (n2.x * f2 * 0.78 + n3.x * f3 * 0.22) / detail_norm;
	float shaped = clamp(macro + (detail - 0.5) * 0.10, 0.0, 1.0);

	// 宏观坡向只取 1/2、1 倍频，不再乘三条窄层级阈值的导数；后者会在每个
	// deck/body/top 等高线上制造尖脊。限制极端梯度，保证大轮廓始终宽缓。
	float broad_norm = max(f0 * 0.72 + f1 * 0.28, 0.0001);
	vec2 broad_grad = (
		n0.yz * (0.5 * f0 * 0.72)
		+ n1.yz * (f1 * 0.28)
	) / broad_norm;
	float broad_len = length(broad_grad);
	broad_grad *= min(1.0, 0.65 / max(broad_len, 0.0001));

	// 覆盖越低阈值越高：迷雾边界只剩破碎云团；满迷雾区则有连续低层托底。
	float cut = mix(0.69, 0.34, cover);

	// 视差剪切：field(p + o) ≈ field(p) + ∇field·o。用已有的解析宏观梯度把同一朵
	// 云的三层轮廓在屏幕上错开 —— deck 贴地不动，body 半偏移，top 全偏移。
	// 零重采样、纯 ALU；俯视正交相机本就没有真视差，这是最便宜的替代。
	float shaped_body = clamp(shaped + dot(broad_grad, parallax_p * 0.45), 0.0, 1.0);
	float shaped_top = clamp(shaped + dot(broad_grad, parallax_p), 0.0, 1.0);

	float deck = smoothstep(cut - 0.14, cut + 0.18, shaped);
	float body = smoothstep(cut + 0.00, cut + 0.30, shaped_body);
	float top = smoothstep(cut + 0.12, cut + 0.42, shaped_top);
	float veil = smoothstep(0.72, 1.0, cover) * mix(0.72, 1.0, deck);

	// 独立塔云场（q2+）：不同种子、不同漂移方向与速度的高层场，只从 deck 托底
	// 之上长出来（gate）。云顶因此能相对低层滑动 —— 高层风更快的差速，是俯视
	// 云海「有厚度」而非「一张噪声图」的最强线索。单次采样、不带导数：
	// top 的高频细节本来就由主场 shaped_top 提供，塔云场只需给出漂移的大形状。
	if (q >= 2) {
		vec2 tower_p = p + parallax_p
			+ vec2(t * 0.23, -t * 0.16) * top_shear_speed
			+ vec2(47.3, -19.1);
		float tower_field = fog_grad_noise_tiled_evolve(tower_p, period_n, t, 8);
		float tower_gate = smoothstep(cut - 0.10, cut + 0.16, shaped);
		top = max(top, smoothstep(cut + 0.16, cut + 0.44, tower_field) * tower_gate * 0.85);
	}

	// 2、4 倍频保留空间上的锐度，但用独立的小振幅进入法线；这样细节清楚，
	// 又不会把高频坡度放大成锡纸或岩石褶皱。LOD 砍掉 octave 时自然归零。
	vec2 detail_grad = (
		n2.yz * (2.0 * f2 * 0.78)
		+ n3.yz * (4.0 * f3 * 0.22)
	) / detail_norm;
	float detail_mask = clamp(deck * 0.20 + body * 0.46 + top * 0.34, 0.0, 1.0);
	detail_grad *= detail_mask;
	float detail_len = length(detail_grad);
	detail_grad *= min(1.0, 1.60 / max(detail_len, 0.0001));

	FogCloudShape s;
	s.macro = macro;
	s.deck = deck;
	s.body = body;
	s.top = top;
	s.veil = veil;
	s.height = clamp(0.20 + deck * 0.22 + body * 0.34 + top * 0.20, 0.0, 1.0);
	s.thickness = clamp(veil * 0.24 + deck * 0.30 + body * 0.32 + top * 0.14, 0.0, 1.0);
	s.broad_grad = broad_grad;
	s.detail_grad = detail_grad;
	return s;
}

// 阴影探针只取 2 个低频段的值，不计算导数。返回前方云体质量而不是硬高度差。
// 自阴影要的是软厚度：2x 高频段权重本来只有 4%，砍掉肉眼不可辨，探针开销省 1/3。
float fog_shadow_mass(
	vec2 p, float t, float period_n, float lod_px, float cover
) {
	vec2 drift = vec2(t * 0.12, -t * 0.08);
	vec2 wobble = vec2(sin(t * 0.55), cos(t * 0.43)) * 0.34;
	vec2 cross_wobble = vec2(-wobble.y, wobble.x);
	float f0 = fog_octave_fade(lod_px, 0.5);
	float f1 = fog_octave_fade(lod_px, 1.0);
	float n0 = fog_grad_noise_tiled_evolve(
		p * 0.5 + drift * 0.42 + vec2(7.1, -3.4),
		period_n * 0.5, t, 4
	);
	float n1 = fog_grad_noise_tiled_evolve(
		p + drift * 0.76 + cross_wobble * 0.10 + vec2(-11.8, 5.6),
		period_n, t, 5
	);
	float norm = max(f0 * 0.68 + f1 * 0.32, 0.0001);
	float macro = (n0 * f0 * 0.68 + n1 * f1 * 0.32) / norm;
	float cut = mix(0.69, 0.34, cover);
	float body = smoothstep(cut - 0.01, cut + 0.31, macro);
	float top = smoothstep(cut + 0.11, cut + 0.43, macro);
	return clamp(body * 0.72 + top * 0.28, 0.0, 1.0);
}

vec3 fog_soft_tonemap(vec3 x) {
	// ACES fitted：保留云顶高光层次，不让大面积直接 clamp 成纯白。
	x = max(x * cloud_exposure, vec3(0.0));
	return clamp(
		(x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14),
		vec3(0.0),
		vec3(1.0)
	);
}

#ifdef PK_CELL_FIELD
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-overlays 2026-11-18 / O3] 场函数本体（必须放在 fog_wrap_uv /
// fog_wrap_world_x / fog_soft_tonemap 之后：GLSL 没有函数前向声明）
// ═══════════════════════════════════════════════════════════════════════════

// 网格参数：uniform → PkHexGrid（核心唯一的几何入口）。
PkHexGrid fog_hex_grid() {
	PkHexGrid g;
	g.hex_size = hex_size;
	g.map_w = int(map_dims.x + 0.5);
	g.map_h = int(map_dims.y + 0.5);
	return g;
}

// 与 uniforms.gdshaderinc::wrap_world_pos 逐字同式（迷雾不 include uniforms）。
vec2 fog_wrap_world_pos(vec2 p) {
	return vec2(fog_wrap_world_x(p.x), p.y);
}

// GLSL 没有 clamp_length：按长度做径向 clamp。约束 2 要求的是**长度**上限，
// 不是逐轴 clamp —— 逐轴 clamp 会把位移方块的角削成斜边，形状会看出方向性。
vec2 fog_clamp_length(vec2 v, float max_len) {
	float l = length(v);
	return v * min(1.0, max_len / max(l, 1e-5));
}

// 一格的知识度 k = cell_table.layer2.R（fog_k）。
//   · cell_table_bound == false ⇒ 返回 0（= 厚云），**绝不**读不存在的层
//     （GLES3/WebGL2 对越界层 / 未绑 sampler2DArray 的返回值未定义）；
//   · row 南北越界 = 地图外 padding：**k = 0（完全不透明）**。
//     [2026-11-18 修复] 这里一度按地形侧的「padding 视作全知 k=1」写，结果世界上下
//     那圈 padding 海冰直接露出来了（截图证据：屏幕上下各一条蓝色冰带）。
//     地形侧 `field_fog` 用 k=1 是**早退判定**的语义（padding 不早退、照常渲染），
//     而迷雾侧 k 是**显示不透明度**的语义；两者相反不是矛盾 —— 渲染出来的 padding
//     必须被迷雾盖住，否则玩家就看到了地图外的极地海冰。
//     `climate_season.gdshaderinc` 里也明写「padding 像素恒为 B_SEA_ICE 且被
//     FogOfWarLayer 整片不透明覆盖」，本行是那条约定的执行点。
float fog_cell_k(ivec2 c) {
	if (!cell_table_bound) {
		return 0.0;
	}
	int w = int(cell_table_size.x + 0.5);
	int h = int(cell_table_size.y + 0.5);
	float k = texelFetch(cell_table,
			ivec3(pk_posmod(c.x, max(w, 1)), clamp(c.y, 0, max(h - 1, 0)), 2), 0).r;
	float inside = step(0.0, float(c.y)) * step(float(c.y), float(h - 1));
	return mix(0.0, k, inside);
}

// 三格里主导格的 k（约束 3 的判定只读主导格，与地形 world_map.gdshader:541 同口径）。
float fog_tri_dom_k(PkHexTri t) {
	int d = pk_hex_tri_dom(t);
	ivec2 c = (d == 0) ? t.c0 : ((d == 1) ? t.c1 : t.c2);
	return fog_cell_k(c);
}

// 地形扭曲场在 wp_wrapped 处的世界位移 —— 与地形
// hex_cell_field.gdshaderinc::pk_boundary_warp_world 逐式相同（解码系数、
// world_origin/world_size 的 uv 映射、tiled / 非 tiled 两条来源）。
// 未烘焙时恒为 0 ⇒ 退化成直边六边形归属（两边一起退化，判定仍然一致）。
vec2 pk_fog_terrain_warp_world(vec2 wp_wrapped) {
	if (!terrain_warp_layer_bound) {
		return vec2(0.0);
	}
	vec2 uv = fog_wrap_uv((wp_wrapped - world_origin) / world_size);
#ifdef MAP_VISUAL_TILED
	vec2 rg = texture(visual_warp_tiles, visual_tile_address(uv)).rg;
#else
	vec2 rg = texture(terrain_surface_tex, vec3(visual_static_wrap_uv(uv), 6.0)).rg;
#endif
	return (rg * 2.0 - 1.0) * (terrain_warp_range * hex_size * terrain_warp_amp);
}
#endif // PK_CELL_FIELD
