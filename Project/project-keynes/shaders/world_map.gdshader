shader_type canvas_item;
// [pk-web-texture-budget] 全部光照都是本 shader 自算（太阳向量/horizon shadow/GI），
// 项目从不使用引擎 Light2D；缺 unshaded 会让 Godot 额外编译"受光"路径，隐式多占
// 1-2 个 fragment 纹理单元（灯光贴图/阴影图集 sampler），在 Compatibility(GLES3/
// WebGL2) 16 单元预算下是纯浪费。其余同类全屏 canvas shader
// （data_overlay/fog_of_war/country_border/hex_edge_overlay）都已带 unshaded，
// 这里补齐。
#if defined(PK_BAKE_LAND_COLOR) || defined(PK_BAKE_LAND_NORMAL)
render_mode blend_disabled, unshaded;
#else
render_mode blend_mix, unshaded;
#endif
#ifdef PK_READ_LAND_BASE
uniform sampler2D land_base_color : filter_nearest, repeat_disable;
uniform sampler2D land_base_normal : filter_nearest, repeat_disable;
#endif

// ═══════════════════════════════════════════════════════════════════════════
// [land-water-split 2026-11-02] 陆地 / 水面双 program 的宏归一（**只做别名，不动前缀**）。
// Web 的两套既有前缀 `PK_WEB_LAND_ONLY` / `PK_WEB_WATER_ONLY` 是字节契约
// （HexRenderer.WORLD_MAP_WEB_PREFIX* / WATER_WEB_HIGH_PREFIX / terrain_shader_variant_test
// 逐字节守着），绝不能改；桌面 / 移动（Vulkan / GLES3 / Mobile）新增
// `PK_LAND_ONLY` / `PK_WATER_ONLY`。这里把 Web 宏在 shader 内部归一到通用名，
// 让下方分支只认一种写法：Web 变体的**行为**逐字不变，只是统一了判定条件。
// ═══════════════════════════════════════════════════════════════════════════
#if defined(PK_WEB_LAND_ONLY) && !defined(PK_LAND_ONLY)
#define PK_LAND_ONLY
#endif
#if defined(PK_WEB_WATER_ONLY) && !defined(PK_WATER_ONLY)
#define PK_WATER_ONLY
#endif
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field-web 2026-11-18] `PK_WEB_WORLD_MIN` 与 `PK_CELL_FIELD` **正交，不互斥**。
// world-min 的唯一作用是「把水面着色源从这个 fragment 里摘掉」（水面由
// shaders/world_water_web.gdshader 的第二 pass 重画），从而避开 ANGLE/FXC 的
// 「两个着色源联合优化」悬崖（20.3 s 实测见本文件下方 PK_WEB_WORLD_MIN 注释块，与
// docs/web-export.md 的 Web 首编实测同源）。它**不是**「不渲染陆地」，也不含任何
// 逐像素索引图消费者：world_map_web_min.gdshaderinc 只补 cell_lut_uv /
// WATER_WRAP_TAU / water_wrap_* 三个叶子，不引用 enum_lut / dyn_lut / map_index。
// ⇒ 上一版那条 `#if defined(PK_CELL_FIELD) && defined(PK_WEB_WORLD_MIN)` →
// `#undef PK_CELL_FIELD` 的归一化已删除：它会静默把 Web LOW 的场函数关掉，
// 让陆地走 legacy 索引图、水面走场函数，海岸判定两套来源 ⇒ 必然错开 1~2 px
// （方案 §3.7「陆地与水面由同一个判断口决定」）。现在 world-min 变体同样可以
// 带 PK_CELL_FIELD，两边的 is_water 同源。
// ═══════════════════════════════════════════════════════════════════════════

// world_map.gdshader v9.atlas — 高分辨率地理仿真渲染（结构重构版 2026-05-19）
// [sky-sh-ambient 2026-06-29] 引入 L1 球谐天光（earth_daylight.earth_sky_sh）；本注释用于
// 触发顶层 shader 重编译，避免编辑 .gdshaderinc 后 Godot 残留旧编译缓存导致 "earth_sky_sh 未找到"。
// [sky-sh-water 2026-06-29b] 水面菲涅尔天空反射改吃方向化球谐天色（按波浪法线取样）；再次 touch。
// [sky-sh-water 2026-06-29c] 新增波浪 hillshade（water_wave_shade_strength）让无直射水域也见波浪；touch。
// [water-detail-sss 2026-06-29d] 新增高频细节法线(q>=2) + 廉价水体 SSS(q>=1)；touch 触发重编。
// [water-wave-readability 2026-06-29e] hillshade 默认强度 0.35→1.8 + 细节法线降频(可调 tiling) +
//   低频噪声复用(macro_lf/macro_vlf 省 2 个 fbm)；touch 触发重编。
// [water-detail-break-tiling 2026-06-29f] 细节法线叠中频 domain-warp 破 tiling(water_detail_normal_warp)；touch。
// [wave-patchiness 2026-06-29g] 波浪强度包络参数化(water_wave_patch_strength) + 细节法线增幅/放宽上限；touch。
// [detail-gate-fix 2026-06-29h] 修复细节法线门控 bug(wave_q 被钳到1→quality>=2 永不成立)，改用全局 visual_quality 判定(保持>=2 高画质专属)；touch。
// [sss-fix+base-normal 2026-06-29i] 修复 SSS 标定(pow(facing,3)×wave_act 压到 0) + 新增 water_base_normal_strength(宏观涌浪强度可调)；touch。
// [range-widen 2026-06-29j] 放宽水面调参 hint_range 上限 + patch 公式 lo clamp(防 patch>1 翻转)；touch。
// [params-bake 2026-06-29k] 固化用户实调水面参数默认值(shade1.5/patch1.23/base1.21/detail0.75/scale0.57/sss0.22)；touch。
// [base+patch tilling 2026-06-29l] 新增 water_base_normal_scale / water_wave_patch_scale 控制宏观涌浪与浪带的瓦片密度；touch。
// [params-bake 2026-06-29m] 固化水面参数(patch 1.58/scale2.69、base1.17/scale0.93、detailScale0.48、sss0.18)；touch。
// [terrain-gi 2026-07-31] 同一张 8 方向 horizon 图派生天空可见度(AO)、bent normal 与单次弹射，
//   环境光改按 bent normal 定向、按 sky visibility 遮蔽；新增 gi_occluder tile 与 bounce_lut；touch。
// [terrain-gi-tuning 2026-07-31b] 首轮实机配平：新增 gi_ao_floor / gi_ao_smoothing，
//   gi_bent_strength 与 gi_normal_floor 下调（暗部死黑 + 高频碎化）；新 uniform 必须 touch。
// [micro-soften+river-hierarchy 2026-07-31c] 微表面/细节法线全面软化 + 河宽幂律对比拉大；touch。
// [normal-soften+albedo 2026-07-31d] residual↓、细节法线改宽差分+zoom门控、高画质恢复 per-biome 程序纹理；touch。
// [terrain-material-tiles 2026-08-01] 四层材质族 Texture2DArray（uniforms/terrain_surface_detail/land_pipeline
//   三处 include 接入）；touch 触发重编，否则 include 改动命中旧编译缓存、贴图路径静默走程序化回退。
// [terrain-material-tiles 2026-08-01b] debug_view=7 材质门禁可视化（GM 面板可切）；touch。
// [terrain-material-tiles 2026-08-01c] 材质强度默认值提升（albedo 0.6 / normal 0.15）；touch。
// [terrain-material-tiles 2026-08-01d] world_size 128→384 修 mipmap 预滤波；GPT-image-2 风格化贴图换源；touch。
// [eco-lut-retire 2026-08-06] 主地形移除 eco_lut，Compatibility 预算槽让给 terrain_material_tex；touch。
// [water-edge-continuous 2026-08-02] 水体静态类别/水深改用距离场连续混合；LOW 编译期旁路。
// [river-normal-separation 2026-08-03] 河心改用水平面基准的独立水波法线，河岸才与地形法线过渡；touch。
// [baked-surface 2026-11-01] 两端删除"运行期高度差分法线"：hillshade_tod 只剩唯一入口
//   terrain_baked_normal（法线/细节坡度全部来自生成期烘焙纹理）。Web LOW 由
//   PK_WEB_HORIZON 真正执行 horizon 解码；上一轮的 Web 运行期细节法线开关整体删除。
// [macro-relief 2026-11-06] 提升烘焙粗法线、horizon 遮蔽与 GI bent normal 的默认权重；
//   保留生成期法线/地形 horizon 数据源不变，仅增强运行期宏观起伏的可读性。
// [packed-surface 2026-11-01 / 方案 A] 非 tiled 的 normal+relief 合并成 1 个 2 层
//   sampler2DArray `terrain_surface_tex`（layer0=normal、layer1=relief），Web 地形程序
//   腾出 1 槽恢复 noise_tex（common_noise 回到 1 次纹理采样的预烘包快路径）。Web 陆地
//   程序最终 8 槽 = height/map_index/enum/dyn/material/terrain_surface_tex/
//   terrain_horizon_tex/noise_tex。touch 触发重编。
// [p0-insolation-dead 2026-11-01] climate_season.season_offset_unified 无条件 return 0.0（on-map dyn_valid==1 ⇒ current_temp==dyn_temp，积分是死代码；padding 被 Fog 盖住，与 web 变体原行为一致）；touch 触发重编。
// [surface-array-edge 2026-11-02] 同一个 array 扩到 **6 层**：layer4 = edge_distance
//   （R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比）、layer5 = edge_neighbor RG
//   （次生 cell id 16-bit；B = water_depth R，A 预留）。数据本来就在 native tile bundle 里
//   ⇒ 扩层零新增烘焙；陆地与两个水面程序共用同一 sampler ⇒ 恢复次生生态过渡 / crease /
//   海岸 halo / 次生水格时**一个材质槽都不新增**（Web 陆地仍 8 槽、HIGH 水面 7→8、
//   compact 水面 5→6）。touch 触发重编。
// ═══════════════════════════════════════════════════════════════════════════
// 本文件 2026-05-19 由 2299 行单文件拆分为 1 个主 shader + 多个 .gdshaderinc：
//   uniforms / common_noise / height / climate_season / biome_color / vegetation /
//   weather_front / snow_cover / biome_detail / hillshade_tod / water / land_pipeline /
//   water_pipeline / global_adjustments  —— 详见 shaders/include/。
//
// 主文件仅保留：shader_type、render_mode、按拓扑顺序的 #include、vertex()、
// fragment()（SETUP 解码 → LAND/SEA 分支调度 → GLOBAL 输出）。具体算法均下沉到 include。
// 通道语义快速参考（详细请见 uniforms.gdshaderinc）：
//   height_tex (RGBA8 LINEAR)      RG=海拔 (R*256+G)/257；B=river flow（原独立 flow_tex）
//   terrain_normal_tex (RGBA8)     2D：RG=粗法线 xy；BA=近景高度细节坡度（encode_slope）。
//                                  仅非 tiled 的**其它层**（植被/建筑/资源/贸易）消费。
//   terrain_surface_tex (6×RGBA8)  非 tiled 地形 / 水面程序共用的打包数组：
//                                  layer0=normal（同上布局）、layer1=relief（RG=粗段/BA=细段）、
//                                  layer2=detail、layer3=occluder ids、
//                                  layer4=edge_distance（R 距离/G crease/BA 海岸占比）、
//                                  layer5=edge_neighbor（RG 次生 id；B 水深）
//   terrain_horizon_tex (RGBA8)    8 方向 horizon angle，high/low nibble packed
//   noise_tex (RGBA8)              预烘噪声包（R raw value；GBA=fbm 2/3/4 octave 预积分）
//   map_index_atlas (RGBA8 NEAREST) R=biome  GB=cell.index
//   enum/dyn LUT:                  per-cell enum / dynamic visual state（eco_lut 已退役）
//   terrain_material_tex           四层材质族 Texture2DArray（albedo/rough/normal 打包）
// ═══════════════════════════════════════════════════════════════════════════

// ─── Include 拓扑顺序（不可随意调整） ─────────────────────────────────────
//   uniforms       叶子，零依赖，必须最先。
//   material_constants 叶子（仅依赖 uniforms 中的 visual_quality 等）；集中常量、F0、特性开关。
//   visual_tile_sampling 依赖 VT_USE_* 采样预算；声明 height/map_index/normal/relief/
//                  horizon/edge/water_depth/detail/gi 的 sampler 与解码 helper。
//   common_noise   全部变体 include；统一走 noise_tex 预烘包快路径（1 次纹理采样）。
//                  [packed-surface 2026-11-01] Web 地形程序恢复绑定 noise_tex。
//   height         叶子，依赖 uniforms.height_tex / hm_resolution。
//   climate_season 叶子，依赖 uniforms.axial_tilt_rad / season_temp_amp / insolation 组。
//   biome_color    叶子，依赖 uniforms.color_* / deep_ocean_* / B_* / ocean_current_enabled。
//   vegetation     依赖 common_noise.fbm + uniforms.V_* / vegetation_season_lut。
//   weather_front  依赖 common_noise.fbm + uniforms.MAX_WEATHER_FRONTS / WT_*（BLIZZARD）。

//   snow_cover     依赖 common_noise.fbm + height.decode_height_rg8 + weather_front.compute_extreme_weather_mask。
//   biome_detail   依赖 common_noise.fbm + common_noise.voronoi_cell + uniforms.B_*。
//   earth_daylight 叶子，仅依赖 uniforms.season_phase/day_phase/axial_tilt_rad。
//   植被气候物候权重内联于 land_pipeline，避免 include 热重载缓存版本错配：
//                  地球式昼夜（晨昏线）单一真源，被 hillshade_tod/brdf/water 统一调用。
//   hillshade_tod  依赖 visual_tile_sampling（烘焙 normal/relief）+ uniforms.hillshade_* /
//                  terrain_erosion_* / camera_zoom；唯一法线入口 terrain_baked_normal。
//   water          依赖 common_noise.* + uniforms.map_index_atlas / B_LAKE/B_REEF/B_KELP/B_SEA_ICE。
//   surface_params 半 PBR Stylized 参数结构（base_color/normal/roughness/metallic/ao/emission/alpha）。
//   tonemap        依赖 material_constants：srgb↔linear、ACES filmic、Reinhard legacy。
//   shore_common   依赖 uniforms + material_constants：sample_shore_neighborhood / compute_shore_halo。
//   terrain_horizon 所有变体统一 include；有 VT_USE_HORIZON 时解码 8 方向 horizon angle
//                  （一次 4-tap 采样同时给出 direct shadow、天空可见度(AO) 与 bent normal），
//                  没有采样槽的程序（Web 水面）内部退化为中性叶子。
//   brdf           依赖 surface_params + material_constants + tonemap + terrain_horizon
//                  + cell_indirect（弹射项要按遮挡源 cell id 查 bounce_lut）：
//                  Cook-Torrance / Blinn-Phong fallback。
//   land/water/global pipelines  最后 include，封装 fragment 的陆地/水面/全局调度算法。
//                  拆分 program 时两边互补：陆地 program 不 include water_pipeline，
//                  水面 program 不 include land_pipeline（PK_WEB_LAND_ONLY /
//                  PK_WEB_WATER_ONLY 与桌面 PK_LAND_ONLY / PK_WATER_ONLY 同义）。

// ─────────────────────────────────────────────────────────────────────────
#include "res://shaders/include/shader_quality.gdshaderinc"
#include "res://shaders/include/uniforms.gdshaderinc"
// ─── VT_USE_* 采样预算（决定 visual_tile_sampling 声明哪些 sampler）──────────
// [baked-surface 2026-11-01 / packed-surface 2026-11-01 / web-high-features 2026-11-01 /
//  surface-array-edge 2026-11-02]
// 法线/细节坡度/edge 静态场两端都只来自生成期烘焙纹理，非 tiled 的**固定 6 层**
// sampler2DArray `terrain_surface_tex`（normal/relief/detail/occluder/edge_distance/
// edge_neighbor）：
//   桌面 tiled：normal + relief 仍是两个数组（relief 是 relief_scale 倍分辨率，
//     不能同 array）+ water_depth + terrain_detail + edge_* + horizon + gi_occluder。
//   桌面 legacy（非 tiled）：6 层打包进 terrain_surface_tex，
//     保留 water_depth / horizon / gi_occluder / micro / bounce_lut。
//   Web 地形程序（LOW + HIGH land，PK_WEB_WATER_ONLY 之外）恰好 8 个材质槽 ——
//     height_tex / map_index_atlas / enum_lut / dyn_lut / terrain_material_tex /
//     terrain_surface_tex / terrain_horizon_tex / noise_tex。
//     方案 B：detail 读 surface array layer2；micro 读 material array 第 5 层；
//     GI 弹射读 surface array layer3（不再需要 bounce_lut）。都不新增 sampler。
//     [2026-11-02] 次生生态过渡（secondary biome 混合 + DitherUV 远景过渡）、沟谷 crease、
//     海岸 halo 占比改读 layer4/layer5 —— 同样是**已有槽**，8 槽预算不变。
//     [cell-field-web 2026-11-18] 启用场函数后旧三槽（map_index / enum / dyn）从声明里
//     删掉、cell_table 补 1 ⇒ **6 槽**：height / horizon / noise / material /
//     terrain_surface / cell_table。逐变体数字以
//     `tests/world/terrain_shader_variant_test.gd` 的 sampler 普查为准（等值断言）。
//   Web/Compatibility 水面（PK_WEB_WATER_ONLY，或桌面 Compatibility 的**非 tiled**
//     完整主 pass）：water_depth 槽打开（HIGH 水面 7→8 槽，新增的 1 槽就是 surface array；
//     桌面 Compatibility 主 pass 8 槽）。
//   Web land-only 程序不拿 water_depth（预算留给上面的 8 槽）；桌面 Compatibility tiled
//     变体保持方案 A 的 8 槽（tiled 的 water_depth/detail 是数组，会超 GLES3 预算）。
//   桌面 Compatibility（只有 PK_WEB_TEXTURE_BUDGET、没有 PK_WEB_HORIZON）：horizon 槽
//     不开（VT_USE_HORIZON 不定义，由 terrain_horizon 中性叶子兜底）。
#define VT_USE_HEIGHT
// [cell-field-web 2026-11-18] 预算变体（PK_WEB_TEXTURE_BUDGET）启用场函数后，旧三槽必须
// 从**声明**里删掉（见 uniforms.gdshaderinc 的 PK_CELL_FIELD_NO_LEGACY_LUT）：Web 陆地
// program 已用满 8 个 sampler，cell_table 会是第 9 个，第 9 张起每帧被引擎内建白纹覆盖，
// **不报错**、画面只是错的（方案 §3.2 / §3.4）。所以 VT_USE_MAP_INDEX 在该组合下不定义
// ⇒ visual_sample_map_index() / map_index_atlas 的任何残留引用直接变成编译错误，漏改
// 不可能靠"人眼 grep"溜过去。
// 开关本身由 uniforms 的宏表达（那里已经算好了 PK_CELL_FIELD && PK_WEB_TEXTURE_BUDGET），
// 本文件**不重复**加第二个宏。
#ifndef PK_CELL_FIELD_NO_LEGACY_LUT
#define VT_USE_MAP_INDEX
#endif
#define VT_USE_FLOW
// [surface-array-edge 2026-11-02] 非 tiled 的静态地表打包成 **6 层** sampler2DArray
// `terrain_surface_tex`（normal/relief/detail/occluder/edge_distance/edge_neighbor）。
// 陆地程序与两个水面程序声明的是同一个 sampler，VT_USE_* 只决定读哪一层 ⇒
// 恢复次生生态过渡 / crease / 海岸占比 / 次生水格时**一个材质槽都不新增**。
#if !defined(MAP_VISUAL_TILED)
#define VT_USE_TERRAIN_SURFACE_ARRAY
#endif
#if defined(PK_WEB_TEXTURE_BUDGET)
#ifndef PK_WEB_WATER_ONLY
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_TERRAIN_RELIEF
// [B] 非 tiled detail 走 terrain_surface_tex layer2；tiled budget（桌面 Compatibility
// tiled 诊断路径）保持方案 A 的 8 槽，不新增 detail/water_depth 数组采样器。
// water_depth 只给"同程序里真的画水"的变体：桌面 Compatibility 完整主 pass（无 LAND_ONLY）；
// Web land-only 程序不拿（保持 8 槽）。
#if !defined(MAP_VISUAL_TILED)
#define VT_USE_TERRAIN_DETAIL
#if !defined(PK_WEB_LAND_ONLY)
#define VT_USE_WATER_DEPTH
#endif
// [surface-array-edge 2026-11-02] 次生生态过渡（secondary biome 混合 + DitherUV 远景过渡）、
// 沟谷 crease、海岸 halo 占比全部改读 surface array 的 layer4/layer5。
// 数据本来就在同一个 native tile bundle 里，所以 8 槽预算不变、烘焙时间不变。
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#endif
#if defined(PK_WEB_HORIZON)
#define VT_USE_HORIZON
#endif
#endif
// [B] HIGH 水面独立程序（WATER_ONLY，非 tiled）需要烘焙水深；land-only 程序不拿。
// [surface-array-edge 2026-11-02] 水面也吃同一个 surface array（7→8 槽）：layer4/5 恢复
// edge_mix / shore_frac / 次生水格，水色方块与浅滩因此变连续。不声明 normal/relief/horizon。
#if defined(PK_WEB_WATER_ONLY)
#define VT_USE_WATER_DEPTH
#if !defined(MAP_VISUAL_TILED)
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#endif
#endif
#else
#define VT_USE_TERRAIN_NORMAL
#define VT_USE_TERRAIN_RELIEF
#define VT_USE_WATER_DEPTH
#define VT_USE_TERRAIN_DETAIL
#define VT_USE_EDGE_NEIGHBOR
#define VT_USE_EDGE_DISTANCE
#define VT_USE_HORIZON
// [pk-web-texture-budget] GI 单次弹射（gi_occluder tile + bounce_lut）只在桌面
// 启用；Compatibility 下裁掉——sky visibility/direct shadow 等其余 horizon 派生量
// 不受影响，只丢弹射色溢出这一项纯装饰性增强。
#define VT_USE_GI_OCCLUDER
#endif
// [web-high-features 2026-11-01 / 方案 B] 非 tiled Web/Compatibility 的 HIGH 地表特性包：
// 全部复用已有 sampler，不增加材质槽：
//   PK_TERRAIN_MICRO_ARRAY   — micro 走共享 terrain_material_tex 第 5 层（index 4）；
//   PK_TERRAIN_PACKED_BOUNCE — GI 弹射 occluder ids 走 terrain_surface_tex 第 4 层
//                              （index 3），不再采样 bounce_lut（该变体也没声明它）。
#if defined(PK_WEB_TEXTURE_BUDGET) && !defined(PK_WEB_WATER_ONLY) && !defined(PK_WATER_ONLY) && !defined(MAP_VISUAL_TILED)
#define PK_TERRAIN_MICRO_ARRAY
#define PK_TERRAIN_PACKED_BOUNCE
#endif
// [cell-field 2026-11-18] 解析格界（docs/plans/terrain-hex-mesh-implementation-plan.md）：
// 像素「属于哪几格、各占多少」不再从逐像素索引图读，而由「世界坐标 + 一张连续扭曲场」
// 解析算出（对偶三角 + 重心权重）。开关 PK_CELL_FIELD，**默认关**；关闭时下面两段 do
// 都不定义 ⇒ 预处理产物与今日逐字节一致（截图 diff = 0 是验收项）。
//   VT_USE_CELL_TABLE    —— per-cell 三层表（class/state/aux），一个 sampler 顶掉
//                           map_index_atlas + enum_lut + dyn_lut 三个，净省 2 槽；
//   VT_USE_BOUNDARY_WARP —— 扭曲场（非 tiled 读 terrain_surface_tex layer6）。
// [cell-field-web 2026-11-18] world-min 变体**也要**这两个开关：它与场函数正交
// （只摘掉水面着色源），见文件头那条注释。之前的 `#ifndef PK_WEB_WORLD_MIN`
// 会把 Web LOW 的场函数关掉，现在已删除。
#ifdef PK_CELL_FIELD
#define VT_USE_CELL_TABLE
#if defined(MAP_VISUAL_TILED) || defined(VT_USE_TERRAIN_SURFACE_ARRAY)
#define VT_USE_BOUNDARY_WARP
#endif
#endif
#include "res://shaders/include/visual_tile_sampling.gdshaderinc"
#include "res://shaders/include/earth_daylight.gdshaderinc"
#include "res://shaders/include/material_constants.gdshaderinc"
#ifdef PK_WEB_WORLD_MIN
#include "res://shaders/include/world_map_web_min.gdshaderinc"
#else
#include "res://shaders/include/cell_indirect.gdshaderinc"
#endif
// [baked-surface 2026-11-01] common_noise 所有变体都 include：统一走 noise_tex 预烘包。
// [packed-surface 2026-11-01] 非 tiled 的 normal+relief 合并进 1 个 array 后腾出采样槽，
// noise_tex 在 Web 地形程序恢复绑定，上一轮的程序化噪声 fallback 已整体删除。
#include "res://shaders/include/common_noise.gdshaderinc"
#include "res://shaders/include/height.gdshaderinc"
#include "res://shaders/include/climate_season.gdshaderinc"
#include "res://shaders/include/biome_color.gdshaderinc"
#include "res://shaders/include/vegetation.gdshaderinc"
#ifndef PK_WEB_WORLD_MIN
#include "res://shaders/include/weather_front.gdshaderinc"
#endif
#include "res://shaders/include/snow_cover.gdshaderinc"
#include "res://shaders/include/biome_detail.gdshaderinc"
#include "res://shaders/include/hillshade_tod.gdshaderinc"
#if !defined(PK_WEB_WORLD_MIN) && !defined(PK_WEB_LAND_ONLY)
#include "res://shaders/include/water.gdshaderinc"
#endif
#include "res://shaders/include/surface_params.gdshaderinc"
#include "res://shaders/include/terrain_surface_detail.gdshaderinc"
// [cell-field 2026-11-18] 场函数必须在这之后 include：
//   依赖 terrain_surface_detail 的 terrain_edge_screen_width_px() 与
//   terrain_static_biome_is_water()；依赖 visual_tile_sampling 的 cell_table /
//   visual_sample_boundary_warp。land/water pipeline 都在它之后，故可自由调用。
// 关闭 PK_CELL_FIELD 时整段不 include（文件不存在于预处理产物里）。
// [cell-field-web 2026-11-18] 不再排除 world-min：那个变体也要场函数（见文件头）。
#ifdef PK_CELL_FIELD
#include "res://shaders/include/hex_cell_field.gdshaderinc"
#include "res://shaders/include/terrain_cell_field_detail.gdshaderinc"
#endif
#include "res://shaders/include/tonemap.gdshaderinc"
#ifndef PK_WEB_WORLD_MIN
#include "res://shaders/include/shore_common.gdshaderinc"
#endif
// [baked-surface 2026-11-01] horizon 所有变体统一 include：Web 全档位生成期烘焙，
// PK_WEB_HORIZON 覆盖 MOBILE_QUALITY_LOW 的早退；没有 horizon 采样槽的程序
// （Web 水面）由 include 内部的中性叶子兜底。terrain_horizon_neutral 不再使用。
#include "res://shaders/include/terrain_horizon.gdshaderinc"
#include "res://shaders/include/brdf.gdshaderinc"
#include "res://shaders/include/cloud_shadow.gdshaderinc"
// [land-water-split 2026-11-02] 水面 program 不 include 陆地管线（与陆地 program
// 不 include 水面管线对称）。Web HIGH 水面程序（PK_WEB_WATER_ONLY）经上面的别名也是
// PK_WATER_ONLY，因此同样只编自己那条着色来源；fragment 里陆地分支退化为占位常量，
// 不会再引用 render_land_pipeline。
#if !defined(PK_WATER_ONLY)
#include "res://shaders/include/land_pipeline.gdshaderinc"
#endif
#if !defined(PK_WEB_WORLD_MIN) && !defined(PK_WEB_LAND_ONLY) && !defined(PK_LAND_ONLY)
#include "res://shaders/include/water_pipeline.gdshaderinc"
#endif

#include "res://shaders/include/global_adjustments.gdshaderinc"
#include "res://shaders/include/fog_memory.gdshaderinc"


#ifdef PK_CELL_FIELD
// ═══════════════════════════════════════════════════════════════════════════
// [cell-field 2026-11-18] PK_CELL_FIELD 下 SETUP 专用的小 helper。
// 只做 ALU、只复用 hex_cell_field 的公开函数，不新增任何采样。
// 关闭开关时整段被预处理剔除 ⇒ 预处理产物与今日逐字节一致。
// （公共场函数与查表 helper 属于 lead 独占的 hex_cell_field.gdshaderinc，这里只放
//  world_map SETUP 自己的三格混合 / 边界判定 / 岸线占比，避免公共文件继续长大。）
// ═══════════════════════════════════════════════════════════════════════════

// 防出洞的岸带宽度（gap 单位，与 pk_cell_field_edge_gap / edge_distance 同一单位）。
// 0.02 = 0.01·hex_size ≈ 0.22 wu，远小于 zoom 6 下的 1 像素；用法见 SETUP 的 is_water。
const float PK_FIELD_SHORE_EPS = 0.02;

#include "res://shaders/include/world_map_cell_helpers.gdshaderinc"

#endif // PK_CELL_FIELD


#ifdef PK_WEB_WORLD_MIN
// ⚠ 本注释块整体包在 PK_WEB_WORLD_MIN 里，目的就是让**桌面变体的预处理产物逐字节
// 不变**（这一点由 tmp/next/_probe 的 expand-diff 守着）。
//
// [web-water-pass] 水面已从本 fragment **整段移出**，见
//   shaders/world_water_web.gdshader（第二 pass）+ hex_renderer._sync_water_quad()。
// 上一轮在这里留过一个"紧凑水面"函数（biome 底色 + 深度 + 岸线 + 海冰，无 fbm /
// 无循环）作为缓解手段，实测证明它治不好，反而更容易被误认为"已经优化过了"：
//   只留陆地（水面=常量）              2 473 ms
//   只留水面（陆地=常量）              1 089 ms
//   两者都在                           20 291 ms
//   水面改紧凑 if/else（≈25 行）       17 264 ms
//   水面改无分支三元/mix（≈30 行）     18 060 ms
// 结论：悬崖与第二个着色来源的**行数无关**（25 行 = 1000 行），是 ANGLE/FXC 的寄存器
// 压力型非线性。唯一有效的做法是让这个 fragment 只剩一个着色来源。所以
// PK_WEB_WORLD_MIN 下水面像素输出一个常量占位色，由 world_water_web.gdshader 整屏
// 覆盖重画。占位色刻意选成"暗海蓝"：万一第二 pass 因故没画（档位被裁 / 编译失败），
// 屏幕上是一片偏平的深蓝，而不是一眼假的品红。
#endif

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// ═══════════════════════════════════════════════════════════════════════
	// SETUP 0：Atlas 采样 / 通道解码
	// ───────────────────────────────────────────────────────────────────────
	// 动态视觉状态统一走 cell-index + LUT；旧 per-pixel dynamic/smooth/ecology atlas
	// 以及 scalar/vector atlas 已退役。
	// ═══════════════════════════════════════════════════════════════════════
	vec2 wp = wrap_world_pos(v_world);
	vec2 uv = wrap_map_uv((v_world - world_origin) / world_size);
	// [cell-field 2026-11-18] 解析格界：整条 fragment 只算这一次。
	//   1 次 warp 纹理采样 + 一段纯 ALU + 3 次 texelFetch（per-cell 小表，全命中缓存）。
	// 结果以 `HexCellField + 三格 class` 往下传给 land / water pipeline 与静态材质，
	// 下游不再重算（重算等于把 §3.8 的预算翻倍）。
#ifdef PK_CELL_FIELD
	HexCellField cell_field = pk_hex_cell_field_default(v_world);
	vec4 cell_e0 = vec4(0.0);
	vec4 cell_e1 = vec4(0.0);
	vec4 cell_e2 = vec4(0.0);
	pk_cell_field_classes(cell_field, cell_e0, cell_e1, cell_e2);
#endif
	// v10.noise-cache：本像素只采样一次全局噪声包，供后续"随机抖动/强度扰动"
	// 类视觉细节复用。真正需要独立频率/方向/时间推进的结构噪声（水纹、河口等）
	// 仍走专用 fbm，避免所有效果同形同相。
	//
	// pixel_rand4 语义（半 PBR 重构后约定）：
	//   .r = phase / jitter（结构噪声相位扰动）
	//   .g = amplitude / paper grain
	//   .b = equator-band / paper grain（与 global_adjustments 共享）
	//   .a = equator mix / dissolve overlay
	// 这 4 个分量在 v10.noise-pack 中是 raw value + fbm-2/3/4-octave 的预积分，
	// 谱形不同但仍是同坐标采样，对"独立 RV"的要求是软约束。下游若需严格独立
	// 随机数，应另调 derive_independent_noise4(wp + offset)。
	// [packed-surface 2026-11-01] 非 tiled 的 normal+relief 合并成 1 个 2 层 array 后，
	// Web 地形程序恢复 noise_tex 绑定：pixel_noise 重新走预烘噪声包（1 次纹理采样），
	// MOBILE_QUALITY_LOW 仍按 PK_SKIP_PIXEL_NOISE 退化成中性灰（移动端省采样）。
	// 60 FPS 优化（2026-06-18）：scalar/vector 和 per-pixel dynamic atlas 已退役。
#ifdef PK_SKIP_PIXEL_NOISE
	vec4 pixel_noise = vec4(0.5);  // 中性灰值，不调 fbm 也不影响
#else
	vec4 pixel_noise = texture(noise_tex, (wp * 0.071 + vec2(19.0, -23.0)) / NOISE_TEX_SCALE);
	if ((pixel_noise.g + pixel_noise.b) <= 0.0001 && pixel_noise.a >= 0.98) {
		pixel_noise = derive_independent_noise4(wp * 0.071 + vec2(19.0, -23.0));
	}
#endif

	// height 一次采样同时给出：RG=16-bit 高程，B=天然河流 SDF，A=运河 SDF。
	vec4 height_px = visual_sample_height(uv);
	float elev = (height_px.r * 256.0 + height_px.g) / 257.0;

	vec4 scals = vec4(0.0);  // scalar_atlas 退役：moist/lat 由 LUT/uv 重建。
	// [river-render-restore / height-flow-pack] flow：Legacy/Tiled 均自 height*.B。
	// land/water pipeline 读 scals.g 画河网。低画质仍要保留静态河网；昂贵的河流动效/
	// 坡向流纹已在 land_pipeline 里按质量档裁掉。
	// 降级必须走 has_flow_tex 而不是"没绑就采样得 0"：GLES3/WebGL2 下解析不到的
	// sampler2D 兜底成 4×4 白纹理，flow 会恒为 1，整片陆地被混上河水色。
	float flow_raw = height_px.b;
	scals.g = has_flow_tex ? flow_raw : 0.0;
	scals.b = height_px.a;
	// edge_distance 一次采样：scals.r = 格界距离（生态过渡 / 材质边缘），
	// scals.a = 烘焙沟谷折痕，shore_frac = 8 邻域水 / 湖占比（海岸 halo）。
	// 下游一律从这里取，不再重复采样。
	// 采样点统一提到分支之前：`terrain_shader_variant_test.gd` 用一次调用点的
	// 出现次数守着"整条 fragment 只采一次 edge_distance"（所以这里连注释都别再写
	// 那个带括号的调用形式）。PK_CELL_FIELD 下仍然要这一次采样（只为 .g 的沟谷 crease）。
	vec2 shore_frac = vec2(0.0);
#ifdef VT_USE_EDGE_DISTANCE
	vec4 edge_px = visual_sample_edge_distance(uv);
#endif
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 三个量拆成两条来源（方案 §3.7）：
	//   scals.r    ← 解析格距 pk_cell_field_edge_gap()。单位与今天的 edge_distance.R
	//                相同（normalized_hex_center_gap），但连续、无纹素台阶；下游
	//                terrain_edge_secondary_weight_d() / 静态材质边缘公式一个字都不用改。
	//   shore_frac ← 解析：三格里水格 / 湖格按 w_raw 累加，不再读 layer4.BA 的 8 邻域统计。
	//   scals.a    —— **保留**读 layer4.G：沟谷 crease 是烘焙连续量，与格界归属无关，
	//                方案 §3.8 明确要求留着（该次采样仍在，只是不再读 .r / .ba）。
	float field_edge_gap = pk_cell_field_edge_gap(cell_field);
	scals.r = field_edge_gap;
#ifdef VT_USE_EDGE_DISTANCE
	scals.a = edge_px.g;
#endif
	shore_frac = pk_cell_field_shore_frac(cell_field, cell_e0, cell_e1, cell_e2);
#else
#ifdef VT_USE_EDGE_DISTANCE
	scals.r = edge_px.r;
	scals.a = edge_px.g;
	shore_frac = edge_px.ba;
#else
	scals.r = 1.0;
#endif
#endif

#ifdef PK_CELL_FIELD
#include "res://shaders/include/world_map_cell_table_state.gdshaderinc"
#else
	// map_index 一次采样：R=像素 biome，GB=cell id，A=landform。
	vec4 map_px = visual_sample_map_index(uv);
	int _cell_id = int(map_px.g * 255.0 + 0.5) + int(map_px.b * 255.0 + 0.5) * 256;
	_cell_id = (_cell_id >= 65535) ? -1 : _cell_id;
	// dyn_lut.a 与旧 dyn_atlas_smooth.a 同语义（水格=sea_ice_frac，陆格=vegetation_vitality）。
	// [dither-index 2026-06-25] 全档位 NEAREST：cell 索引边缘融合（烘焙期 Bayer dither）已在
	// 索引层软化离散硬边，无需再对 dyn/eco LUT 做跨格 4-tap 双线性。
	vec4 dyns = (_cell_id >= 0) ? texture(dyn_lut, cell_lut_uv(_cell_id)) : vec4(0.0);
	// [eco-lut-retire 2026-08-06] 主地形不再读 eco_lut：着色与 dyn_vitality 重叠，
	// 纹理槽让给 terrain_material_tex（web/mobile/desktop 统一）。植被层自有 eco_lut。
#endif

#include "res://shaders/include/world_map_surface_axes.gdshaderinc"
	// flow + river_edge_warp 仅在陆地的 river 分支才用，这里推迟到 _if (!is_water)_ 计算，
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 水陆判定（方案 §3.7）：陆地与水面两个 program 调用
	// **同一个**函数、读同一份数据 ⇒ 海岸线就是 dom 在水 / 陆之间切换的那条弯曲等值线。
	bool is_water = pk_cell_field_is_water_dom(cell_field, cell_e0, cell_e1, cell_e2);
#ifdef PK_LAND_ONLY
	// 防出洞（方案 §3.7）：两个 program 分别编译，同一表达式在恰好落在等值线上的
	// 像素上可能给出不同结果（一边 discard、另一边也 discard ⇒ 1 px 洞）。规则是
	// 「画在**下层**的 program 放宽 ε，上层严格」，宁可重叠不许出洞。
	//
	// 哪边是下层（绘制顺序证据）：
	//   renderer_scene_services.gd:91-94 建 _world_quad（陆地 program，z_index=0）；
	//   renderer_shader_water.gd:687-696 把 _water_quad 的 z_index 也设为 0，再
	//   move_child 到 _world_quad.get_index() + 1，注释原文「水面盖住陆地」。
	// ⇒ **陆地是下层、水面是上层**，所以放宽 ε 的是陆地 program：岸带（gap < ε）内
	//   即使 dom 判成水也照常画陆地色；正常像素仍由上层水面 program 覆盖，只有那个
	//   1 px 争议带会退化成陆地色而不是一个洞。
	is_water = is_water && (field_edge_gap >= PK_FIELD_SHORE_EPS);
#endif
#else
	bool is_water = (biome == B_OCEAN) || (biome == B_COAST) || (biome == B_LAKE)
			|| (biome == B_REEF) || (biome == B_KELP) || (biome == B_SEA_ICE);
#endif
	vec2 ocean_current_v = vec2(0.0);
	vec2 wind_v = vec2(0.0);
#if !defined(PK_LAND_ONLY) && (!defined(PK_WEB_TEXTURE_BUDGET) || defined(PK_WEB_WATER_ONLY))
	if (is_water && ocean_current_enabled && ocean_current_flow_tex_bound) {
		ocean_current_v = textureLod(ocean_current_flow_tex, uv, 2.0).rg * 2.0 - 1.0;
	}
#endif
	// [land-water-split 2026-11-02] 水面 program（Web HIGH 与桌面/移动 PK_WATER_ONLY）：
	// 只画水。陆地像素 discard —— 陆地像素由陆地 program 负责（含混合 block 的陆地像素）；
	// 未探索的**水**像素不 discard，落到下面的 fog 出口画 fog_unexplored_color（与陆地
	// program 同一 uniform 值），保证纯水 block 在分 mesh 后仍有迷雾色。
	// debug 视图由 renderer 回退单 program，这里保留 discard 作为防御。
#ifdef PK_WATER_ONLY
	// Reuse the PC water pipeline without compiling a second land shading source.
	if (!is_water || terrain_surface_debug_view != 0) { discard; }
#endif
	// Fog and the land/water edge effects can all read the same secondary
	// cell. Resolve its index and enum texture once, only when a consumer
	// needs it. Dynamic weather, ice, and climate stay on the primary cell.
	int visual_land_biome = biome;
	int visual_land_veg = veg;
	int visual_land_cover = cover;
	// Water keeps hard primary ownership, but MID/HIGH pass the secondary static
	// material and a continuous distance-field weight into one water evaluation.
	// LOW compiles this lookup out entirely. Dynamic state remains primary-owned.
	int water_secondary_biome = biome;
	int water_secondary_cover = cover;
	float water_static_edge_mix = 0.0;
	// [edge-sample 2026-11-18] 静态材质边权重包（PR #9 引入）。两个变体都要声明：
	// render_land_pipeline 的形参不随 define 变化，场版本只把它原样传下去、不读值。
	TerrainEdgeSample terrain_edge;
	terrain_edge.biome = -1;
	terrain_edge.weight = 0.0;
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 海冰比例：layer1.A 按 w_raw 三格混合（连续量，冰缘不再
	// 沿格界硬切）。dyns 在 PK 下就是三格 state 的 w_raw 混合；padding 像素 dyn_valid=0
	// ⇒ 与今天 cid < 0 取 1.0（整片海冰）一致。
	float visual_water_ice_fraction = mix(1.0, dyns.a, dyn_valid);
	// [cell-field 2026-11-18] 门控阶段选格（方案 §3.6）：不再用 DitherUV 在主 / 副之间
	// 二选一（那是 Bayer 网点，近景 `terrain_land_dither_zoom_strength()` 归零后退化成
	// 硬主 id ⇒ 纹素台阶），改为在**每格世界锚定的抖动量**上做 argmax：近景碎边、远景
	// 退化成 argmax(w) 的弯曲硬边。整段不再读 terrain_mobile_dither_uv_threshold /
	// terrain_land_dither_zoom_strength / decode_edge_secondary_index / enum_lut。
	// 门控不能把水格配色带进陆地像素（方案 §3.7「颜色不跨水陆」）：胜者若是水格，
	// 退回主导格三元组 —— 与今天 land_secondary 的水格守卫同义。
	if (!is_water) {
		ivec3 field_gate = pk_cell_field_gate_class(
				cell_field, cell_e0, cell_e1, cell_e2, pixel_noise);
		int field_gate_water = terrain_static_biome_is_water(field_gate.x) ? 1 : 0;
		visual_land_biome = (field_gate_water == 1) ? biome : field_gate.x;
		visual_land_veg = (field_gate_water == 1) ? veg : field_gate.y;
		visual_land_cover = (field_gate_water == 1) ? cover : field_gate.z;
	}
#if !defined(PK_QUALITY_LOW)
	// [cell-field 2026-11-18] 次生水格 = 权重第二的那一格（pk_cell_field_rank(f, 1)），
	// 混合权重就是它的 w_raw。今天的 water_edge_w 是距离场导出的连续量，这里换成同一
	// 语义的连续量；候选仍必须是水格（与今天 candidate_biome 的守卫同义）。
	{
		vec4 field_rank1_cls = pk_cell_field_ranked_class(cell_field, 1, cell_e0, cell_e1, cell_e2);
		int field_rank1_biome = pk_byte_of(field_rank1_cls.r);
		bool field_second_ok = is_water && terrain_static_biome_is_water(field_rank1_biome);
		water_secondary_biome = field_second_ok ? field_rank1_biome : water_secondary_biome;
		water_secondary_cover = field_second_ok ? pk_byte_of(field_rank1_cls.b) : water_secondary_cover;
		water_static_edge_mix = field_second_ok
				? pk_cell_field_ranked_weight_raw(cell_field, 1) : 0.0;
	}
#endif
#else
	float visual_water_ice_fraction = (_cell_id < 0) ? 1.0 : dyns.a;
	// Fog and the land/water edge effects can all read the same secondary
	// cell. Resolve its index and enum texture once, only when a consumer
	// needs it. Dynamic weather, ice, and climate stay on the primary cell.
	if (_cell_id >= 0 && has_terrain_edge_data) {
		float edge_weight = terrain_edge_secondary_weight_d(scals.r, wp);
		bool land_material_edge = !is_water && edge_weight > 0.0001;
		float land_probability = land_material_edge
				? edge_weight * terrain_land_dither_zoom_strength() : 0.0;
		bool land_edge = land_probability > 0.0001;
		bool fog_edge = false;
#if defined(PK_MOBILE_ANY)
		fog_edge = edge_weight > 0.0001;
#endif
		if (land_edge || fog_edge) {
			float dither = terrain_mobile_dither_uv_threshold(uv, wp);
			land_edge = land_edge && dither < land_probability;
			fog_edge = fog_edge && dither < edge_weight;
		}
		bool water_edge = false;
#if !defined(PK_QUALITY_LOW)
		water_edge = is_water && edge_weight > 0.0001;
#endif
		if (land_material_edge || fog_edge || water_edge) {
			int secondary_id = decode_edge_secondary_index(uv);
			if (secondary_id >= 0) {
				vec4 secondary_enum = texture(enum_lut, cell_lut_uv(secondary_id));
				if (fog_edge) fog_k = secondary_enum.a;
				int secondary_biome = int(secondary_enum.r * 255.0 + 0.5);
				bool secondary_water = terrain_static_biome_is_water(secondary_biome);
				if (land_material_edge && !secondary_water) {
					terrain_edge.biome = secondary_biome;
					terrain_edge.weight = edge_weight;
				}
				if (land_edge && !secondary_water) {
					visual_land_biome = secondary_biome;
					visual_land_veg = int(secondary_enum.g * 255.0 + 0.5);
					visual_land_cover = int(secondary_enum.b * 255.0 + 0.5);
				}
				if (water_edge && secondary_water) {
					water_secondary_biome = secondary_biome;
					water_secondary_cover = int(secondary_enum.b * 255.0 + 0.5);
					water_static_edge_mix = edge_weight;
				}
			}
		}
	}
#endif

	// ═══════════════════════════════════════════════════════════════════════
	// SETUP 1：季节相位 + 当前温度（每帧由 WorldClock 驱动）
	// ───────────────────────────────────────────────────────────────────────
	// 提前算好 lat_signed / season_offset / current_temp，让后续
	// 植被 / 雪 / 海冰 / 深海色温分支都消费同一组温度值。
	// ═══════════════════════════════════════════════════════════════════════
	// ─── Phase 1：季节相位 + 当前温度（每帧由 WorldClock 驱动） ───────────
#if defined(PK_BAKE_LAND_COLOR) || defined(PK_BAKE_LAND_NORMAL)
	TerrainStaticMaterial base = compute_terrain_static_material_field(
		cell_field, cell_e0, cell_e1, cell_e2, visual_land_biome, elev, wp, uv);
#ifdef PK_BAKE_LAND_COLOR
	COLOR = vec4(base.color * 0.5, base.micro_strength * 0.5);
#else
	COLOR = vec4(base.material_normal_xy * 0.5 + 0.5, base.roughness, 1.0);
#endif
#else
	float lat_signed = lat_norm * 2.0 - 1.0;            // [-1, 1]
	// True Insolation-Driven：CPU / GPU 同源日照偏移；兼容 bool 不再切换 legacy 分支。
	float season_offset = season_offset_unified(lat_signed, season_phase);
	float derived_temp = compute_current_temp(elev, lat_signed, season_offset);
	float current_temp = mix(derived_temp, dyn_temp, dyn_valid);

	// ═══════════════════════════════════════════════════════════════════════
	vec3 col;

	// ═══════════════════════════════════════════════════════════════════════
	// ═══════════════════════════════════════════════════════════════════════
	// 主分支：陆地 / 海面
	// ───────────────────────────────────────────────────────────────────────
	// 每条分支都按：basecolor → 变色层 → 覆盖层 → 光照。
	// 分支外只保留全局视觉调整（羊皮纸、季节过渡 alpha、COLOR 写出）。
	// ═══════════════════════════════════════════════════════════════════════
	// 未探索早退：这些像素会被 FogOfWarLayer 的**完全不透明**厚云盖住，画什么都
	// 看不见，所以整条陆地/水体/BRDF/hillshade 管线（几十次采样）可以整段跳过。
	// GPU 分支按 wave 粒度生效：迷雾区是大片连续屏幕区域，发散 wave 只有 O(边界
	// 周长)，相对 O(面积) 可忽略。canvas_item 的 fragment 禁用 return，所以只能
	// 用 if/else 把两条出口都写出来。
#ifdef PK_CELL_FIELD
	// [cell-field 2026-11-18] 「三格均未探索」才早退，但**不额外采 aux**：
	// edge_gap ≥ PK_FIELD_BAND_MAX ⇒ 邻格权重为 0，这个像素既不在任何格界带里，也没有
	// 邻居能在视觉上渗进来 —— 主导格未探索就等于整块未探索；反过来，整条过渡带
	// （edge_gap < 带宽）永远不早退，正是「三格里至少有一格已探索」原本要保护的性质。
	// fog_k 本身是主导格 aux.R 的 1 次 texelFetch（见 SETUP），LOW 档与今天逐值等价。
	bool fog_hidden = fog_early_out_enabled
			&& (fog_k <= fog_early_out_k)
			&& (field_edge_gap >= PK_FIELD_BAND_MAX);
#else
	bool fog_hidden = fog_early_out_enabled && (fog_k <= fog_early_out_k);
#endif
	if (fog_hidden) {
		COLOR = vec4(fog_unexplored_color, 1.0);
	} else {
		if (!is_water) {
#if !defined(PK_PROBE_NO_LAND) && !defined(PK_WATER_ONLY)
			col = render_land_pipeline(
				visual_land_biome, biome, visual_land_veg, visual_land_cover, landform,
				elev, moist, wp, uv, scals, lat_signed, current_temp,
				wind_v, dyn_snow, dyn_valid, dyn_vitality, pixel_noise, shore_frac, terrain_edge
#ifdef PK_CELL_FIELD
				, cell_field, cell_e0, cell_e1, cell_e2
#endif
#ifdef PK_READ_LAND_BASE
				, SCREEN_UV
#endif
				);
#else
			col = vec3(0.2, 0.35, 0.15);   // PROBE: land pipeline removed
#endif
		} else {
#ifndef PK_PROBE_NO_WATER
#if defined(PK_WEB_WORLD_MIN) || defined(PK_WEB_SPLIT_WATER)
			// [web-water-pass] web-LOW 档：水面由独立的第二 pass
			// （shaders/world_water_web.gdshader）整屏覆盖重画，这里只出一个常量。
			// 这是本次结构性修复的**全部内容**：本 fragment 从此只有一个真正的
			// 着色来源（陆地），FXC 不再踩"两个来源联合优化"的 20.3 s 悬崖。
			// 常量取值与 PK_PROBE_NO_WATER 探针一致（该探针因此退化为等价路径，
			// 但按约定保留：它是"水面像素到底由谁画"的开关）。
			col = vec3(0.1, 0.2, 0.4);
#elif defined(PK_LAND_ONLY)
			// [land-water-split 2026-11-02] 桌面 / 移动陆地 program：水面像素由独立的
			// 水面 program 绘制（混合 block 两张覆盖 mesh 都覆盖，这里 discard 才不会
			// 盖掉水；未探索像素已在上面走 fog 出口，与水面 program 同色）。
			discard;
#else
			col = render_water_pipeline(
				biome, cover, water_secondary_biome, water_secondary_cover,
				water_static_edge_mix, elev, wp, uv, scals,
				lat_signed, current_temp, ocean_current_v, wind_v,
				visual_water_ice_fraction, shore_frac, pixel_noise
#ifdef PK_CELL_FIELD
				, cell_field, cell_e0, cell_e1, cell_e2
#if defined(PK_WATER_ONLY) || defined(PK_QUALITY_LOW)
		, field_water_depth
#endif
#endif
				);
#endif
#else
			col = vec3(0.1, 0.2, 0.4);     // PROBE: water pipeline removed
#endif
		}
		int visual_surface_cover = is_water ? cover : visual_land_cover;
		int visual_surface_veg = is_water ? veg : visual_land_veg;

		// 已探索但当前不可见 → "褪色的记忆"，不是"压暗的脏块"。
		// k=0.5 处最强，k=1 归零。零新增采样，只是几条 ALU。
		//
		// [fog-memory-wash 2026-11-17] 原来是 `mix(col, 灰, amt) * 0.82`：整体压暗 18%
		// 再全去饱和。深色海面上这直接变成一圈近黑的脏环，而且把地形烘焙的块状边缘
		// 一起放大 —— 真机"迷雾很丑"的观感有一半来自这里（关掉迷雾那一帧的同区域
		// 是明亮的浅海）。记忆层应该是**提亮+褪色**：往纸色靠，明度不低于原图，
		// 顺便把块状边缘糊掉，和手绘纸本的底子也更搭。
		if (fog_gray_enabled) {
			// 灰化公式统一在 fog_memory.gdshaderinc（植被 / 资源共用同一份），
			// 保证同一片未发现区里三层给出同一个纸白。
			col = pk_fog_memory_wash(col, fog_k, fog_gray_strength);
		}

#include "res://shaders/include/world_map_fragment_output.gdshaderinc"
#endif // static land bake
}
