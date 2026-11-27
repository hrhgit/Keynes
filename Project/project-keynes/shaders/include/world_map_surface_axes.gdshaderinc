	// enum 通道（biome/veg/cover）走 cell 索引图 + enum_lut。
	// cid<0 是极地外侧的不可交互 padding。玩家地图把它表现为海冰，既明确世界边界，
	// 也避免无归属区域看起来像可点击海洋；模拟与选格仍只认真实 cell id。
	int biome;
	int veg;
	int cover;
	// fog_k = 视野知识度：0 未探索 / 0.5 已探索未可见 / 1 完全可见。它搭车在
	// enum_lut 的 A 通道上，所以拿到它是**零新增 texture sample** —— 主 shader
	// 本来就无条件采这张 LUT，只是多读一个分量。地图外 padding 视作全知，不参与
	// 迷雾（padding 本就由迷雾层自己盖住）。
	float fog_k = 1.0;
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 类别三元组取**主导格**的 layer0（pk_field_class_of），
	// 语义等价于今天 enum_lut[主 cell]。padding 行由 pk_cell_table_fetch 的哨兵给出
	// B_SEA_ICE / 0 / 0，与今天 cid < 0 的三个赋值逐值一致。
	// fog_k 直接取主导格 layer2.R（上面的 field_fog，1 次 texelFetch）：与今天
	// enum_lut[主 cell].a 的语义逐值一致（方案 §3.3 把 fog_k 归为类别量，不插值）；
	// 移动端那条 DitherUV 次生选格整段编译掉（方案 §3.6）。
	vec4 field_cls_dom = pk_field_class_of(cell_field, cell_e0, cell_e1, cell_e2);
	biome = pk_byte_of(field_cls_dom.r);
	veg = pk_byte_of(field_cls_dom.g);
	cover = pk_byte_of(field_cls_dom.b);
	fog_k = field_fog;
#else
	if (_cell_id >= 0) {
		vec4 elut = texture(enum_lut, cell_lut_uv(_cell_id));
		biome = int(elut.r * 255.0 + 0.5);
		veg   = int(elut.g * 255.0 + 0.5);
		cover = int(elut.b * 255.0 + 0.5);
		fog_k = elut.a;
	} else {
		biome = B_SEA_ICE;
		veg = 0;
		cover = 0;
	}
#endif
	// [landform 轴可视化 2026-06-25] landform id 走 map_index_atlas.A（per-pixel, NEAREST），
	// 供陆地管线给火山/高原/峡谷/裂谷/高峰补充专属着色。地图外哨兵采样得 0（=DEEP_OCEAN，陆地分支不消费）。
	// [cell-field 2026-11-18] PK 变体改读主导格 layer0.A（padding 哨兵 A=0，与 map_index 的
	// 地图外哨兵同值）。
#ifdef PK_CELL_FIELD
	int landform = pk_byte_of(field_cls_dom.a);
#else
	int landform = int(map_px.a * 255.0 + 0.5);
#endif
	float moist = dyns.g;
	// [cell-field-web 2026-11-18] lat_norm 的归一化分母不再借 map_index 纹理的尺寸：
	// `visual_static_texture_size()` 在非 tiled 下就是 `textureSize(map_index_atlas, 0)`，
	// 而 map_index_atlas 在该组合下整张退役。改用 derived_resolution —— 二者**逐值相等**：
	//   非 tiled：derived_resolution ← world.derived_size（renderer_material_publish.gd:404-405），
	//             而 map_index_atlas = world.enum_atlas_tex 正是按 world.derived_size 生成
	//             （map_baker.gd:774 `world.derived_size = world.hm_size`、:916-918），
	//             `textureSize()` 取回的又是整数像素尺寸 ⇒ 同一个数。
	//   tiled：  derived_resolution ← visual_tiles.layout.logical_size（同文件 :404-409），
	//             `visual_static_texture_size()` 也返回 visual_logical_resolution，
	//             同样由 renderer_terrain_horizon.gd:750 推自 layout.logical_size。
#ifdef PK_CELL_FIELD_NO_LEGACY_LUT
	float _Hf = derived_resolution.y;
#else
	float _Hf = visual_static_texture_size().y;
#endif
	float lat_norm = clamp((uv.y * _Hf - 0.5) / max(_Hf - 1.0, 1.0), 0.0, 1.0);
	float dyn_temp = dyns.r;
	float dyn_wet = dyns.g;
	float dyn_snow = dyns.b;
	float dyn_vitality = dyns.a;
	// [snow-dyn-valid-fix 2026-06-16] 真实格子动态 atlas/LUT 恒为有效。
	// 历史背景：旧值 step(0.02, dyn_temp) 是为了兜底"bake_world 阶段温度尚未初始化
	// (默认 0.0)→ atlas R 通道为 0"的时序窗口。但该哨兵把真实极寒格(温度=0)误判为
	// "未初始化"，导致整格动态状态(含 100% 雪盖)被清零、屏幕不出雪。
	// 现已在 map_generator.gd 把温度 Bootstrap 前移到 bake_world 之前，atlas 从第 0
	// 帧即带真实纬度温度，不再存在未初始化窗口，因此恒信 atlas 真值（含温度=0 的极寒）。
	// 唯一例外：cell-indirection 下地图外哨兵像素（cid<0）采样为 vec4(0)，仍回退
	// derived_temp，避免地图边缘出现"温度=0 冷边"。on-map 真实格永远有效。
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] dyn_valid = 「三格里真实格占的权重过半」。与今天
	// cid < 0 ⇒ 0 的硬判定语义相同（padding 格的 state 权重已被清零），但在南北
	// 边界一格之内是渐变的，不会再出现整块"温度=0 冷边"。
	float dyn_valid = step(0.5, field_valid);
#else
	float dyn_valid = (_cell_id < 0) ? 0.0 : 1.0;
#endif
	moist = mix(moist, dyn_wet, dyn_valid);
