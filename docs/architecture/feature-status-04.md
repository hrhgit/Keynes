# 格子场、开局加载与逐日计算

## 格子场推广到天气云与战争迷雾（2026-11-18，同日第三轮 O0–O3）

方案：`docs/plans/terrain-cell-field-overlays-plan.md`（O0–O6；**本轮做 O0–O3 与 O2↔O3 接口收口，O4 探针与 O5/O6 未做**）。
这一轮把「类别量进纹理」的根治从地形推广到**天气云**和**战争迷雾**，并把场函数核心拆成不依赖任何 uniform 的共享层。

- **O0 核心拆分**：新增 `shaders/include/hex_cell_core.gdshaderinc`（**零 uniform / 零 sampler**：
  `PkHexGrid` / `PkHexTri` / `pk_hex_tri` / `pk_hex_tri_dom` / `pk_hex_tri_gap` / `pk_hex_sharpen` /
  `pk_hex_field_aa`）与 `cell_field_overlays.gdshaderinc`（零 uniform 胶水：`pk_overlay_tri` /
  `pk_overlay_fog_k` / `pk_overlay_fog_visibility` / `pk_soft_warp_tiled`）。`hex_cell_field.gdshaderinc`
  退化成包装层，`HexCellField` 与全部公开函数签名不变。**地形侧编译结果逐 token 不变**（6 种前缀
  对照：default 与 `PK_LAND_ONLY` 完全相同；4 个 PK 前缀的差异全部落在场函数 include 的
  变化窗口内，窗口外逐字相同），GPU parity 仍 100%。
- **O1 天气数据**：新增 offset 空间的 `weather_table`（`Texture2DArray` 4 层：天气 A/B + 风 A/B，
  层号双缓冲，`update_layer` 只写 `1-cur` 那一层、**不拷贝**）。重排复用
  `DCCellTableCodec.reorder_to_offset`；发布挂在 `_publish_weather_lut_bytes` 的既有提交点，
  **不新增节拍、不改模拟行为**。风字节的上游查清：`weather_wind_source.build_image()` 自己编码
  （不在 `encode_cell_luts` 里），且**发布节拍与天气同一**（`weather_lut_update_usec` 是唯一门），
  所以可以共用层号。两个前提也确认：`cell_table` 与地形扭曲场（layer6 / `visual_warp_tiles`）
  **都与地形开关无关、无条件生成**，Web 上不会读到空表。
- **O2 天气 overlay**：`PK_CELL_FIELD` 下天气改走场函数 —— 连续量（intensity / cloud / vapor / 风）
  按 `w_raw` 三格插值，**类型先查 profile 再按权重混结果**（不插 ID）；`compute_cloud_lighting`
  的 `int wt` 参数经查证是**死参数**，直接删除（比方案 §3.5 的「传 `wt_dom`」更彻底，构造上不可能
  有交界跳变）。删除 `map_index` / `edge_*` 间接寻址、Bayer 选格、桌面 6 邻环采样。
  **sampler 8 → 2**（`cell_table` + `weather_table`）。新增**独立**开关
  `project_keynes/rendering/map_tiles/weather_cell_field_enabled`（**2026-11-18 收尾起出货默认开**，
  与地形开关互不影响；关态逐字节还原）。
- **O3 战争迷雾**：k 改读 `cell_table` aux.R 并按**锐化权重**三格混合，带宽 `fog_field_band`（默认 0.6，
  比地形宽）；扭曲改成**按长度 clamp**，`A_max = (√3/2 − band/2)·hex_size` 由 band 解析算出
  （旧 `edge_warp = 0.55` 是 hex 直径倍数，能把可见格格心推进隔壁未探索格 —— 这是本轮修掉的真问题）。
  **强制不透明**：迷雾 shader 内部复算地形早退判定（同一个 `PK_FIELD_BAND_MAX`、同一张地形扭曲场、
  同一个 `pk_hex_tri_gap`），并让 `fog_hidden_margin` 吸收半分辨率 + 线性上采样。**不新增开关**：
  直接跟随 `RendererShaderWater._cell_field_active()`（与地形同源）。delete Bayer / edge 路径。
- **O2↔O3 接口**：`fog_field_band` / `fog_warp_freq` / `fog_warp_amp` 收敛到**单一真源**
  （`fog_of_war_layer.gd` 的常量），天气的迷雾门控改用**迷雾的**扭曲构造 k 的三角形 ——
  否则云的消失边界与薄纱边界仍会错开（方案 §3.7）。

验证证据：

| 项 | 结果 |
|---|---|
| `tests/world/terrain_shader_variant_test.gd` | **368 / 0**（+1 条：`hex_cell_field` 是纯包装层 + 核心零 uniform） |
| `tests/world/weather_overlay_field_test.gd`（新） | **164 / 0**：sampler 8 → 2（等值 + 名单 + 类型）、9 条符号缺席/在场双向外加、`weather_table` 无 `source_color`、`compute_cloud_lighting` 不吃 int |
| `tests/world/fog_cell_field_test.gd`（新） | headless **128 / 0**（不变量 SKIPPED）；**vulkan 141 / 0**：不变量 1 = `terrain_hidden` 13955 px / 最小 alpha **255** / 违例 0（关掉早退的对照组有 4283 个 <254），不变量 2 = k=1 全屏 alpha>0.02 的像素 **0.0000%** |
| `tests/world/weather_table_layout_test.gd`（新） | headless **82 / 0**（1 skipped）；opengl3 与 vulkan 各 **85 / 0**：逐字节对照重排结果、翻转后 prev 层仍是上一次 cur、`update_layer` 只写目标层 |
| `tests/world/hex_cell_field_parity_test.gd` | 44 / 0（CPU 镜像未改） |
| `cell_field_gpu_parity_probe` | opengl3 / vulkan 各 **19 / 0**（76800 px 100%） |
| 既有天气/迷雾回归 | `overlay_edge_transition_shader_test` 88/0、`cloud_weather_quality_test` failures=0、`weather_noise_shape_test` PASS、`web_water_pass_node_test` 86/0 |
| 关闭还原 | `PK_CELL_FIELD` 关闭时两份 shader 逐字节不变（迷雾侧做了「HEAD 版 vs 当前版展开后 1129 行完全相同」的直接比对） |

未覆盖 / 已知偏差（详见方案 §8 与本轮报告）：

1. **O4（GPU 回读探针的天气侧）未做**：迷雾的不变量 1/2 已有真后端实测（见上），但**天气**的
   `dom offset` / `Σw` / `terrain_hidden` 逐点 CPU 比对还没接进 `cell_field_gpu_parity_probe`。
2. **O5 雨幕、O6 云影未做**（方案本身把 O5 列为可选，O6 是后续项）。
3. **移动/Web 的性能与视觉判据未实测**：方案 §6 的「overlay pass 移动 ≤1.15× / 桌面 ≤1.0×」、
   「任意缩放无方块」「雨晴交界色调连续」「迷雾边形态」都需要开窗口跑真机矩阵。
4. **有意的视觉变化**（需美术确认）：① 迷雾边扭曲幅度约减半（`A_max = 0.566·hex_size` vs 旧
   `1.1·hex_size`）；② 天气低雾的「山地权重」在 PK 路径统一成桌面档（移动/Web 旧的二值近似会
   在普通陆地上多一点低雾）；③ ~~迷雾 padding 语义改为与地形一致（k=1 视作全知）~~ ——
   **上线后按用户截图回退：padding 的 k 改回 0（完全不透明）**，并补了真后端「不变量 3」守着
   （`fog_cell_field_test` 128 → 151 断言；padding 带 16320 像素 alpha 违例 0，变异验证可红）。
   注意两侧 k 的**语义相反**：地形侧 k=1 是「不早退、照常渲染」，迷雾侧 k=0 是「完全不透明」。
5. **`VisionSolver.BLUR_ITERATIONS` 未动**：场插值 + 两环 blur 可能「双重柔化」，需 O3 视觉验收时
   对比 2/1/0 再定（方案 §8-1）。
6. **`weather_table_valid=false` 时 PK 路径整层无云**（旧路径只是少风向）；而 `weather_table_commit_plan`
   依赖风场字节，风场上游一旦断供天气会整体消失。这条后果比方案 §7 预估的更硬，W5 应复核。


## 格子场 Web / Compatibility 解禁（2026-11-18，同日第二轮）

方案：`docs/plans/terrain-cell-field-web-plan.md`（W0–W6）。**默认开关仍为关**；关闭时前缀逐字节不变。
上一轮的 v1（P0–P4）见下面「地形格界解析化」一节。

这一轮做的事，一句话：把「Web 8 槽预算装不下 `cell_table`」这个唯一卡点解掉，并给线上静默错误加了自检回退。

- **`cell_table` 加第 4 层 `class_by_index`**（`cell.index` 空间，R=biome/G=veg/B=cover/A=landform，不重排），
  让 GI 弹射近似不再依赖 `enum_lut`。`WorldData.cell_table_layers`（0/3/4 三态）在 `n > W×H` 时降级不越界写。
- **旧三槽在 Web 预算变体里从声明中删除**（`PK_CELL_FIELD_NO_LEGACY_LUT`）：`enum_lut` / `dyn_lut` 不再声明、
  `VT_USE_MAP_INDEX` 不定义 ⇒ 任何残留引用变成编译错误。`lat_norm` 改用 `derived_resolution.y`（与旧
  `textureSize(map_index_atlas)` 逐值相等）。
- **`world-min` 与场函数正交化**：删掉之前那段 `#undef PK_CELL_FIELD` 归一化。world-min 的职责是把水面着色源
  搬到第二 pass，不阻碍 SETUP 用 `cell_table`；否则 Web LOW 会是「陆地索引图判水陆 + 水面场函数判水陆」，
  海岸必然错开 1~2 px。
- **`world_water_web.gdshader` 迁到场函数**，载荷宏 `PK_WATER_FIELD_MATCHES_LAND` 跟随**陆地 program 的数据源**
  （同一个 `_cell_field_prefix()`），陆地和水面因此始终同源。
- **启动自检 + 自动回退**：专用 probe shader（3 sampler，`blend_disabled` 保证四通道可回读）+ 合成 4 层表 +
  金丝雀 texel，16×16 离屏回读后与 `DCHexCellField` 比对；结果写 Engine meta、按 adapter+driver+build 缓存到
  `user://`，`?cellfield=off|on` 强制覆盖；fail 自动回退旧路径并上报遥测。warmup 在 `_collect_codes()` 之前
  跑自检，只预热选中那一套。

验证证据：

| 项 | 结果 |
|---|---|
| sampler 普查（四前缀 × OFF/PK） | OFF 全 8，**PK 全 6**；清单逐项等值，类型区分 `sampler2DArray` / `sampler2D`；`map_index_atlas`/`enum_lut`/`dyn_lut` 逐名缺席 |
| `world_water_web` 第二 pass | sampler **7 → 4** |
| `tests/world/terrain_shader_variant_test.gd` | 292 → **341 checks / 0 failures** |
| `tests/world/web_water_pass_node_test.gd` | 28 → **81 checks / 0 failures**；真后端「两边都 discard 的像素 = 0」、「水面画出的水集合 == CPU 场 100%（19200 px）」 |
| `tests/world/cell_field_web_probe_test.gd` | headless 89（1 skipped）/ opengl3 98 / vulkan 97，**0 failures**；含「去掉金丝雀」「破坏 layer3」⇒ fail 并回退 |
| `tests/world/cell_table_layout_test.gd` | 29 → **48 checks / 0 failures**；含 `layer3[o2i[o]] == layer0[o]` 与 `cells ≤ W×H` |
| `tests/world/cell_table_platform_probe.gd`（真后端） | 4 层数组：GLES3 与 Vulkan 各 0 failures（分层读回 + 单层 `update_layer`） |
| `tests/world/cell_field_gpu_parity_probe.gd`（真后端） | 保持 0 failures（A/B/C/D 四 pass，76800 像素 100% 匹配） |

未覆盖（详见 web 方案 §9.4）：

1. **浏览器 / 真机矩阵（W0 浏览器部分、W5 全部）**：只在桌面 GLES3(OpenGL3) 与 Vulkan 验过。
   Chrome/Edge(ANGLE→D3D11)、Safari、Firefox、Android Chrome 的 `sampler2DArray`+`texelFetch` 行为、
   FXC 首编时长、帧时间仍需按方案 §5 跑并截图存档。
2. 自检不覆盖真实 program 的槽位分配（槽位由编译期普查守）。
3. `?cellfield=` 的真实 JS 读取未在浏览器里验过（非 web 恒空串）。
4. **有意保留的视觉语义变化**，需真机截图确认：岸线从「8 邻域水占比」改成「贴岸度」后，开阔洋面不再被混向
   浅滩色、海岸带才出现浅滩；次生水格混合权重从峰值 0.5 降到 ≈0.33（海/湖交界更淡）。


## 地形格界解析化（hex cell field）v1 落地（2026-11-18）

方案：`docs/plans/terrain-hex-mesh-implementation-plan.md`（P0–P4）；实现契约与偏离：
`docs/plans/terrain-cell-field-contract.md`。开关 `project_keynes/rendering/map_tiles/terrain_cell_field_enabled`
（或 `HexRenderer.terrain_cell_field_enabled`）—— **2026-11-18 第二轮末尾起出货默认开**
（`project.godot` 显式 `true`，代码 fallback 也是 `true`）；关闭时预处理产物与改动前逐字节一致，
`terrain_shader_variant_test` 用显式 `false` 的假 host 守住这条字节身份。

落地内容：

- **C++** `run_bake_terrain_index_pass` 新增 RG8 `boundary_warp_buffer` / `boundary_warp_range`
  (=1.6) / `boundary_warp_clamped`（实测 0），由 `run_bake_geometry_fields_pass` 转发；
  `run_bake_visual_tile_layer_pass` 新增 `boundary_warp` tile 字段（halo 重映射逐字节等价）。
- **非 tiled** `terrain_surface_tex` 6 → 7 层（layer6 = warp RG8），`MapBaker.SURFACE_ARRAY_LAYERS = 7`；
  **tiled** `VisualTileSet.FIELD_FORMATS` 新增 `boundary_warp`，`BYTES_PER_PHYSICAL_TEXEL` 35 → 37。
- **`cell_table`**（Texture2DArray，3×RGBA8，`map_w×map_h`，offset 空间）：class / state / aux，
  由 `cell_lut_baker` 在每次 LUT 刷新时按 `offset_to_index` 重排发布（state-only 刷新 1.58 ms / 2400 格）。
- **shader**：新 `hex_cell_field.gdshaderinc`（对偶三角 + 重心权重 + gap + 门控选格 + 三格查表）；
  `PK_CELL_FIELD` 下陆地与水面 SETUP 改查 `cell_table`、`is_water` 单一判定（下层陆地放宽 ε）、
  fog 早退改解析判定、静态材质 3-way（材质只采前两名）、水面删 `compute_lake_shore_proxy` 与
  邻域 `map_index` 环采样、水深/海冰按 `w_raw` 插值、DitherUV 整族编译剔除。
- **调试**：`terrain_surface_debug_view` 18–21（dom 自检 / 三格权重 / gap 差值 / warp），
  GM 面板「诊断」组已登记。
- **CPU 镜像**：`scripts/geography/hex_cell_field.gd`（`DCHexCellField`，只给测试/debug）。

验证证据（全部本地 headless 或真后端跑过）：

| 项 | 结果 |
|---|---|
| scons template_debug / template_release | `scons: done building targets.`，DLL 已更新 |
| `tests/world/hex_cell_field_parity_test.gd` | 44 checks / 0 failures（10 万点 parity 0 处不一致；gap 与 C++ 单位一致，误差 7e-8） |
| `tests/world/cell_table_layout_test.gd` | 29 checks / 0 failures |
| `tests/world/terrain_shader_variant_test.gd` | 277 checks / 0 failures（含 PK 变体编译、采样器增量、源码禁用符号、前缀互斥） |
| `tests/world/web_water_pass_node_test.gd` | 28 checks / 0 failures |
| `tests/world/terrain_index_edge_bake_test.gd` | 11 checks / 0 failures |
| `tests/ui/visual_tile_native_bake_test.gd` / `visual_tile_layout_test.gd` | PASS（bundle 含 `boundary_warp` hash） |
| `tests/ui/cell_lut_incremental_test.gd` / `bounce_lut_native_test.gd` | 31 / 93 checks，0 failures |
| `tests/world/cell_table_platform_probe.gd` | OpenGL3(3.3) 与 Vulkan 各 0 failures：`texelFetch(ivec3)` 分层的读写回一致、`update_layer` 单层更新且可重复 |
| 端到端 `tests/game/headless_perf_record.gd` | tiled 与 legacy 两次：`fatal=false`、`ledger_failures=0`、`rows=expected_rows`；每块 tile 的 `hashes.boundary_warp` 均存在 |
| 水面采样预算 | MID 38 → 14 次（37%）、HIGH 42 → 14 次（33%），≤ 60% 目标达成 |
| 	ests/world/cell_field_gpu_parity_probe.gd（**真后端**） | vulkan 18 checks / OpenGL3 19 checks，全 0 failures：view 22 回读 dom offset 与 DCHexCellField.dom_at **逐像素 100% 一致**（无回绕 / 跨接缝 / 带 warp 场三个 pass，各 76800 点、0 hard mismatch）；view 23 回读带宽 max=0.0911 < 0.10，等于文档化 AA 项 2/hex·1px |
| 架构守卫 | `check_size_ratchet` 仅剩 5 条既有违规（非本次文件）；`check_cpp_deps` / `check_module_map` / `check_world_ext_bindings` / `check_script_native_access` / `check_runtime_switches` / `check_module_contracts` / `check_committed_views` 全 0 |

未覆盖 / 已知限制（详见契约 §8）：

1. **Web 与桌面 Compatibility 不启用**：`PK_WEB_TEXTURE_BUDGET` 变体只有 8 个采样槽，`cell_table`
   是第 9 个；`enum_lut`/`dyn_lut`/`map_index_atlas` 在 P2 退不掉（`cell_indirect` 的 GI 弹射仍要
   `cell.index`）。P6 退役这些通道后才能解除。移动端走 Vulkan mobile 后端，不受这条限制。
2. **未做真机与视觉验收**：Mali / Adreno 真机、WebGL2、以及「任意 zoom 无纹素台阶 / 角点无楔形 /
   关闭开关 diff = 0」这几条视觉判据都需要带窗口跑图截图，本次未执行（GPU↔CPU 的逻辑一致性已由
   上面两条真后端探针覆盖）。
3. 采样账面比方案 §3.8 多 1（陆地 13 而非 12），因为沟谷 crease 仍读 `edge_distance`。
4. P4-1（纹样锚点选格）与 P5（其余图层统一场函数）未做；P4-1 实现时必须用
   `pk_hex_dom_offset()`（无 fwidth，可在分支里调），不能复用 `pk_hex_cell_field`。

### 评审修复（2026-11-18 review，同批已合入）

评审提出四条，全部确认成立并已修：

1. **回绕接缝的 AA 带宽（bug）**：AA 导数原来取自**已回绕**坐标，跨经线时 `q` 跳 `map_w`、
   `fwidth` 爆掉、带宽被 clamp 到 0.86 ⇒ 接缝处 1~2 px 混合拉满的竖线。改为入参用未回绕
   世界坐标 + 精确梯度 `2/hex_size`。回归守：探针 Pass C（`max band = 0.0911 < 0.10`）。
2. **门控抖动做不出碎边**：整格常量 jitter 只把边界整体平移，是光滑但与颜色边界错开的线。
   改为 `fract(pixel_noise.r·3 + hash(cell_i))`（复用 SETUP 已有采样，零新增），LOW 档直接 argmax。
3. **缺 GPU↔CPU 坐标系测试**：新增两条真后端探针（见上表），并把「世界 uniform 不得硬编码」
   写成断言。
4. **P4-1 的 fwidth 坑**：新增 `pk_hex_dom_offset()`（无导数、无 AA），供纹样锚点这类
   非一致控制流里调用。

## 96×64 四国开局的后台天气准备（2026-11-17）

天气热赤道采样改在后台对冻结的温度、位置和边界计算。每日日提交附带同一份物理场和风轨迹，
主线程可以直接写回地图。地图天气与生态像素的准备排在日尾放行之后，准备耗时随视觉应用计时。

Apple M2、Godot 4.6.3，双方使用各自的 Release 原生库。种子 `20260718`，96×64 双大陆四国，
速度设为 100 倍。窗口 1600×960 高画质，计第 5 天至第 180 天。无画面使用正常游戏时钟，
计第 5 天至第 305 天。每组前后交替三次，逐日校验另跑。

| 项目 | 改前中位数 | 改后中位数 |
| --- | ---: | ---: |
| 高画质窗口 | 19.50 天/秒 | 20.27 天/秒 |
| 实际绘制频率 | 24.00 帧/秒 | 24.09 帧/秒 |
| 无画面正常时钟 | 68.11 天/秒 | 75.24 天/秒 |
| 无画面每游戏日等待环境输入 | 4.94 毫秒 | 3.67 毫秒 |

窗口测速的样本范围重叠，两版每两次绘制之间最多结算一天。窗口第 40 天结算时短暂停住
主线程，101.7 毫秒内后台结算 0 天，计时全部落在等环境输入。另一次隔离试验先送入
第 41 天输入再停住主线程，102.1 毫秒内也结算 0 天，计时落在等日尾。正式流程仍由主线程
提交下一日环境输入并确认军务、资源恢复和事件的日尾完成。去掉日尾确认前，须保证这些动作
给下一天发送的指令仍在原日生效。真实窗口 100 天/秒尚未达到。

无画面 370 天和真实窗口 180 天的对照中，改前 50 倍、改后 50 倍、100 倍、100 倍加两个
CPU 加压进程的八份模块校验值和完整经济逐日一致。气候纯原生测试逐位核对风轨迹及物理场，
并覆盖地图邻接、坐标及轨迹参数变化。关闭物理环流的 90 天逐日对照也一致。两份固定逐日
对照均通过，其中一份覆盖军事和资源。最终 Debug 库通过两轮加压下的命令生效日与独立进程
读档续跑检查。最终 Release 库的气候场景自测 7 项通过。文件行数检查仍有五处既有超限。
测速和逐日结果见 `/tmp/keynes-unframe.UilkxLBT` 的 `graphical/comparison.json`、
`clock-rate/comparison.json`、`parity/comparison.json` 和 `screen-parity/comparison.json`。
停住窗口主线程的两项验证见 `hold-frame-fixed.log` 和 `hold-tail.log`，加压读档和命令
验证见 `save-and-command-verified/summary.json`。

## 96×64 四国开局的加载与逐日交接（2026-11-17）

Apple M2、Godot 4.6.3，双方使用各自的 Release 原生库。与上一轮结束时的工作区对照，
仍用种子 `20260718`、96×64 双大陆、四国，速度设为 100 倍。窗口 1600×960 高画质，
两组对照交换运行顺序，按 GameFlow 启动至玩家场景就绪、以及第 5 天至第 180 天分别计时。
无画面正常游戏时钟三次前后交替，按第 5 天至第 305 天测速，逐日校验另跑。

| 项目 | 改前中位数 | 改后中位数 |
| --- | ---: | ---: |
| 开局加载 | 11.92 秒 | 10.11 秒 |
| 高画质窗口 | 19.89 天/秒 | 20.62 天/秒 |
| 窗口帧率 | 26.59 帧/秒 | 26.50 帧/秒 |
| 无画面正常时钟 | 70.39 天/秒 | 68.25 天/秒 |

开局缩短约 15%。窗口吞吐和无画面吞吐的样本范围互有重叠，距离 100 天/秒仍有差距。
新版窗口中，后台每游戏日平均计算约 9.9 毫秒，环境队列空时等待约 31.4 毫秒，
环境输入已就绪后的日尾等待约 7.2 毫秒。无画面三次等待环境的中位数为 4.86 毫秒/天。
两项等待是互斥的计时分类，环境和日尾同时未准备好时先记录环境等待。

回归用例固定了提交在一帧中变为可读的时机，旧顺序将该日输入延后，改后同一帧发送。
原生环境队列在后台等待所用的锁内发布。海岸与海域编号复用相同邻接和海陆分类。
经济储量副本按变更页发布，Debug 独立测试中第 10–360 日每天检查约 49.7 万字节，
改前为 154.8 万字节，减少 67.9%。这组隔离对照的 365 天中，八份模块校验值、完整经济、
31 类储量、军事及全图物种分布逐日相同。原始数据见
`/tmp/keynes-resource-projection.9PAyYxWF/comparison.json`。

地图显示把纹理上传放在天气插值之前的渲染阶段。三天同帧夹具中，上传从 14 次降至 6 次，
六张结果纹理逐字节相同，包括天气插值的当前与上一份纹理。开局使用预编译默认规则，原生
生成可直接交付邻接索引，后一块地形能在上一块上传后立即开始烘焙。上一轮 `build_indices`
的 3.6 秒记录含整个地图烘焙，本轮分开打点。96×64 定向对照中，地图、邻接索引及
12 块地形的 96 张纹理摘要相同。

Debug 正常时钟运行 370 天，改前、改后 50 倍、100 倍、100 倍加两个 CPU 加压进程的
八份模块校验值和完整经济逐日相同。Release 玩家窗口按同一组条件对照了 180 天，各日相同。
命令生效日期和独立进程的加压读档续跑均通过最终版本对照。第 364 日保存后跨年续跑八天通过，
第 366 日的用例在无中断参照退出时出现 ObjectDB 资源警告，严格检查在读档前停止。
Release 原生库的 10 个定向用例通过。两套固定逐日对照通过，文件行数检查仍有五处既有超限。
原生加载测试在编译期并跑的一次检查出现退出警告，最终版详细复核以及另三次加压均通过。

现有提前发送路径的隔离试验从第 2 天出现差异，追踪到启动时提前发出了缺少后台气候字段的输入。
等授权并对齐日期后，90 天对照相同，全年试验在第 357 天再次出现气候和完整经济差异。
短测提前发送为 73.71 天/秒，普通路径为 74.62 天/秒。正式开局继续按日期发送输入、完成日尾后才推进。
测时和验证日志见 `/tmp/keynes-next.AtKoVHCE` 下的 `clock-rate`、`screen-rate`、
`debug-parity`、`screen-parity`、`final-save-load-pressure`、`annual-checkpoints`、
`release-smoke`、`experimental-prefetch-year.log`、`prefetch-trace.log` 与 `final-loading-check`。

## 96×64 四国开局的 100 倍快进（2026-11-17）

Apple M2（8 核）、Godot 4.6.3、macOS arm64，比较提交 `c31304658` 与本轮改动。
新旧两版均加载各自的 Release 原生库。正式开局为 96×64、四国、初始人口 160，种子
`20260718`。速度设为 100 倍，只计实际完成结算的天数。无画面测速交替运行三组，取中位数。

| 实测项目 | 改前 | 改后 |
| --- | ---: | ---: |
| 玩家窗口，1600×960 高画质，从第 5 天到第 180 天 | 12.69 天/秒 | 20.02 天/秒 |
| 无画面，正常游戏时钟从第 5 天到第 305 天 | 62.71 天/秒 | 72.16 天/秒 |
| 无画面，预热 5 天后直接驱动正式模拟，测 100 天 | 63.04 天/秒 | 69.09 天/秒 |
| 无画面，同一测试测 365 天 | 62.55 天/秒 | 70.46 天/秒 |
| 365 天测试的总耗时，含预热及收尾 | 6.11 秒 | 5.44 秒 |
| 365 天测试，后台每天执行计算 | 11.80 毫秒 | 9.31 毫秒 |
| 365 天测试，后台每天等待输入 | 4.73 毫秒 | 5.37 毫秒 |

玩家窗口经 GameFlow 进入完整的玩家场景，使用双大陆地图和 Metal 渲染，开启昼夜、关闭垂直同步。
macOS 以 `open -g` 打开窗口。按旧、新、新、旧的顺序跑四次，均收到了连续的第 1 到第 180 天，
后台故障为零。速度取第 5 天至第 180 天的 175 个完整间隔，每日只记一次时间，帧率由起止帧号取得。
新版两次分别为 19.53 和 20.50 天/秒，旧版为 12.25 和 13.13 天/秒，提升约 58%。
同一时段平均帧率从 25.13 降至 23.73 帧/秒。逐日状态对照另行运行。

无画面正常时钟三次测得 70.73–73.57 天/秒，中位数折合 13.86 毫秒/天。100 天/秒需要
10 毫秒/天。后台耗时与等待时间来自独立计数器，其取样范围与正常时钟计时不同。

国家数据校验按块处理空值和未占领地块。地块标签只检查该地形适用的规则，经济汇总仍按
地块顺序计算。年平均日照复用相同纬度和行星设置的结果，海面和风场的独立地块并行计算。
发起任务的线程也处理地块，减少短任务等线程唤醒的时间。无画面的 100 倍及以上会话
把 Godot 主循环休眠间隔从默认约 6.9 毫秒缩到最多 0.5 毫秒，代价是更频繁唤醒 CPU。
暂停、降速或最后一个高倍会话关闭时恢复原设置。

旧版用同一种子自然推进两次，第 2 天的天气就出现差异。当天气温和海冰使用了画面时钟的
小数日期，且下一天有时会读取尚未写回的天气。只固定输入日期时，两次运行仍在第 31 天
出现差异。年报在第 365 天补发天气也要遵守相同的日期和先后顺序。修正后，正常游戏时钟
分别以 50 倍、100 倍、100 倍加两个 CPU 加压进程推进 370 天，八个模块的逐日状态校验值和
完整经济状态校验值逐日相同。旧版原生库接收修正后的相同输入，也得到相同的 370 天结果。

完整玩家场景还有两个无画面模拟不会触发的读取时机。加载画面最先绘制的两帧曾让第 1 天
的气温随启动耗时变化。冻结开局时钟后，音乐和剧情的事件确认编号仍可能不同。首位读者
释放当天的记录后，另一个读者有时要等到下一天才能确认这批事件。两者现在都在整日结算后
读取同一份记录，各自确认进度。1600×960 的真实玩家窗口以 50 倍、100 倍和 100 倍加
两个 CPU 加压进程测试，连续 180 天的八个模块和完整经济记录逐日相同。

固定逐日输入后，Debug、Release、Release 加两个 CPU 加压进程的 365 天结果均与改前记录
逐日一致，包括八个模块、完整经济记录和 31 类地块储量。第二个地图种子的 90 天也逐日相同。
每天结算后读取军事详情的全年测试曾从第 96 天起出现国家校验值差异。额外加压时复现并抓取
当天记录，玩家国家少了地块 1595 的韧皮纤维植物线索（`bio.bast_fiber`）。手动推进关闭了
自动时钟，地块分批更新时，只算完第一批就进入了下一天。强制分批可稳定复现，军事数据始终相同。
手动推进现会用当天的输入完成全部地块。加两个 CPU 加压进程，同时跑四个四国世界，
分别采用 Release 强制分批、一次算完、自动选择和 Debug 自动选择。四次全年结果都与改前
参照逐日一致，包含军事状态。另对四次运行逐日比较了全图所有地块的物种分布，365 天均相同。

正式逐日结算、指令生效日期、读档续跑均通过负载对照。完整游戏存读档测试通过，读档后推进了一个
经济结算周期。气候并行对照与水文计算图测试的 34 项和 31 项检查全部通过。年报场景使用种子 `1728100280` 时，
新旧版均通过弹窗、领奖和存档测试。种子 `312061230` 在两版都会先触发另一个等待玩家操作的
暂停窗口，测试停在年报之前。曾试用跨文件编译优化，第 120 天出现国家状态差异，最终构建恢复
原编译设置。原基准的五处文件行数超限和独立气候测试的损坏存档断言仍可复现。手机速度待测。

本机原始数据位于 `/tmp/keynes-100d.bE2hMQsi`。测速见 `bio-screen-rates/comparison.json`、
`bio-live.json`、`bio-perf100/comparison.json`、`bio-perf365/comparison.json`。
正常时钟和窗口逐日对照见 `bio-verified/clock.json`、`bio-player/comparison.json`、
`bio-player-pressure/comparison.json`。国家差异复现见 `country-pressure-review/summary.json`
和 `bio-diagnosis/summary.json`，修复后的全年逐日对照见 `bio-verified/military.json`。标准地图
和第二种子见 `bio-verified/extra.json`。存读档与指令负载对照见 `multi-load/summary.json`，
完整游戏存档见 `game-roundtrip-verify.log`，气候与水文见 `manual-bridge-checks/summary.json`，
年报见 `annual-seeds/comparison.json`。

## 96×64 四国快进（2026-11-17）

Apple M2、Godot 4.6.3、macOS arm64 Debug，正式四国开局，初始人口 160，
种子 `20260718`，速度 50 倍。改前是上一轮已优化的本地版本，提前保留源码差异、
项目和运行库。原有无界面压测预热 5 日后交替运行三组，原 50 天/秒门槛与观察方式照旧。

| 观察项目 | 改前 | 改后 |
| --- | ---: | ---: |
| 100 日已提交天数/秒，三次中位数 | 38.73 | 62.33 |
| 100 日耗时，含预热，三次中位数 | 2.80 s | 1.80 s |
| 后台每日实际执行，三次中位数 | 14.97 ms | 11.38 ms |
| 后台每日额外耗时，主要为主线程服务等待，三次中位数 | 5.57 ms | 0.14 ms |
| 365 日已提交天数/秒，各一次 | 39.25 | 54.18 |
| 正常 WorldClock 推进 300 日，无绘制，各一次 | 47.45 | 49.04 |

改后三轮 100 日压测范围为 61.04–62.36 天/秒。100 日和 365 日压测均取得所需行数，
后台故障、回退、人口、货币和货物账本误差均为零。正常时钟按 50 天/秒发日，
当前无绘制路线实测为 49.04 天/秒。Debug 与 Release 两种运行库均已重建，独立项目
加载 Release 库后的 100 日无界面压测为 59.21 天/秒，改前、改后 Release 的 100 日
结果逐日一致，气候、目标标签、日尾和内联存读档四项用例通过。图形客户端和移动设备速度待测。

日输入完整检查后移入只读队列，河流下游检查不再重复走共享路径。天气和标签独立部分
使用现有线程池，原来的逐格计算与汇总顺序保留。已排队的思想刷新用原日期在日尾重试，
避免后续帧再次唤醒后台。结算周期、存档格式及过载时不追赶的时钟规则照旧。

大图每次逐日比对八个已提交域、经济整体校验和 31 类地块储量。等当天资源与军事收尾后，
三轮 100 日和一整年 365 日均与改前逐日一致，其中一轮 100 日同时运行两个 CPU 加压进程。
早期观察能在改前和改后读到资源仍为前一天的窗口，确认当天写回后读数一致。两个标准逐日
场景各重复三次，也与改前参照一致。高负载测试通过正式逐日结算、35 日命令及第 5 日读档后
续跑至第 35 日的对照。第 365 日自动存档后的连续运行、回放和读档续跑也通过。
20 项相关运行用例通过。原有文件行数检查的五处超限仍在。独立气候测试可链接，
既有物理存档末字节损坏断言仍失败，改前的纯气候测试同样失败。
Godot 气候权威、阶段顺序和日输入测试通过。

原始数据位于 `/tmp/keynes-50d.fIC9WJ6A`，包括 `paired/comparison.json`、
`paired-365/comparison.json`、`live-after/result.json`、`wide-tail-comparison.json`、
`wide-365-comparison.json`、`load-consistency/summary.json`、
`annual-replay/annual365/summary.json`、`release-perf/headless_session.json`
和 `release-wide-comparison.json`。

## 大图每日计算、加载和手机绘制优化（2026-11-17）

以 `6c87359d5` 为改前版本，由源码重建 macOS arm64 Debug 程序库。Apple M2、Godot 4.6.3、
96×64 四国开局、种子 `20260718`、50 倍速、预热 5 日后每次测 100 日。改前改后分别运行
三次并交替顺序。六次均完成连续 100 天，人口、钱和货物守恒，后台故障与回退为零。

| 项目 | 改前中位数 | 改后中位数 |
| --- | ---: | ---: |
| 已提交日吞吐 | 36.29 天/秒 | 39.31 天/秒 |
| 调度最慢单步的 p95 | 2.237 ms | 0.620 ms |
| 调度最慢单步的最大值 | 2.328 ms | 2.374 ms |
| 气候输入摘要 | 1.764 ms/日 | 0.314 ms/日 |
| 经济地块标签 | 1.853 ms/日 | 1.677 ms/日 |
| 经济日末收尾 | 1.641 ms/日 | 1.405 ms/日 |
| 静态地表贴图 | 2.542 s | 2.114 s |
| 地图生成 | 6.819 s | 6.392 s |

六次运行的 12 块静态贴图输出校验值逐项一致。改后实测为 38.77–39.75 天/秒，当前 50 天/秒
吞吐门槛仍未达到。表中单步耗时来自无界面调度记录。气候输入摘要的编码改变适用于本次运行的
封包校验，逐日业务结果用改前回放参照对照。证据见 `/tmp/keynes-all-perf.opEXgv/comparison.json`。

- 主模拟和表外推进各重复三次，逐日与改前记录一致。两路 CPU 加压下，正式日结、35 日命令及
  第 5 日存档后继续至第 35 日均与对应参照一致。真实 365 日自动存档与续跑对照通过。
- Metal Mobile 54 组和 OpenGL Compatibility 36 组画面对照逐像素一致，覆盖手机三个画质档、
  地表边缘、迷雾早退和陆水分层。半分辨率迷雾显示、隐藏、再显示的实绘覆盖为 15,360、0、15,360
  像素。手机真机帧率和发热留待真机采样。
- macOS arm64 Debug 和 Release 已重建。隔离项目加载 Release 库通过气候、目标标签、贴图和
  内联存读档四项专项。包括脚本原生访问和模块边界在内的 16 项静态与检查器验证通过。
  默认全量回归在 `6c87359d5` 上也能复现的 5 处文件行数超限处停止。80 格加载测试单独
  运行时两侧最长帧均约 124 ms，超过 100 ms 门槛。资源调度和水文用例的退出泄漏提示也在
  同一改前版本复现，断言在两侧均通过。

复验证据位于 `/tmp/keynes-all-perf.opEXgv` 的 `new-golden-*`、`new-load-consistency`、
`annual-replay`、`gpu-comparison.json` 和 `release-smoke`。

## 时代晋升人口与建筑门槛降到 1/3（2026-11-17）

`EraAdvancementCatalog` 的 `POPULATION_THRESHOLDS`、`POPULATION_PER_CELL`、
`BUILDING_THRESHOLDS`、`BUILDINGS_PER_CELL` 四张表按原值 ÷3 四舍五入下调（如首次晋升 10 格：
人口 750→253、建筑 3,000→1,003）。贸易次数、物资篮子与倍率、科技比例（0.6）均未改动；
服务层、条件投影、界面文案与存档格式不变，条件行仍读模型算出的门槛，已启动的晋升继续用
冻结地块数与冻结物资订单。规则表与 `docs/cpp-dots-runtime/era-advancement-runtime.md` §3.2
同步；同时把该文档与 `docs/architecture/feature-guides.md` 里残留的「科技 80%」改为当前代码
的 60%。

顺带修正 `tests/era/era_advancement_service_test.gd` 两条过期断言：HEAD 的 4015c5a89 引入
`_aggregate_buff_lines`（同主语+统计项跨里程碑相加）后，首次晋升文案由 6 条并为 4 条
（全社会经济产出 +14%），断言仍按 6 条写，导致该测试在本次改动前即 2 failures。现在改为
校验 4 条且含合并后的 +14% 行，`era_advanced` 载荷直接与预览逐字比较。

验证：`tests/era/era_advancement_service_test.gd` 0 failures；
`tests/technology/era_advancement_service_test.gd` 135 checks / 0 failures（两套均 headless 跑通）。
未覆盖：没有在实机存档上跑完整一代，无法确认新门槛下「三选二」是否被人口+建筑长期包办。

## 移动端 PR 提交前检查修复（2026-11-16，最终验收）

本节是下面两轮移动端记录之后的提交前状态。移动端优化本身沿用现有日计算；
为满足推送前修完已知失败的要求，本轮另行拆分了原生和脚本文件，并重新编译两种
macOS arm64 程序库。下文较早记录中的“原生库不变”和“检查尚被阻挡”不再代表
最终提交状态。上游基点为 `56f605f75`。

24 处文件长度增长超限与 5 项 C++ 依赖违规已全部处理。拆分位置见
[source-module-splits.md](source-module-splits.md)；状态、异步回调和公开入口仍归原宿主。
120 个原生成员定义保持原文，62 个脚本函数经明确的输入转发与类型补足后逐函数
对照一致，事件注册顺序及文字也一致。开拓人口槽预留的重复遍历合并，停止或继续
处理失败的策略由原调用方传入；家族载荷自己回答按归属分组的人数，人物声明按职责
独立。存档分支仍使用原游标、版本条件与末尾长度校验，没有改变公式或存档格式。

长度检查覆盖 1275 个文件，违规为 0；基线没有任何增长或阈值放宽。
依赖检查为 609 个引用键、437 个债务键，头文件暴露 484、总引用 2170，违规为 0。
搬迁记录由检查器登记来源；原审核基线的头文件暴露 520、总引用 2205 均已收紧。

另外修正两处过期测试目标：资源视觉按运行画质选择数量、移动 shader 档只选择预算，
测试增加正反两组断言；存档测试按上游实际写入的 PKEC65 建样，保留 13 字段精确
对照、冷/暖恢复、空表清理、损坏/缺段拒绝，并明确断言旧格式结构样本没有开拓记录。
该存档测试为 98 项断言、0 失败。首轮使用本地既有库曾出现启动保存边界失败，
用当前源码重建后定向和完整回归通过；未修改保存边界实现或放宽断言。

本机 Apple M2 / Godot 4.6.3 的最终验证：

- 18 项静态及检查器自测通过。正式完整回归 106 个项目用例及 4 项回放检查全部通过，包含真实 365 日运行。
- 主模拟、表外推进各重复 3 次；7 类命令各重复 3 次，均与当前源码重建后、拆分前
  保存的参照逐字段相同，无缺少的证据记录。
- inline、Android、iOS 选择路径和两次各 2 进程 CPU 加压的 Android 路径，
  各 30 日逐字段一致；运行期间源码与 Debug 库身份未变。
- 正式逐日计算、35 日命令，以及第 5 日保存后到第 35 日的两次加压冷恢复均通过，
  与相应参考逐日一致，命令日期不变。参考运行不声称整机空闲，压力覆盖及源码身份
  由检查器独立核对。
- Release 库经独立临时项目真实加载，10 个场景全部通过，涵盖启动/结算保存边界、
  存读档、执行器退出、世界重启、意见输入与原生视觉计算。
- 9 个家族、开拓、效果、触发、资源与聚落专项全部通过。

Debug/Release 均以 `platform=macos target=template_debug|template_release arch=arm64 dev_build=no`
构建；Release 首次构建的编译进程收到 SIGTERM，保留日志后用同样配置、`-j4` 重建成功。
最终两库 SHA256：

- Debug：`2deb294557277ca2c85e1d63716f176056e6a9eb55c545efdb9b71347c5fa4a6`
- Release：`b66ba82b6adbf4e452ab428889d7d386a6df2c15a240eeb2d2c55bdca01e0d9e`

仍未在 Android/iOS 真机上安装和测量帧率、内存或发热；平台选择用例在 macOS 上
替换平台判定，再运行真实会话及后台执行器。雨雪像素一致的 GPU 验证沿用下方原始
360 组证据，本轮职责拆分没有更改 shader；没有有效 GPU 计时，也不报告手机提速比例。
正式项目的 macOS FMOD 缺库属于原有明确禁用的平台音频路径，回归仍按已登记规则
识别这些消息；不能将本轮结果解释为完成了该平台音频验证。

本机证据：`/tmp/keynes-mobile-pr-validation.json` 汇总各最终检查命令和退出状态；
`/tmp/keynes-mobile-pr-*-verified/` 保存完整日志与结果，改前参照为
`/tmp/keynes-mobile-pr-source-before-{main,external,intents}.json`。

## 手机后台日计算与关闭云影后的风场（2026-11-16，后续修复）

同步到 `56f605f75`（仅清理构建产物和验证输出的跟踪；本机文件已备份保留）后，
先补复现再修复。关闭云影的生产入口原来调用 `clear_inputs()`，连同天气云共用的
风纹理一起清空，三个目标检查失败。现在 `weather_wind_source.gd` 独立管理同一份
当前/上一份风纹理和发布标记，由 CloudShadowField 持有并转发给天气云；
`clear_shadow_inputs()` 只停云影，`clear_inputs()` 才结束整个数据生命周期。
没有变化时不重复上传，新世界即使时间戳相同也重新绑定，不混合旧世界风场。
关闭云影后切画质、天气变化均不会重新打开云影视口。

手机原来默认强制 inline，整日十二域计算在画面线程执行；旧启动绕路晚于问题出现、
早于当前 RuntimeClockBinding 的会话级同步。当前启动入口已先创建执行器，再立即
绑定并同步暂停/速度，输入发布与后台日尾闸门也已有共同路径。本次取消手机强制
inline 的默认分支，使用现有 native worker；明确 `PK_MOBILE_NATIVE_WORKER=0`
仍可对照 inline。没有改 C++、公式、日计划、日期或保存字段，也没有新增执行器。
原生库不变。主线程的输入准备、已提交结果回灌、军事和资源日尾仍在原处。

目标测试把生产选择器的平台判定替换为 Android/iOS，随后运行真实会话、原生执行器、
暂停恢复与正式日期回调。改前 30 日均执行 inline，三个执行路径检查失败；改后
后台整日调用数为零，逐日的八域已有摘要、完整经济哈希和全部原始账目/市场字段与
改前完全一致。测试不假装在手机上运行，也不把后台线程吞吐计作画面帧率。

本机 Apple M2 / Godot 4.6.3：

- inline 参考、Android、iOS 和两次各 2 进程 CPU 加压的 Android 运行，各 30 日
  完全相同；`check_mobile_runtime_consistency.py` 保存逐日结果、实际压力和源码/库身份。
- 已有负载检查通过：35 日预约命令，参考与两次 CPU 加压；第 5 日保存、继续到
  第 35 日，与两次独立加压冷恢复逐日一致；完整观察期间源码身份相同。
- 八项定向检查通过：天气云/风场、时钟绑定、执行器边界、inline 四种存读档组合、
  正式保存协调器、世界重启、新旧时钟事件与过载恢复。无新增脚本错误和对象泄漏；
  正式项目仍有已登记的两份 macOS FMOD 扩展缺库错误。
- Metal Mobile 实际图形路径的云影/风场检查也通过。补查时复现测试自身被窗口初始化
  提前唤起、向尚未 ready 的根节点添加子节点失败；入口改为等待 root.ready 后通过，
  不采用等待秒数。最终日志为 `wind-metal-ready.stdout`。
- 静态模块地图、模块契约、脚本原生访问、模块接口、已提交视图、请求/应用、
  保存契约、跨域清单、运行开关及技能镜像检查通过。长度护栏仍有 24 个未改动
  上游文件超限，C++ 依赖仍有 5 项上游违规；没有放宽阈值。所改 water renderer
  已收回原长度上限。完整默认回归未通过这些前置护栏，不能称为全回归通过。

未打包或安装 Android/iOS、未测手机帧率/发热；后台执行消除的是整日同步调用，
不承诺所有主线程长帧均已消失。首轮本机观察中日回调平均 7.73→2.36 ms、最大
26.61→4.59 ms，仅作为该 40×28 场景的辅助数据；后台服务回调仍有 9.11 ms 的峰值。
证据：`/tmp/keynes-mobile-followup-20261117/`；移动逐日最终对照在 `mobile-final-check/`，
命令/冷恢复在 `load-consistency/`，改前失败在 `wind-before.stdout` 与 `mobile-before.stdout`。

## 移动端帧预算与天气、植被优化（2026-11-16）

基于同步后的 `31ebfda17` 复核并修改：

- 雨雪幕把逐像素重复的天气、视野纹理读取移到实例顶点；完全不可见的实例和透明
  边缘提前跳过绘制计算。雪花仍保留三层、全格随机位置、摆动与 3×3 邻格补画，
  只在候选不可能覆盖当前像素时跳过形状计算。同步 `Project/perf-validation` shader。
- Android/iOS 快进不再把默认 8 ms 帧预算放大到 20/40/60 ms。过载时实际天数/秒
  可能降低，游戏日期仍连续；一次同步日调用仍可能超过预算，不宣称消除了全部长帧。
- 删除“八秒且零实例就全量重建所有植被层”的路径。水域等合法空块也会触发旧路径；
  已有分块原生/脚本生成与零实例缓存足以处理正常补齐，不新增计时救援机制。
- 显式低画质关闭触摸端 2D MSAA，减少额外采样。自动/中/高档仍保留 2×；默认地图
  纹理密度仍为 16，保留之前为解决方块感和边缘闪烁做的清晰度选择。

先写的回归复现了改前 Android/iOS 快进预算扩大（12 项断言失败）和空植被误触发
全量 setup（1 项失败），改后分别为 0 失败。Godot 4.6.3/macOS 的 9 项定向检查通过：
mobile_clock_budget、runtime_clock_overload_recovery、runtime_clock_binding、player_clock_event、
detail_scatter_budget_slice（20 项，含无原生扩展时的分块脚本生成及空水域缓存）、
detail_scatter_visibility（9 项）、cloud_weather_quality、mobile_msaa_policy、visual_tile_layout。
两个新无界面测试已加入默认回归入口。

实际 GPU 绘制在 Apple M2 的 OpenGL Compatibility 与 Metal Mobile 下各检查改前/改后
90 组，以及裁剪 3×3/未裁剪 5×5 的 90 组；共 360 组逐像素一致。覆盖五种宏变体、
三层深度、多个时刻（含长时间值）、俯角端点、视野与天气过渡、雨/雪混合旗标。
一次更激进的计算重排只在 OpenGL 下通过，Metal 下出现差异，未采用该版本。
额外的 GPU 计时探针全部返回 0，不能用来推算速度收益。

`check_runtime_load_consistency.py --workers 2 --goals production_daily` 完成参考运行和
两次 CPU 负载运行，30 日逐字段一致，证据错误为 0，运行期间源码身份一致。
15 个静态护栏通过；文件长度护栏有 25 处既有超限，C++ 依赖护栏有 5 项既有违规，
均位于本次未改的上游内容。本次仅收紧变短文件的长度记录，没有扩大这些上限。
完整默认回归入口因上述护栏未通过而停止，定向运行另行完成。正式项目启动仍报告
仓库缺少 macOS FMOD 库；这些已登记的平台音频错误之外未出现脚本错误或泄漏。

上游新 Android debug/release 库均包含当前 661 个绑定方法名称，之前缺 27 个名称的
问题已不再复现；这只是二进制名称核查，不代表手机上的加载或性能验收。
未安装 APK、未做真机帧率/内存测量；没有修改 C++、模拟公式或存档字段。
本机日志、改前 shader、像素对照与负载证据：`/tmp/keynes-mobile-opt-20261117/`。

## 营造悬停卡的遮挡与缺口信息（2026-11-16）

`BuildingHoverCard` 的定位安全区改为当前 `BuildingWorkspace` 与 viewport 的交集，
不再让纸笺越过 `DetailShell` 压住右侧地块详情或在顶部被裁切。卡片收窄为建造决策摘要：
保留建造现金与工期，隐藏岗位/生产链长账单；不可营造时只列建材缺口数量及“市场无货”，
现金不足则标为“买不起”。缺口行由同一份已提交报价的 `materials` 与本地市场现货生成，
未改变经济字段、命令或存档契约。

验证入口为 `tests/ui/building_workspace_test.gd`（0 failures，包含卡片栏内约束、
可建空缺口、不可建缺口数量/原因和语义图标断言）与 `tests/ui/ui_scene_structure_test.gd`
（0 failures）。本机非 headless OpenGL 截图探针未能启动窗口，headless 探针只能完成
布局指标、无法保存纹理截图；未据此宣称完成图形验收，完整回归仍待后续批次执行。

## PR #7 审查后的季节日期与验证补齐（2026-11-16）

独立核对真实调用链后确认：输入日为WorldClock日期减一，因此完成日期写入 `day+1`
符合既有CLM2约定。新增真实Coordinator、WorldClock和植被输入构建的目标测试，
改前11项中4项失败，复现了提前输入仍读取显示时钟而重复计算植被，以及跨调用完成
后错误记录日期、重新启动同一轮。修复改为使用明确输入日期，并在续算完成后记录
同一日期。有限4100切片验证超过既有单次4096上限后仍能继续同一天；未采用跳日消费
旧环境或任意累计重试次数的方案。新测试11/11通过，已加入默认回归。

其他审查处理：一致性检查器8项单元测试加入PR的CI，负载采集移除BSD专用 `ps -r`；
共享存档段版本检查新增反例，修正family/ECP2=63与technology/PKCN=16。大存档测试
独立固定ABI4/schema63。混排预约与未指定日期命令的真实测试通过，原代码逐条使用
日期，没有改动命令规则；Country-only不推进经济轮次也已补断言。存档周期优先于
新profile的行为补了测试与契约说明；直接PKEC结构导入不代表历史PKSV迁移。

本轮验证：6项专项共613条断言通过，17项静态护栏、44项架构检查、14项证据检查、
8项一致性检查器单元测试全部通过。30日正式经济、35日命令均以一次参考和两次
7进程CPU加压比较；第5日保存后两次独立冷恢复第6—35日，所有逐日结果与不中断
运行及保存后继续一致。源码与Debug库全程不变，压力进程覆盖完整观察窗口。

本轮未重复完整102场景、365日和Release十场景；上一轮101场景及Release1356断言
证据仍见下文，不称作本轮重测。未重新计时，无新的性能结论。C++和库与
`3f96b84751fc41155b445af1dde54f6552b3321e` 相同；构建命令及两库SHA已补入PR说明。
本轮证据：`/tmp/keynes-pr7-review/consumer-target-before.log`、`focused-final/`、
`consumer-final/`、`architecture-final.log`、`high-load/summary.json`。

## PR 收尾：冷恢复加成与生产销售历史（2026-11-16）

提交前完整回归发现两项失败：goods_storage 仍断言旧的自适应周期；军事20日保存场景
冷恢复后第21日经济/国家结果不同。前者按已批准的逐日规则修正目标，仍保持原加压、
小批次和检查上限，247项通过；后者先保留原运行/重跑/暖继续一致而冷恢复不同的证据，
再逐阶段比较：就业、库存与资源输入相同，首次差异在建筑生产。NPC地块204/821的
国家商品产出系数原为75366、恢复为65536，导致产出6613→5751；开始第21日前完整
经济摘要与权威加成摘要均相同。

原因是 Host 尚未启动时根据旧权限选择经济加成读者，冷世界误读主线程显示副本。
改为使用已验证的启动配置，并要求 Economy/Modifier 同时由后台负责。随后用实际
读者查询补查，复现地块加成副本遗漏：派生层不在普通实例快照内，原目标51项失败2项。
修复在既有日边界内发布完整派生层及清空结果；改后51/51通过，192格的存在性、加值
与最终数值和主线程参考精确相同。新世界清理另有8/8检查。

同时发现生产者当期/上期可售量及商人实购量会影响下一日投入和机会报价，却未保存。
新原生目标通过真实保存/解码复现冷恢复全丢失，修复前2项失败1项，改后通过。
PKEC升至64、ECP2升至63，四列进入信号段与状态摘要；不扩展历史PKSV迁移。
动员保存回归97/97通过，包含冷/暖恢复、空段、缺段及损坏拒绝；没有放宽断言。

最终Debug完整回归通过：101个测试场景，年度自动保存、真实365日、检查点及4组回放
矩阵全部通过；静态护栏17项、架构44项和证据14项通过。加压目标三项均通过：30日
正式经济、35日命令及第5日保存后第6—35日的两次独立冷恢复，逐日完整结果一致；
每轮7个CPU工作进程，验证源码与Debug库全程不变。macOS arm64 Debug/Release构建均
成功；显式加载最终Release库的10个场景、1356条断言全部通过。未重测最终性能，
此前单组速度观察保留为PR收尾前数据；大图、多年及完整图形长时间负载不在本轮范围。
最终Debug SHA256 `c92585cbaa2aff07391549afafed2fd61f0e04e5b3b141a4e2333158b63a1458`；
Release SHA256 `5f311a4b26505dfe441688b6b8bf59ea0c37f1790d41f4faaa8018d5335ffe4d`。
证据：`/tmp/keynes-pr-20261116/`，失败见 `full-regression`、`derived-reader-before.log`、
`producer-target-before.log`，专项修复见 `final-focused-retry`，完整回归见
`final-full-regression`，加压见 `final-high-load/summary.json`，发布版见
`final-release/report.json`；汇总为 `final-validation.json`。

## 固定逐日经济与冷启动续跑修复（2026-11-15）

实现已完成：生产、消费、价格固定按一日计算；规划/投资按配置固定周期，默认10/30日。
耗时估计只作诊断，开局首日和新出现人口的地块不额外补一天。Country明确预约的命令
保留未来日期，普通操作仍在最早可用日执行；回执返回入队锁内确认的实际日期。
命令组装分别收拢到 Country 的值打包脚本与原生命令文件，未新增状态所有者。

读档先查明后修：保留旧源码/库，仅加临时逐字段诊断，原规则第13日23093个标量输入中
三项值不同，均为地块247的职业动员行玩家标记（1→0）。冷启动跳过bootstrap，国家
解码没有重建开局国家槽位，经济捕获到-1，因此把玩家当作AI。PKCN16已有稳定国家
顺序，两条开局路径均把开局国家放在槽位0；修复在配置/重置清理身份，在恢复和只读
副本安装时重建身份。未改存档格式，未放宽比较字段。新增冷恢复身份用例在旧库失败1/13，
改后13/13通过；临时散列打印已移除。

定向回归12项全通过，覆盖：固定周期与33个逐日状态、冷/暖ECP2及损坏拒绝、国家命令、
GM实际日期、线程重启、内联保存、环境继续、财政续算、建筑，以及帧时钟正常→等待→恢复。
33日对比同时改变计时输入、工作线程启用和切片大小，逐日完整经济摘要相同。
帧时钟7检查确认已安排日连续、不重复、不因解除等待补跑未安排的现实时间；此项以明确
帧输入驱动真实WorldClock，未等同于图形客户端长时间运行。

延长至35日又发现气候慢层刷新计数未恢复：两次读档均从第31日开始分叉，原运行
`season_ran=1`、恢复为0。计数原本累加调度器探测次数，既未保存，也会受预算跳过影响。
修复为普通Climate ACTIVE在输入采集时按固定游戏日刷新，周期30时为31、61……日；
复用CLM2已有完成日期去重，不改格式、公式或刷新内部顺序，保留切换时已有轮次的续算。
旧实现269项中失败3项，最终270项通过；气候修复前后的不中断35日结果也完全相同。

| 最终定向验证 | 结果 |
|---|---|
| 正式经济30日，一次参考、两次7进程CPU加压 | 全部逐日值与摘要一致，无账本错误 |
| 正式周期下35日命令，一次参考、两次加压 | 全部逐日结果一致，预约生效日与实际回执正确 |
| 第5日保存；不中断、保存后继续及两次加压冷读档 | 第6—35日全部已有域摘要、完整经济摘要、军事/资源及命令结果一致；保存不改变后续结果 |
| 12项原定专项＋气候日期专项 | 全通过；固定周期33日对比、帧时钟7项、气候日期270项均通过 |
| 17项静态护栏、检查器7项反例 | 全通过；架构44项及已有证据14项检查通过 |
| macOS arm64 Debug/Release构建与Release显式加载 | 双配置构建成功；指定Release库10项运行检查、1356条断言零失败 |

加压范围为正式40×28、40人开局，每次7个CPU工作进程，其他应用保持运行。完整批次为
`high-load-final`；最后补充已有刷新续算后，命令/存档在 `save-load-final` 重新取得通过，
两批均验证运行期间源码/库不变。生产30日结果不用于声称提速；规则已改为获准的逐日模型。
未运行本轮全量回归、巨大世界、多年或完整图形客户端负载测试，不能外推为所有路径已验收。
Debug用于上述定向与加压测试；Release经临时项目显式加载，覆盖开局/结算保存边界、
后台/内联存读档、执行边界、生命周期、规则/意见输入和两项原生显示计算。
Debug SHA256：`bdca1ac871fffe559ddd2b050c2d13ee6d8ba9bdfdfe4d978fdddcdbc5b68c43`；
Release SHA256：`f6646787837147a9f11badec06823e241250d27d966e54b4ff95c1fff7404dc2`。
最终加压检查后只追加了两个默认测试登记，运行源码与已验证版本相同。未提交或推送。
证据根目录：`/tmp/keynes-consistency-fixes-20261115/`；各批次 `compact-summary.json` 可快速查看。

## 高负载目标测试与计算规则审查（2026-11-15）

按用户要求先加目标测试，在未修改运行实现、未重编译的版本上取证，然后审查输入、
计算、提交、发布及存读档流程。以下保留最初修改前的失败证据，修复结果见上一节。
用户已确认逐日结果一致优先；兼顾速度的方案见
[高负载一致性计划](../plans/high-load-consistency.md)。

环境：macOS arm64 / Godot 4.6.3 / template_debug，库SHA256为
`869eff22a7abba4d279ec6cd352397929b5f0a9a81273ebd70a905644c69da54`。
正式开局40×28、种子20260727、一个40人国家；这是CPU争用测试，不是十万格大世界验证。
参考运行不启动自有压力，其他应用保持运行，不能称为完全空闲。每次加压均有7个独立
CPU进程，从启动前就绪到Godot退出后结束，有实际CPU时间与工作量记录。
每个批次开始/结束均核对源码、内容和原生库指纹，未发生变化；批次间仅修正测试类型
声明并增加目标筛选参数，运行源码及原生库完全相同。

| 目标 | 实测结果 | 判定 |
|---|---|---|
| 正式周期下逐日一致，30日，一次参考与两次加压 | 三次均751项内部检查、0失败；两次加压均从第2日出现ECONOMY/事件差异，开局数据相同，30日每次账目均平衡 | 一致性失败，真实收支/库存不同 |
| 固定周期下命令顺序与生效日期，13日，一次参考与两次加压 | 三次完整结果相同，但每次有11条实际日期断言失败 | 没复现负载导致的命令分叉；发现日期承诺错误，不能判整项通过 |
| 第5日保存、继续到13日；两个加压恢复与一个不加压恢复 | 保存后继续与不中断的13日完全相同；三个恢复过程彼此相同，第6—12日与原运行相同，第13日整体经济摘要不同 | 续跑一致性失败，非仅高负载；具体不同字段未定位 |

**经济周期的因果链已确认。** `native_simulation_host_worker.cpp` 固定日输入和命令后，
`native_simulation_host.cpp` 依次推进各模块，`native_simulation_stage_economy.cpp` 读取本日
已提交的气候与规则，在同一天续算经济。经济`aggregate_publish`完成后通过
`note_completed_epoch_cadence_ms`累计实际耗时；下一轮`lock_market_cycle`把该值转为
“每天可完成的工作量”，决定市场周期。`start_epoch`再按`cell % N`选择结算地块，
生产与消费也按本轮天数计算。因此耗时改变的是游戏规则，不只是何时完成。
第2日参考周期N=1（每份工作0.2ms），两次加压N=3/5（2.1/6.0ms）。参考起始地块
当天收入/支出原始值为202126/202126；加压该地块未结算，仍为499557/491075。
第30日同一地块资金为24330636、24281796、24196666。差异传播到Trigger第3日、
Ideology第17/15日；本窗口Climate、Country、Effect、Modifier摘要仍相同。

**命令日期的因果链已确认。** GM入口接受未来的`day`，并回报“已排入第D日”；
`world_runtime_gm_commands.gd`把日期交给CountryFacade，但worker拥有Country后，
`world_ext_country.cpp::enqueue_country_host_command_batch`把所有玩家命令日期统一改为
`command_seal_day()`，只在审计字段保留原日期。普通立即操作与明确预约操作共用这个
入口。实测第2日提交、回执承诺第4日的`Replay day 2`改名，第3日就已生效。
不能只改断言接受提前生效，也不能直接去掉所有日期调整而破坏已有迟到操作处理。

**存档继续差异尚未归因。** 三个恢复过程第13日`whole_economy_hash`均为
`7598317944556045667`，不中断及保存后继续均为`2099255115206109185`。
8个已有模块摘要、军事、资源与命令记录仍相同；已有逐字段追踪中的人口、资金、库存、
价格、需求、资源摘要也相同。整体摘要还包含家族、建筑、日期/版本与财政等状态，
不能据此断言存档丢失了某个字段，也不能因可见人口/库存相同而忽略失败。

新增`runtime_load_daily_test.gd`保留正式周期；旧golden默认仍固定周期、8日。
`committed_view_replay_test.gd`增加实际名称/生效日断言，全部旧检查保留。
检查器`tools/ci/check_runtime_load_consistency.py`不重试失败、不安装黄金基线，保留
原始输出、逐日结果、阶段追踪、保存文件与压力证据。7项新增反例检查和14项已有
证据检查均通过。第一批命令/存档未运行到目标，原因是新增GDScript变量类型推断错误；
修正显式String声明后仅重跑这两个目标，原始无效运行未删除、未计作业务失败。

证据：`/tmp/keynes-high-load-consistency-20261115/summary.json`（生产周期），
`/tmp/keynes-high-load-commands-20261115/summary.json`（命令/保存），
`/tmp/keynes-high-load-restore-control-20261115/summary.json`（不加压恢复对照）。
本轮未跑完整回归、release、长年数、大地图和部分权威模式；此前Modifier输入更新的
未修记录仍保持未验证状态。

后续讨论补充：用户指出旧版“追帧”可能一直追不上。设计改为不累积需要补回的现实时间，
性能恢复后回到目标速度；游戏日必须完整按序计算。代码审查确认当前`WorldClock`已丢弃
未安排的整数日，完整Climate ACTIVE worker也按环境输入每轮推进一天，不能把旧版
问题直接宣称为当前已复现。手动逐日驱动测试未覆盖真实帧时钟的过载→恢复过程，该项
留作重设计验收；运行实现尚未变更。

[返回专项记录总目录](feature-status.md#历史记录)
