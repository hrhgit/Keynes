shader_type canvas_item;
render_mode blend_mix, unshaded;

#include "res://shaders/include/shader_quality.gdshaderinc"

// [fog-runtime-quality 2026-11-17] 编译期 tier 只裁特征，运行期画质归玩家设置。
//
// PK_WEB_FOG_RUNTIME 是历史名字（web 先落地），语义其实是"忽略编译期档，把
// fog_quality 夹到 2"。移动端必须共用它：安卓的编译期档被 player_game 钉死在
// MOBILE_QUALITY_LOW（性能决定，换档 = 换 program），而迷雾的
// `MOBILE_QUALITY_LOW → return 0` 会让设置里的"最高画质"变成空操作 —— q0 只有一层
// 灰蓝底色加起伏，没有分层云海 / TOD 光照 / 自阴影，远看就是一块灰板。
//
// web 的旧宏保留为别名，两份程序逐字节不变；新代码一律用 PK_FOG_RUNTIME。
#if defined(PK_WEB_FOG_RUNTIME) && !defined(PK_FOG_RUNTIME)
#define PK_FOG_RUNTIME
#endif

// ════════════════════════════════════════════════════════════════════════
// fog_of_war.gdshader — 三态视野迷雾（体积云）
//
// ── 取 k 的两条路径（`PK_CELL_FIELD` 二选一）────────────────────────────
// 开（本任务 O3，方案 docs/plans/terrain-cell-field-overlays-plan.md §3.6）：
//   解析格界（cell field）。世界坐标 → 可平铺低频扭曲（按长度 clamp）→ 对偶三角形
//   三格 + 重心 → 连续权重（格心/极地保护）→ 三格 k 加权。k 来自 `cell_table` layer2.R（offset 空间的
//   per-cell 表，1 texel = 1 格），不再是"纹理里的类别量"，所以任意 zoom 都没有纹素
//   台阶。另外**在自己的 shader 内复算地形的早退判定**（约束 3），保证「地形早退的
//   像素迷雾一定不透明」。开关与环境侧地形**同一个判定口**
//   （RendererShaderWater._cell_field_active），所以不会出现"地形走旧路径、迷雾走新
//   路径"从而判一个不存在的条件。
// 关（今日行为，逐字节不变）：
//   数据通路与天气云完全同构：map_index_atlas.GB 逐像素解出 cell.index，再经
//   cell-index 间接寻址采 per-cell LUT。区别是迷雾不占用独立纹理 —— 它复用
//   enum_lut 空闲的 A 通道（enum_lut 已从 RGB8 升为 RGBA8），因此主地形拿迷雾
//   值是零新增采样。
//
// 知识度 k（开：cell_table.layer2.R / 关：enum_lut.a，语义完全相同）：
//   k = 0.0  未探索      → 厚云，完全不透明
//   k = 0.5  已探索未可见 → 薄纱 + 主地形去饱和灰化（灰化在 world_map 做）
//   k = 1.0  完全可见     → alpha 0，整个 fragment 早退
//   中间值 = 烘焙期 hex 邻域 blur 产生的柔化过渡带（开路径下再叠一层场插值）
//
// ── 云怎么画：分层 2.5D 云海 ─────────────────────────────────────────
//
// 迷雾必须在未探索区保持完全遮挡，但「完全遮挡」不等于一块不透明浮雕。这里把同一
// 个连续密度场分成三层：低层层云 deck、中层云体 body、高层云塔 top。低层负责玩法
// 遮挡，中高层负责可读的云团形状；三层共享连续宏观场，因此不会出现互相滑动的贴片。
//
//   · 形状    普通 FBM 宏观场 + 高频侵蚀；域扭曲保持低幅，避免流体涡纹
//   · 法线    低频宽缓宏观坡向 + 小振幅高频细节，避免尖脊和「揉皱锡纸」
//   · 自阴影  沿主光方向积分前方云体质量，得到柔和光学厚度，不比较硬高度差
//   · 散射    双指数直射透过 + 有理式多重散射 + 天空半球补光
//   · 合成    deck/body/top 分层提亮，最后做软色调映射，避免大片截成纯白
//   · 视差    屏幕空间假视差：用解析梯度一阶位移把三层轮廓按高度错开，零重采样
//   · 差速    高层塔云是独立风场（异种子/异速/异向），与低层底盘相对滑动
//   · 体积    高度 AO 压谷底直射 + 坡向轮廓光勾云团边缘 + S 曲线拉回中间调
//
// q2/q3 的探针只积分二维云体质量，不做每像素数十步体积 raymarch；但视觉模型已经
// 从「一张地形高度图」改为「有低层托底的分层云体」。
//
// ── 东西向环绕 ────────────────────────────────────────────────────────
// 地图东西向无限滚动，采样点会被 fog_wrap_world_x 折回一个周期内。普通噪声在周期
// 两端对不上，接缝处就是一条肉眼可见的竖线。所以**这个 shader 里所有噪声都必须
// 走可平铺版本**（cloud_*_tiled / cloud_cumulus_*），并且域缩放要先经
// fog_tileable_scale 微调，让环绕周期恰好落在整数格上。
//
// 光照走 earth_daylight 逐像素晨昏线（与地形/水面/植被/天气云同一真源），
// 所以迷雾会随昼夜被晨昏线扫过：正午冷白顶 + 蓝灰缝隙，黄昏暖橙侧光 + 长投影，
// 夜里只剩冷蓝环境光。
//
// ── 质量分档 ──────────────────────────────────────────────────────────
// 有效档 = min(编译期 tier 上限, 运行时 fog_quality)。编译期宏砍掉低端机的
// 整段代码，运行时 uniform 让桌面端低配也能降档。
//   q0 超低：1 octave，无光照 —— 纯色 + 一点起伏，最便宜。
//   q1 低  ：3 频段分层密度 + 平滑法线 + TOD。无扭曲/无自阴影。
//   q2 中  ：4 频段 + 1 层域扭曲 + 2 个质量探针 + 独立塔云场 + Powder/银边/透射。
//   q3 高  ：4 频段 + 2 层域扭曲 + 2 个质量探针 + 独立塔云场 + 天空 SH 环境光。
//
// q3 每像素 4 主场 + 4 扭曲 + 1 塔云 + 2×2 阴影 = 13 次噪声采样。
// 阴影探针只吃 2 个低频段：第 3 频段权重仅 4%，却要多付 1/3 的探针开销；
// 探针数 3 → 2 同理 —— 自阴影是软厚度，少一段远探针肉眼不可辨。
// ════════════════════════════════════════════════════════════════════════

// [cell-field-overlays 2026-11-18 / O3] PK_CELL_FIELD 变体不再读 enum_lut：知识度 k 改从
// cell_table 的 layer2.R（offset 空间 per-cell 表）取。声明本身留在这两行之外的老路径里，
// 否则 PK 变体会白白占一个 sampler 槽（方案 §3.9 的迷雾账：4 → 2）。
#ifndef PK_CELL_FIELD
uniform sampler2D enum_lut : filter_nearest, repeat_disable;        // A = 知识度 k
#endif
uniform vec2 lut_dims = vec2(0.0);
uniform bool has_terrain_edge_data = false;
uniform float terrain_ecotone_width : hint_range(0.0, 0.96) = 0.84;

uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(1.0);
uniform float wrap_origin_x = 0.0;
uniform float wrap_period_x = 0.0;
// [cell-field-overlays 2026-11-18 / O3] PK_CELL_FIELD 变体删掉三条旧采样链：
//   map_index（主格 id）、edge_neighbor（副格 id）、edge_distance（次生权重）。
// 三个 VT_USE_* 只决定 visual_tile_sampling 里是否声明那几个 sampler / helper，所以
// 「关掉它们」就等于「整条旧路径从 program 里消失」，而不是靠"声明了但不采"。
// 关闭 PK 时这三行与今日逐字节相同（`#ifndef` 展开成同样三行）。
#ifndef PK_CELL_FIELD
#define VT_USE_MAP_INDEX
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#endif
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
uniform float world_time = 0.0;
uniform float hex_world_diameter = 38.0;

#ifdef PK_CELL_FIELD
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-overlays 2026-11-18 / O3] 解析格界（场函数）路径
//
// 方案：docs/plans/terrain-cell-field-overlays-plan.md §3.6（迷雾显示、三条约束）、
//       §3.2（坐标契约）、§3.9（迷雾采样账）、§4（开关跟随地形）
// 契约：docs/plans/terrain-cell-field-contract.md §1（AA 带宽 / 平局次序）、
//       §9.1（回绕接缝 AA）、§9.3（世界 uniform 不得硬编码）
//
// 只 include **零 uniform** 的核心 + 胶水（hex_cell_core / cell_field_overlays）。
// 绝不 include hex_cell_field.gdshaderinc：那是地形的包装层，依赖 uniforms.gdshaderinc
// 的 world_origin / hex_size / terrain_warp_* / cell_table_size / B_SEA_ICE 等一整批
// uniform，迷雾一条都没有 ⇒ 整片编译失败。
#include "res://shaders/include/cell_field_overlays.gdshaderinc"

// ── 新增 uniform：**全部由 FogOfWarLayer 推送**，一个都不许依赖这里的默认值 ──────
// 契约 §9.3「世界坐标 uniform 不得硬编码」：hex_size / map_dims 必须来自宿主
// （host.hex_size / WorldData 的地图尺寸），不从 hex_world_diameter 反推。
uniform float hex_size = 22.0;                       // 世界单位 / hex（宿主 hex_size）
uniform vec2 map_dims = vec2(0.0);                   // (map_w, map_h)，= WorldData.cell_table_dims
uniform sampler2DArray cell_table : filter_nearest, repeat_disable;   // offset 空间 4 层 RGBA8
uniform vec2 cell_table_size = vec2(1.0, 1.0);       // 与 map_dims 同值（texelFetch 的模数）
uniform bool cell_table_bound = false;               // false ⇒ 绝不读表（一律按厚云处理）
// 地形扭曲场（约束 3 必须与地形用**同一张**场，否则"早退像素"两边的判定会错开）：
//   非 tiled → terrain_surface_tex 的 layer6（RG = warp xy，LINEAR 双线性）；
//   tiled    → visual_warp_tiles（同一个 bundle 的 boundary_warp）。
// terrain_warp_layer_bound == false（未烘焙）⇒ 扭曲视为 0，与地形侧逐值一致。
uniform bool terrain_warp_layer_bound = false;
uniform float terrain_warp_range = 1.6;              // = WorldData.boundary_warp_range
uniform float terrain_warp_amp = 0.4;                // = MapBaker.WARP_AMP（生成期同一常量）
// 扭曲场的 sampler 自己声明（**不**复用 visual_tile_sampling 的 VT_USE_BOUNDARY_WARP 块）：
// 那个块同时声明 terrain_warp_layer_bound，而非 tiled 分支还要 VT_USE_TERRAIN_SURFACE_ARRAY
// 才肯用 terrain_surface_tex（否则退成 terrain_boundary_warp_tex 这张不存在的 2D 图），
// 会连带把 terrain_surface_layer_count / terrain_edge_layers_bound 等四个与迷雾无关的
// uniform 拖进来。两个名字与那两块**逐字同值**，绑定由 FogOfWarLayer 按地形同一套门控推送。
#ifdef MAP_VISUAL_TILED
uniform sampler2DArray visual_warp_tiles : filter_linear, repeat_disable;
#else
uniform sampler2DArray terrain_surface_tex : filter_linear, repeat_disable;
#endif
// 迷雾锐化带宽（gap 单位）。约束 1：必须 < √3/2，否则沿穿过格心的线出现接缝；
// 默认 0.6 刻意比地形的 terrain_ecotone_width（0.84）宽 —— 迷雾是"柔边类别量"。
uniform float fog_field_band : hint_range(0.0, 0.86) = 0.6;
// 迷雾自己的可平铺低频扭曲（纯 ALU，方案 §3.2 第 3 条：必须沿 x 可平铺）。
// freq 提高到 0.010，在原有两次噪声内打散长直边；
// amp 的单位是 **hex_size**（旧 edge_warp 用的是 hex 直径 —— 见下面的约束 2 推导）。
uniform float fog_warp_freq = 0.010;
uniform float fog_warp_amp = 0.55;
// 地形早退判定（必须与地形 program **逐像素同形**，见 fragment 里的约束 3）。
// 由 FogOfWarLayer 从 host._shader_mat 上读地形**实际收到**的实参再推过来 ——
// 不复述 _effective_fog_early_out() 的判定链（那会漂移）。
uniform bool fog_early_out_enabled = false;
uniform float fog_early_out_k : hint_range(0.0, 0.5) = 0.02;
// 调试档（仅 PK_CELL_FIELD；0 = 正常）：
//   1 = terrain_hidden（R 通道 0/1）  2 = 最终 alpha（RGB 灰阶）  3 = 显示用 k（R 通道）
// 给 tests/world/fog_cell_field_test.gd 的不变量探针回读用（方案 §6 不变量 1/2）。
uniform int fog_debug_view = 0;
// 场函数本体见文件下半部（`void vertex()` 之前的 PK_CELL_FIELD 段）：它们要调
// fog_wrap_uv / fog_wrap_world_x，而那两个函数在本文件 200 行之后才定义。
#endif // PK_CELL_FIELD

uniform bool fog_enabled = true;
// 运行时质量档 0..3，会被编译期 tier 上限夹住。
uniform int fog_quality : hint_range(0, 3) = 3;

// ── TOD（earth_daylight 的依赖必须在 include 之前声明）────────────────
uniform bool day_night_enabled = true;
uniform bool tod_debug_sun_position_enabled = false;
uniform vec2 tod_debug_sun_uv = vec2(0.25, 0.5);
uniform float tod_debug_sun_height_scale : hint_range(0.2, 1.5) = 1.0;
// 只在调试永昼覆盖时被 earth_daylight 读到；正式模式走逐像素太阳方向。
uniform vec3 tod_sun_dir = vec3(0.4, -0.7, 0.6);
uniform float season_phase : hint_range(0.0, 4.0) = 1.0;
uniform float day_phase : hint_range(0.0, 1.0) = 0.25;
uniform float axial_tilt_rad : hint_range(0.0, 0.7854) = 0.4101523;
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/cloud_noise.gdshaderinc"
#include "res://shaders/include/cloud_volume.gdshaderinc"

// q0 的基础色。q1+ 走分层密度散射，使用 deck_color / cloud_albedo。
// world_map 的早退分支输出与 unexplored_color 匹配的常量色；一旦开了光照（q>=1）
// 两者必然对不齐，所以早退只在 q0 允许（见 FogOfWarLayer）。
uniform vec3 unexplored_color : source_color = vec3(0.52, 0.56, 0.64);
// 已探索但离开当前视野的格子要明显区别于完全可见区域。提高薄纱不透明度，
// 同时把颜色压向冷灰蓝，让远景仍能读出地形轮廓但不会误认为已经在视野内。
uniform vec3 explored_color : source_color = vec3(0.62, 0.69, 0.78);
uniform float explored_alpha : hint_range(0.0, 1.0) = 0.64;
// 未探索区云缝下面的低层层云。它承担玩法遮挡，不应被画成黑色峡谷。
uniform vec3 deck_color : source_color = vec3(0.58, 0.65, 0.76);
// 边界噪声位移（hex 直径倍数）。让迷雾边缘不贴着 hex 轮廓走。
uniform float edge_warp : hint_range(0.0, 2.0) = 0.55;
// 云翻腾速度，低于天气云但必须能在 1x 下读出缓慢形变；游戏倍速由图层时钟另乘。
uniform float churn_speed : hint_range(0.0, 1.0) = 0.20;
// 主云团的空间尺度，单位 = hex 直径。越大云团越大。
uniform float cloud_scale : hint_range(1.0, 20.0) = 3.2;
// 域扭曲只改变云缘走向，不参与法线，避免把低频扭曲放大成巨型坡面。
uniform float warp_amount : hint_range(0.0, 2.5) = 0.28;

// ── q1+ 分层云海 ──
uniform vec3 cloud_albedo : source_color = vec3(0.97, 0.975, 1.0);
// 宏观法线只描述宽缓云丘；细节法线频率高但振幅小，负责近看时的锐利绒边。
uniform float cloud_relief : hint_range(0.0, 2.0) = 0.34;
uniform float cloud_detail_relief : hint_range(0.0, 0.5) = 0.08;
uniform float light_wrap : hint_range(0.0, 2.0) = 1.0;
uniform float sun_gain : hint_range(0.0, 3.0) = 0.68;
uniform float ms_gain : hint_range(0.0, 2.0) = 0.42;
uniform float ms_falloff : hint_range(0.1, 4.0) = 0.90;
uniform float ambient_gain : hint_range(0.0, 2.0) = 0.50;
uniform float valley_sky : hint_range(0.0, 1.0) = 0.68;
// 天光色相。现实中云的暗面偏**冷蓝**：天光来自 Rayleigh 散射，偏蓝，而它正是
// 暗部的主要照明。受光面暖白 + 暗面冷蓝的这一组对比，是云"看起来真"的一大半；
// 暗部做成中性灰就立刻假了。但也别过头 —— 冲到墨蓝就成了水下。
// 使用时会先归一化到亮度 1，所以这个值只改色相、不改明度。
uniform vec3 shadow_tint : source_color = vec3(0.84, 0.91, 1.0);
// 暗部转蓝的速度：ms_depth 乘上它得到「天光占比」。越大越早转蓝。
uniform float shadow_tint_depth : hint_range(0.0, 3.0) = 0.75;
// 自阴影积分范围与消光强度。两者都刻意压低，阴影应是软厚度，不是黑色沟槽。
uniform float shadow_reach : hint_range(0.0, 6.0) = 1.15;
uniform float shadow_absorb : hint_range(0.0, 20.0) = 3.2;
// Powder（糖粉效应）权重、银边强度、次表面透射强度。
uniform float powder_weight : hint_range(0.0, 1.0) = 0.28;
uniform float silver_gain : hint_range(0.0, 4.0) = 0.65;
uniform float sss_gain : hint_range(0.0, 2.0) = 0.25;
// HG 前向散射各向异性。
uniform float phase_g : hint_range(0.0, 0.95) = 0.58;
uniform float cloud_exposure : hint_range(0.4, 2.0) = 1.12;

// ── 体积感增强（视差 / 差速 / 轮廓光）──
// 屏幕空间假视差强度，单位 = hex 直径（屏幕四角处的高层云最大偏移）。俯视正交
// 相机没有真视差；这里用屏幕位置近似视线方向，把高层云沿视线路径错开。
// 它是纯屏幕函数，三块 wrap 副本取值一致，不会引入环绕接缝。
uniform float parallax_strength : hint_range(0.0, 2.0) = 0.80;
// 独立塔云场的漂移速度倍率：高层风比低层快，云顶相对云海底盘滑动（差速）。
uniform float top_shear_speed : hint_range(0.0, 2.0) = 0.75;
// 高度 AO 强度：压低谷底云缝的直射/反弹光，拉开云顶与云缝的明暗落差。
uniform float ao_strength : hint_range(0.0, 1.0) = 0.50;
// 坡向轮廓光强度：迎光坡提亮（背光坡另有小幅压暗，固定 0.16）。
uniform float rim_gain : hint_range(0.0, 2.0) = 0.55;
// 软色调映射后的 S 曲线对比度，0 = 不处理。
uniform float volume_contrast : hint_range(0.0, 0.6) = 0.22;
// 夜侧整体调光器：合成末端按 cloud_day 混入此倍率。夜云亮暗是艺术偏好，
// 与其分别拧环境光/月光/填充五六个旋钮，不如给一个总闸。1 = 夜昼同亮。
uniform float night_darkness : hint_range(0.2, 1.0) = 0.60;

varying vec2 v_world;

int effective_fog_quality() {
#if defined(PK_FOG_RUNTIME)
	// 运行期档权威：编译期 tier 只决定编进来的特征集。
	//
	// [mobile-high-full 2026-11-17] HIGH 档不再是"移动平台精简档"（见
	// shader_quality.gdshaderinc 里为什么 HIGH 不再定义 PK_MOBILE_ANY），
	// 所以它和桌面一样可以吃到 q3（第二层域扭曲 + 球谐天光）。
	// LOW/MID 仍夹到 2：它们的每像素分支预算就是按 q2 定的。
#if defined(MOBILE_QUALITY_HIGH)
	return clamp(fog_quality, 0, 3);
#else
	return min(fog_quality, 2);
#endif
#elif defined(MOBILE_QUALITY_LOW)
	return 0;
#elif defined(MOBILE_QUALITY_MID)
	return min(fog_quality, 1);
#elif defined(MOBILE_QUALITY_HIGH)
	return min(fog_quality, 2);
#else
	return clamp(fog_quality, 0, 3);
#endif
}

float fog_wrap_world_x(float x) {
	if (wrap_period_x <= 0.0001) {
		return x;
	}
	return wrap_origin_x + mod(x - wrap_origin_x, wrap_period_x);
}

vec2 fog_wrap_uv(vec2 uv) {
	if (wrap_period_x <= 0.0001) {
		return clamp(uv, vec2(0.0), vec2(1.0));
	}
	float world_x = world_origin.x + uv.x * world_size.x;
	float wrapped_x = fog_wrap_world_x(world_x);
	return vec2((wrapped_x - world_origin.x) / world_size.x, clamp(uv.y, 0.0, 1.0));
}

// [cell-field-overlays 2026-11-18 / O3] 整段旧取 k 链路在 PK_CELL_FIELD 变体里
// **不参与编译**：它要 map_index（视觉索引图）、edge_neighbor / edge_distance 两场、
// 以及纹理空间的 Bayer 选格 —— 场函数路径一个都不用，而且三个 VT_USE_* 已经关掉，
// 这些 helper 会直接引用到不存在的符号。关掉 PK 时本段与今日逐字节相同。
#ifndef PK_CELL_FIELD
// cell-index 间接寻址（与 cell_indirect.gdshaderinc 同公式；此处内联，避免为了
// 一个 A 通道把 dyn/eco LUT 的 uniform 依赖全拖进来）。
int fog_decode_cell_index(vec2 uv) {
	vec2 gb = visual_sample_map_index(uv).gb;
	int lo = int(gb.r * 255.0 + 0.5);
	int hi = int(gb.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

vec2 fog_cell_lut_uv(int cid) {
	int lw = int(lut_dims.x + 0.5);
	if (lw < 1) { lw = 1; }
	int cx = cid % lw;
	int cy = cid / lw;
	return (vec2(float(cx), float(cy)) + 0.5) / max(lut_dims, vec2(1.0));
}

int fog_decode_edge_secondary(vec2 uv) {
	vec2 rg = visual_sample_edge_neighbor(fog_wrap_uv(uv)).rg;
	int lo = int(rg.r * 255.0 + 0.5);
	int hi = int(rg.g * 255.0 + 0.5);
	int cid = lo + hi * 256;
	return (cid >= 65535) ? -1 : cid;
}

float fog_bayer2_digit(vec2 bit_xy) {
	if (bit_xy.y < 0.5) {
		return (bit_xy.x < 0.5) ? 0.0 : 2.0;
	}
	return (bit_xy.x < 0.5) ? 3.0 : 1.0;
}

const float FOG_DITHER_THRESHOLD_MARGIN = 0.18;

float fog_mobile_dither_uv_threshold(vec2 uv, vec2 wp) {
	vec2 atlas_dims = visual_static_texture_size();
	vec2 pixel_xy = floor(fog_wrap_uv(uv) * atlas_dims);
	if (wrap_period_x > 0.0001 && world_size.x > 0.0001) {
		float period_px = max(
				8.0,
				round((atlas_dims.x * wrap_period_x / world_size.x) / 8.0) * 8.0);
		float phase = (fog_wrap_world_x(wp.x) - wrap_origin_x) / wrap_period_x;
		pixel_xy.x = floor(fract(phase) * period_px);
	}
	vec2 p = mod(pixel_xy, 8.0);
	float value = 16.0 * fog_bayer2_digit(mod(p, 2.0))
			+ 4.0 * fog_bayer2_digit(mod(floor(p * 0.5), 2.0))
			+ fog_bayer2_digit(floor(p * 0.25));
	float raw_threshold = (value + 0.5) / 64.0;
	return mix(
			FOG_DITHER_THRESHOLD_MARGIN,
			1.0 - FOG_DITHER_THRESHOLD_MARGIN,
			raw_threshold);
}

float fog_edge_secondary_weight(vec2 uv, int q) {
	if (!has_terrain_edge_data || terrain_ecotone_width <= 0.0001) {
		return 0.0;
	}
	float edge_distance = visual_sample_edge_distance(fog_wrap_uv(uv)).r;
	float one_screen_pixel = max(fwidth(edge_distance), 1.0 / 255.0);
	float quality_scale;
// Web / mobile 的编译期档被 player_game 钉死在 LOW（换档 = 换 program = 换驱动缓存，见
// player_game._shader_quality_define_from_setting），但运行时画质由 PK_FOG_RUNTIME
// 放开到 q2。所以这两条路径上必须按**运行时 q**取边宽，而不是按 MOBILE_QUALITY_LOW 的 0.58：
// 否则高画质的迷雾边界只有中档的 58%，既细又毛糙。
#if defined(PK_FOG_RUNTIME)
	quality_scale = (q <= 0) ? 0.68 : ((q == 1) ? 0.82 : ((q == 2) ? 0.92 : 1.0));
#elif defined(MOBILE_QUALITY_LOW)
	quality_scale = 0.58;
#elif defined(MOBILE_QUALITY_MID)
	quality_scale = 0.82;
#elif defined(MOBILE_QUALITY_HIGH)
	quality_scale = 0.94;
#else
	quality_scale = (q <= 0) ? 0.68 : ((q == 1) ? 0.82 : ((q == 2) ? 0.92 : 1.0));
#endif
	float width = clamp(terrain_ecotone_width * quality_scale, one_screen_pixel, 0.98);
	float analytic = 0.5 * (1.0 - smoothstep(0.0, width, edge_distance));
	float aa = 0.5 * (1.0 - smoothstep(0.0, one_screen_pixel, edge_distance));
	return max(analytic, aa);
}
#endif // PK_CELL_FIELD（旧取 k 链路结束）

#include "res://shaders/include/fog_cloud_shape.gdshaderinc"

void vertex() {
	// VERTEX 此时是 mesh 局部坐标 = 世界坐标（quad 顶点按 world_bounds 写入）。
	// 与 data_overlay.gdshader 同约定：不走 canvas_item 默认 UV，避免
	// 「自定义 UV 是否传到 fragment 取决于 texture slot 绑定」这个坑。
	v_world = VERTEX;
}

void fragment() {
	// canvas_item 的 fragment 禁用 return（见 data_overlay.gdshader 注释），
	// 全部用嵌套 if 表达，默认完全透明。
	vec4 out_color = vec4(0.0);
#ifdef PK_CELL_FIELD
	// 调试档的载体（只存在于 PK_CELL_FIELD 变体；关掉时本文件逐字节不变）：
	//   fog_k_debug  = 显示用 k（三格锐化权重混合后的知识度）
	//   fog_hidden01 = 地形早退判定（0/1），即方案 §3.6 约束 3 的 `terrain_hidden`
	float fog_k_debug = 0.0;
	float fog_hidden01 = 0.0;
#endif

	if (fog_enabled && lut_dims.x >= 1.0) {
		int q = effective_fog_quality();
		vec2 wp = vec2(fog_wrap_world_x(v_world.x), v_world.y);
		float t = world_time * churn_speed;

#ifdef PK_CELL_FIELD
		// ═══════════════════════════════════════════════════════════════════════
		// [cell-field-overlays 2026-11-18 / O3] 场函数取 k（方案 §3.6 的三条约束）
		//
		// 这一步替换掉整条旧链路：`map_index` NEAREST 取格 → `enum_lut` 间接寻址 →
		// （移动档）Bayer 选格 / （桌面档）主副格双采样 mix。旧链路是**类别量进纹理**，
		// 格界只能落在 texel 边上，所以近景一定出现纹素台阶与孤立方块。
		//
		// 坐标契约（方案 §3.2，两条都不能省）：
		//   · `wp` 是**已回绕**的世界坐标（上行算出），进 pk_hex_tri 用；
		//   · AA 的屏幕导数必须取自**未回绕**的 `v_world`，否则跨经线那个 2×2 像素块
		//     里分数 axial 会跳 map_w，fwidth 爆掉 ⇒ 带宽被顶到 PK_FIELD_BAND_MAX，
		//     接缝处一条竖线（契约 §9.1）。
		//
		// ⚠ 迷雾清晰度为 50% 时（子视口 1/2 尺寸 +
		//   线性上采样）：这里 fwidth(v_world) 拿到的是**半分辨率像素**的世界跨度，
		//   所以 AA 带宽天然宽 2 倍。这一条是有意接受的（方案 §3.2 第 4 条），并且
		//   下面的 fog_hidden_margin 按同一份 fwidth 算 ⇒ 半分辨率下余量也自动翻倍，
		//   不会因为"AA 带窄于一个半分辨率像素"而在早退区边缘漏出 alpha 衰减。
		// ═══════════════════════════════════════════════════════════════════════

		// ── 约束 1：带宽。fog_field_band < √3/2（默认 0.6，比地形的 0.84 宽 = 更柔）；
		//    再与 AA 项取 max（近景时带宽至少要有一个屏幕像素那么宽，否则格界会闪）。
		float fog_aa = pk_hex_field_aa(v_world, hex_size, 1.0);
		float fog_band = clamp(max(fog_field_band, fog_aa), 1e-4, PK_FIELD_BAND_MAX);

		// ── 约束 2：扭曲按**长度** clamp，上限由带宽反算（不另设参数）。
		//    推导（方案 §3.6）：|∇gap| = 2/s，格心 gap = √3；扭曲把采样点从格心最多
		//    推开 A（世界单位）后，到格界的距离 ≥ (√3/2)s − A，对应 gap ≥ √3 − 2A/s。
		//    要让可见格的格心仍然是"纯主导格"（gap ≥ band），需要
		//        √3 − 2A/s ≥ band   ⇒   **A ≤ (√3/2 − band/2)·s**
		//    band = 0.6 时 A_max = 0.566·s。
		//
		//    ⚠ 这是**有意的视觉变化**：今天的 `edge_warp = 0.55` 是 hex **直径**倍数，
		//    单轴最大位移 = 0.55·2s = **1.1·s**，能把一个可见格的格心推进隔壁未探索
		//    格（这正是本任务要修掉的真问题：它没有任何保证，只是碰巧没被噪声撞到）。
		//    换成 A_max 之后迷雾边的"张牙舞爪"幅度会明显变小（约减半）—— 需要美术确认；
		//    若形态太乖，只能加**二级细节噪声**（只改 alpha 纹理），不能放宽 clamp。
		float fog_warp_amax = max(PK_HEX_SQRT3 * 0.5 - fog_band * 0.5, 0.0) * hex_size;
		PkHexGrid fog_grid = fog_hex_grid();
		// 可平铺低频扭曲（与天气共用 cell_field_overlays 里那一份；沿 x 周期 =
		// wrap_period_x，否则环绕接缝两侧会取到不同的格子，方案 §3.2 第 3 条）。
		vec2 fog_warp_raw = pk_soft_warp_tiled(
				wp, wrap_period_x, fog_warp_freq, fog_warp_amp * hex_size);
		vec2 fog_warp = fog_clamp_length(fog_warp_raw, fog_warp_amax);

		// 显示遮罩是连续量：锐化权重会把每格画成一块透明度平台。
		// 扰动在原始格心归零以保护格心；格间一直使用连续权重，避免局部锐化斑点。
		PkHexTri fog_tri = pk_overlay_fog_tri(wp, fog_grid, fog_warp);
		vec3 fog_w = pk_overlay_fog_weights(fog_tri, fog_grid, fog_band);
		float k = pk_overlay_fog_k(fog_w,
				fog_cell_k(fog_tri.c0), fog_cell_k(fog_tri.c1), fog_cell_k(fog_tri.c2));
		k = pk_overlay_fog_edge_k(k, fog_warp_raw, fog_warp_amp * hex_size);
		fog_k_debug = k;

		// ── 约束 3（强制不透明）：**在自己的 shader 内复算地形的早退判定**。
		//    与 world_map.gdshader:815-817 同形、同一张地形扭曲场、同一个
		//    PK_FIELD_BAND_MAX：
		//        fog_hidden = fog_early_out_enabled
		//                  && (fog_k(主导格) <= fog_early_out_k)
		//                  && (field_edge_gap >= PK_FIELD_BAND_MAX);
		//    唯一差别是 gap 阈值减掉 fog_hidden_margin —— 方向**永远安全**：
		//    迷雾判定为不透明的区域比地形早退区域大一圈。
		//
		//    fog_hidden_margin = 2 个**屏幕**像素对应的 gap
		//                      = (2/hex_size · world_per_px) · 2
		//                      = 4 · world_per_px / hex_size；
		//    world_per_px 直接取 fwidth(v_world)（本 shader 现有的唯一像素尺度来源，
		//    不新推硬编码常数）。它吸收两件事：① 半分辨率 + 线性上采样在边缘造成的
		//    1 个半分辨率像素的 alpha 衰减（半分辨率下 fwidth 翻倍 ⇒ margin 自动翻倍，
		//    见上面坐标契约那一段）；② 地形与迷雾两片 program 在判定边界上的浮点差异。
#ifndef PK_FOG_NO_TERRAIN_QUERY
		float fog_px_world = max(abs(fwidth(v_world.x)), abs(fwidth(v_world.y)));
		float fog_hidden_margin = 4.0 / max(hex_size, 1e-4) * fog_px_world;
		PkHexTri fog_ttri = pk_hex_tri(
				fog_wrap_world_pos(wp + pk_fog_terrain_warp_world(wp)), fog_grid);
		bool fog_terrain_hidden = fog_early_out_enabled
				&& (fog_tri_dom_k(fog_ttri) <= fog_early_out_k)
				&& (pk_hex_tri_gap(fog_ttri) >= PK_FIELD_BAND_MAX - fog_hidden_margin);
		fog_hidden01 = fog_terrain_hidden ? 1.0 : 0.0;
#endif
#else
		// 边界域扭曲：只影响"在哪儿取 k"，不影响 k 本身，因此 hex 轮廓被打散成
		// 有机曲线，而每格的语义状态仍然精确。
		// 同样要走可平铺噪声，否则环绕接缝上的迷雾边界会错开一截。
		vec2 warped = wp;
		if (edge_warp > 0.001) {
			vec2 ews = fog_tileable_scale(0.0042);
			vec2 np = wp * ews.x;
			float wa = cloud_grad_noise_tiled(np, ews.y);
			float wb = cloud_grad_noise_tiled(np + vec2(17.3, -9.1), ews.y);
			warped += (vec2(wa, wb) - vec2(0.5)) * 2.0 * edge_warp * hex_world_diameter;
		}

		vec2 uv = fog_wrap_uv((warped - world_origin) / world_size);
		int cid = fog_decode_cell_index(uv);
		// cid < 0 是极地外侧的烘焙 padding：不可交互，按未探索处理，顺带把
		// 人造边界藏进云里。
		float k = 0.0;
#if defined(PK_MOBILE_ANY) && !defined(PK_FOG_RUNTIME)
		// Mobile DitherUV selects one visual cell before the LUT lookup. This keeps
		// the old distant transition character without paying for two LUT samples.
		// 运行期档（web / 移动端高画质）不走这条路径：编译期档同样是 MOBILE_QUALITY_LOW，
		// 但运行时可以到 q2，用 Bayer 选格会在迷雾边缘留下 4–8px 的棋盘 dither
		// （高画质下非常显眼）。运行期档直接走下面的平滑双采样 mix，代价只是边缘像素
		// 多一次 LUT 采样。
		int visual_cid = cid;
		if (visual_cid >= 0) {
			float edge_w = fog_edge_secondary_weight(uv, q);
			if (edge_w > 0.0001) {
				int secondary_id = fog_decode_edge_secondary(uv);
				if (secondary_id >= 0
						&& fog_mobile_dither_uv_threshold(uv, warped) < edge_w) {
					visual_cid = secondary_id;
				}
			}
			k = texture(enum_lut, fog_cell_lut_uv(visual_cid)).a;
		}
#else
		k = (cid >= 0) ? texture(enum_lut, fog_cell_lut_uv(cid)).a : 0.0;
		if (cid >= 0) {
			float edge_w = fog_edge_secondary_weight(uv, q);
			if (edge_w > 0.0001) {
				int secondary_id = fog_decode_edge_secondary(uv);
				if (secondary_id >= 0) {
					float secondary_k = texture(enum_lut, fog_cell_lut_uv(secondary_id)).a;
					k = mix(k, secondary_k, edge_w);
				}
			}
		}
#endif
#endif // PK_CELL_FIELD

		float fog_amount = 1.0 - clamp(k, 0.0, 1.0);
#ifdef PK_CELL_FIELD
		// ── 约束 3 的前半：让"强制不透明"在结构上成立，而不是只靠下面的 mix ──────
		// 显示侧的 k 与地形侧的主导格 k 来自**两张不同的扭曲场**（显示用本 shader 的
		// 可平铺噪声，判早退用地形烘焙的边界扭曲场）。两者的位移差上界是
		// |fog_warp| + |terrain_warp| ≤ 0.566s + 0.9s（约束 2 的 A_max + 契约 §2 的
		// 编码范围）≈ 1.47s，比一个 hex 的内切圆半径还大 ⇒ **存在**这样的像素：地形
		// 侧主导格未探索（早退），显示侧却恰好落在隔壁可见格的正中央 ⇒ 显示 k = 1、
		// fog_amount = 0，下面的云体分支整段跳过。那时只改 alpha 是改不到的
		// （没有 alpha 可改），地形早退输出的常量色就会露出来。
		// 所以条件 3 拆成两半：
		//   ① 这里把 fog_amount 顶到 1（= 按"完全未探索"画云：thick 收敛到 1、
		//      云体满覆盖），分支必然执行，视觉上也是一块正常的厚云而不是黑块；
		//   ② 分支末尾再 mix 一次（幂等的兜底，防止将来有人调 thick 的阈值）。
		fog_amount = max(fog_amount, fog_hidden01);
#endif
#include "res://shaders/include/fog_fragment_cloud.gdshaderinc"
	}

#ifdef PK_CELL_FIELD
	// ── 调试档（只在 PK_CELL_FIELD 变体里存在；只给 tests/world/fog_cell_field_test.gd
	//    的不变量探针回读，生产路径 fog_debug_view 恒 0）────────────────────────
	// 三个视图都把值写进**颜色**并且 alpha 固定 1.0：canvas_item 是 blend_mix，
	// alpha=0 的片元会把 rgb 一起乘成 0（与"什么都没画"无法区分，契约 §9.3 的 view 22
	// 踩过同一个坑），所以回读必须走 rgb。
	if (fog_debug_view == 1) {
		// (a) 地形早退判定：R = terrain_hidden ? 1 : 0
		out_color = vec4(fog_hidden01, 0.0, 0.0, 1.0);
	} else if (fog_debug_view == 2) {
		// (b) **最终** alpha（已含约束 3 的强制不透明）：RGB 灰阶
		out_color = vec4(vec3(out_color.a), 1.0);
	} else if (fog_debug_view == 3) {
		// (c) 显示用 k（三格锐化权重混合后的知识度）：R
		out_color = vec4(fog_k_debug, 0.0, 0.0, 1.0);
	}
#endif

	COLOR = out_color;
}
