# 资源显示、军务与存档续跑

## 资源视觉变化队列与共用帧预算（2026-11-15）

已实现：资源储量、生物占领、气候和新可见格通过 MapData 发布通知；图层合并完整扫描和去重的地块队列，扫描完成后停止空闲采样。气候变化单独更新记忆，不再重新计算 51 项丰度。观察、地表覆盖、实例生成及上传共用默认 0.8 ms 工作预算，原性能验收仍为 prepare + upload 的 p95 ≤ 1 ms。未修改样式、密度、实例位置、画质规则、shader 或保存字段。原生整数组发布仍触发完整扫描；精确地块通知用于视野和显式调用，不能把当前实现描述为所有资源发布均只处理实际变化格。

功能验证：macOS arm64、Godot 4.6.3、template_debug，资源显示 60 项、地表覆盖 23 项、变化处理 24 项、视野 55 项均零失败，无退出泄漏。相同的 `resource_visual_trace.gd` 分别运行在改前/改后版本；初始、资源变化、气候变化、隐藏、重新可见、隐藏状态恢复六阶段的全部实例数组、逐格样式/丰度/气候记忆及两张 CPU 纹理逐字节一致。新增断言覆盖空闲停止、持续稀疏更新不饿死完整扫描、过期上传作废、原生发布顺序和视野增量。视野 fixture 同时补上临时 `WorldRuntimeHost` 的释放，不改断言。

大小、C++ 依赖、脚本原生访问、模块登记检查均零违规。证据位于 `/tmp/keynes-visual-redesign-delivery/`。前后性能对比待无构建/无并行测试的独占窗口；CPU 内容一致性不能替代图形环境的 shader 和画面验收。

## 国库收支滚动窗口（2026-11-10）

国库顶栏悬停卡与经济卷宗总览不再把「最近一次结算」冒充当天流水。
`EconomyFiscalHistory` 现在同时保存逐已提交日国库现金与按财政 `sample_day`
去重的结算事件；展示层默认显示近 30 日日均，总览可切换近 7 日/近 30 日。
窗口内税种、补贴和非税支出先按真实结算事件汇总，净额再用国库现金首尾差校准，
差额单列为「其他国库变动」。历史不足时按实际覆盖天数折算；不足两个现金样本时
回退到最近一次结算，不补零、不伪造整月。折线保留逐日结算读数（未结算日沿用上次），
用于观察波动；
顶栏悬停与经济卷宗共用 `EconomyDossierViewModel.cashflow_from_history()`。

验证：`tests/economy/economy_fiscal_history_rolling_test.gd` 覆盖结算去重、无结算日、
7/30 日边界、历史不足、未归类现金变化和净额与国库差一致；`tests/ui/hud_status_card_test.gd`
通过。`tests/economy/economy_dossier_view_model_test.gd` 的滚动窗口与切换断言通过，
整页套件仍有一项既有的跨章区段滚动断言失败：断言硬编码要求滚动量大于 100，
而本次空产业台账下页面最多只能滚到 74；跨章跳转本身已落到产业章投资段。
C++、存档格式与存档字段未改。

## 派遣来源目录、进度与筹备缩编（2026-11-10）

已实现：目标入口直接按出发地分组列当地家族，使用地点与家族的组合身份；
顶部派遣按钮打开全国进行中队伍，按日事件、控制器绑定与命令回执刷新。
筹备详情保留当前队伍并显示三项实际物资进度、状态和采购阻碍；取消/召回放在
详情底部。紧凑视口保留两栏，极窄视口才上下排列；顶部空间不足时缩紧留白与字号，
派遣按钮保留文字入口，时代名回到宽视口显示。没有增加逐帧轮询或 UI 模拟权威。

Economy 筹备重验取 `min(计划人数, 当前当地可派人数)`，保留最后族人/商人与军人
排除规则；缩编后重算采购目标及进度分母。已有成交托管与在途采购续接保留，
后续只补实际缺口。状态沿用既有远征列，存档布局、跨域财政契约和 cadence 不变。
契约与回归入口见 [家族开拓运行时](../cpp-dots-runtime/family-colonization-runtime.md)。

验证：Windows/Godot 4.6.2，Debug `dots_ext_dispatch_v3` 与 Release
`dots_ext_dispatch_v2` 完成构建，人数缩减定向回归均零失败，实际出发后人口/货币/物资
误差均为零。来源目录/刷新/取消/顶部入口及 workbench 回归通过；1280×720、
2560×1080、1024×600 与移动 QA 档执行带渲染检查，含 125% UI 缩放和 10 倍速度。
全项目编辑器脚本编译无 Parse Error / Failed to load script / SCRIPT ERROR。
模块 API 与 C++ 依赖检查零违规。

共享工作区随后将正式 Debug 库切到 `dots_ext_supply_chain_v4`，在该映射下复跑人数
缩减专项仍为零失败。全项目编译时遇到同时新增经济历史脚本的两处数组元素类型推断
错误，只补 `Dictionary` 注解后编译通过；其视图模型测试的章节跳转断言仍失败，未改
相关导航逻辑，不把该测试报告为通过。

完整家族旧套件仍有 12 项失败；修改前 `dots_ext_army_explore_v14` 在同一内容与脚本下
也有全部这 12 项，另加本次新增缩编用例的 3 项失败；修复后这 3 项通过，没有新增失败。
旧失败涉及 worker authority、旧存档断言、开工包内容/落成、效果奖励等，不能宣称完整套件
已通过。PlayerController 旧契约测试仍有未改动的 `no frame polling` 失败。
渲染进程另有既有 FMOD 调试器注册/退出日志；截图与 UI 断言正常完成。
日志、基线对照与截图在 `.codex-temp/dispatch-20261110/`；UI 反模式扫描已人工复核
本次新增行，未将全库机械命中数当作本次缺陷数。

## 军事维护实物化（PKMI v6，2026-11-11）

军事维护从“现金账单”改为“实物采购与消耗”：需求 → 国库付款给商人 → 物资交付与运输 →
库存消耗 → 维修满足率 → 装备完好度或建筑失修。详见
`docs/cpp-dots-runtime/military-runtime.md` §5.4 与 `docs/plans/military-physical-maintenance.md`。

- Military 新增 `MilitaryMaintenanceRow`（按国家/地块/建筑类型与持有者/兵种分组）、
  `run_maintenance`、`get_military_maintenance_snapshot`；固定点余量 `acc_q32` 与 5 日窗口进存档。
- 采购走 opcode 37（`COMMAND_MILITARY_PURCHASE`）与 38/39 回执；`queue_purchase` 只登记订单，
  `settle_purchase` 才入库/建车队/记账，订单身份进 PKMI section 24。
- 预算顺序固定为 军饷预占 → 维护份额 → 一般采购，三者共用同一份冻结国库快照。
- 经济侧新增 `kind == 3` 显式跳过（私营建筑维护不得为军事建筑买单）。
- 验证：原生自检全绿（1500 日 AI soak `reconcile_max=0`）；三份维护验收用例
  （snapshot / flow / conservation）均 0 failures；种子 1812289715 的 60×40 世界跑到第 5500 日
  零错误、账目恒等式为 0。

## 军事维护回执与经济审计（2026-11-10）

`SPEND_CASH` 的 D+1 兼容路径仍调用 Country 财政 reserve/collect：先扣后加，
国库现金净变化为零。军事桥不再将返回额登记为货币销毁，经济也不再暂存这类
跨 epoch burn；正式 cohort burn 命令和零误差守恒故障保护保留。维护费真实终端
支出尚未接入，不能把回执金额当作已销毁现金。C++ 权威、周期和存档布局不变。
定向回归见 `tests/economy/military_deferred_cash_conservation_test.gd`。
Windows/Godot 4.6.2：旧 DLL 稳定复现 `money_error=1000`；修复后 Debug/Release
各通过 37 项检查，含待回执恢复、九日续跑和第十日真实 cohort burn。
正式 Debug 加载的 `dots_ext_supply_chain_v2` 亦通过该回归；Release 加载
`dots_ext_cash_audit_v1`。经济 cadence、parity（26 项）、merchant debt 回归通过；
市场综合测试 246 项中唯一失败为旧的 2x 产出断言与当前 1.5x 配置不符，
旧 DLL 同样失败。未宣称已恢复玩家当前被 fatal 锁住的进程或完整重放第 5447 日。
模块 API 检查与定向 diff 检查通过；UTF-8 模式的依赖检查在并行修改的
`economy_runtime_colonization.cpp` 报 FamilyMembershipEdge 7>6、总量 2182>2181，
本次未修改该文件或放宽基线。验证日志在 `.codex-temp/military_deferred_*.log`、
`.codex-temp/cash_audit_*.log`，构建日志在 `.codex-temp/military_cash_build_*.log`。

## DCWorldExt 模块绑定拆分（2026-11-11）

阶段 1 已将 646 条绑定按定义文件归属搬到 15 个 `world_ext_bind_*.cpp`：core 49、runtime 81、climate 75、economy 112、country 94、military 32、effect 37、modifier 37、ideology 30、trigger 24、events 13、generation 18、bake_encoders 7、visual 21、demo 16。绑定语句和模块内顺序逐字核对不变，说明注释随绑定移动。入口按该顺序调用模块函数，仅保留原来的 `using namespace godot;`，没有常量、枚举或信号等其他登记。绑定声明全部在原 public 区按模块分段，没有跳过项；非绑定声明、数据成员、访问级别及实现代码不变。清理搬移留下的空行后，头文件 4080 → 4050 行。

清单新增 `bind_file`，定义扫描排除绑定文件；新护栏检查文件归属、入口调用次数及缺失/多余文件，已加入本地回归和 PR 检查。8 个权威 skill 及镜像同步了绑定位置，country/modifier 的 PowerShell 检查改为扫描所有模块绑定文件。正式 `--sync` 同步也消除了这些 skill 的既有镜像差异，随后用 `check_skill_mirrors.py --write-baseline` 删除 23 条过期记录（49 → 26）；只收紧镜像基线，没有修改长度、依赖、游戏结果或方法列表基线。

已验证：macOS arm64 debug、release 串行构建成功；两份日志各有 14 条未修改文件的警告，没有本次改动文件的警告。16 个静态脚本逐个运行全部通过（架构测试 37 项、回归证据测试 9 项），清单默认及 `--audit` 均为 646 条、0 problems；`--json --refs` 输出与原清单除新增字段外一致。Godot 4.6.3 导出 646 个方法，`cmp` 与指定拆分前基线逐字节相同，SHA-256 为 `dab184126aadbd58fd5e2659397fd89729de581bf1583022b07bb874996c39a8`。构建生成的两个已追踪 macOS 程序库保留在工作区；运行检查日志在 `/tmp/keynes-binding-split-validation`。

额外检查：release 程序库的 8 项实际加载/运行检查全过；黄金主链与表外链各重复 3 轮，全部与既有基线一致，没有首个差异。默认回归 exit=0：86 个脚本、固定气候存档、10 日保存续跑、save1/calendar5/multicountry5/military20 回放矩阵、自动保存和真实第 365 日保存均通过，所有继续轨迹没有首个差异。未验证 Windows、Web、其他架构及图形界面，两个 PowerShell 脚本未在 Windows 实跑；未实施阶段 2/3，也没有改变数据归属或脚本接口。

## 大文件拆分（2026-11-11 至 11-13）

完成 G1–G5、C1–C7，规则并入 `development-guide.md`「机械搬迁与拆分」，计划文档已删除。GDScript 超标文件都降到 1700 行以下（`map_generator.gd` 22331 → 1672，期间删掉 GDScript 气候计算回退），最大协作者 `ideology_workspace_presentation.gd` 1782 行。C++：`runtime_climate_passes.cpp` 1212、`world_ext_climate_async.cpp` 1788、`country_runtime.cpp` 1018、`effect_runtime.cpp` 1542、`ideology_runtime.cpp` 415，`economy_runtime_building_investment_candidates.cpp` 2000。C8（其余 3000–4000 行的 C++ 文件）改到哪个拆哪个。

已验证：debug/release 构建与全部静态护栏通过；绑定方法 dump 改前改后一致（653 个）；黄金主链与外部链对拆前候选逐字段一致。搬迁中发现 `player_controller` 协作者把 4 个 player_view 存档键和 4 处日志文本误加了 `host.` 前缀，已修，扫描规则写入开发指南。

## 降雪散点显示（2026-11-09）

逐地块雪幕仍由 WeatherLayer 的 MultiMesh 和已发布 weather_lut 驱动。
weather_cell_curtain.gdshader 将格心附近抖动改为全格散点，按 patch/layer
旋转查找坐标，逐雪花独立摆动，并以 3×3 邻格补画跨格雪花；形状距离转回
世界方向，保留俯视椭圆及三层大小/速度/密度。移动/Web 同样保留完整散点，
不再缩小位置随机范围。没有新增模拟、存档或上传状态；性能验证项目 shader 同步。

Godot 4.6.2 / RTX4080 隔离 GPU 检查：五种宏变体、三层深度的 15 组空间
频谱集中峰值降为旧版的 0.004–0.174 倍；五组连续帧确认动画仍推进。
3×3 与 5×5 邻域在三层、三个时刻（含 12006 秒）逐像素一致，45 项通过；
五种变体实际天气 LUT/flag 雪幕路径均出图。上述 50 项在 OpenGL Compatibility
与 D3D12/Mobile 各通过一次。隔离脚本和对照图位于
.codex-temp/snow-scatter-20261109/。尚未覆盖实际手机、浏览器及正式会话长时间画面。

## 山地高度与烘焙起伏（2026-11-09）

原生 base 生成在 `world_ext_generate_base.cpp` 冻结山脊基底，按陆地 p99 分配统一增量比例；
必要时基底以海平面为锚线性缩放。只有顶部约 1% 使用导数连续的软收尾，
不再按地图尺寸混入旧的逐点指数压缩。`ridge_budget_scale`、`ridge_base_scale`、
`ridge_tail_cells`、`ridge_land_cells`、`ridge_elevation_cap` 由 base/full 结果包返回。
这一步改变权威初始 elevation，后续水文和气候仍在既有生成管线中重算。

terrain-index/fused geometry/visual tile 共同读取可选 `cell_landform` U8 SoA。
山地/高峰/火山将邻格起伏与两圈区域起伏合并，山地/高峰起伏下限为 0.055/0.080；
高原内部减弱细纹，陡坎仍由邻格高差驱动。三中心插值保持地貌权重连续。
主脊振幅系数 0.55、波长 2.4 hex、尖化指数 2.2、倍频增益 0.40；
汇流谷深/谷壁系数为 1.4/5.0，保留只降不升与陆地不低于水面的约束。
这些烘焙细节写视觉高度 buffer，不新增 DataCore slot 或存档列。
缺少 landform 的旧调用可继续按邻格起伏烘焙，非空错误长度明确 fallback。

Windows Debug/Release DLL 为 `dots_ext_relief_v1`，正式项目已切换加载路径。
定向测试 `tests/world/mountain_relief_bake_test.gd` 61 项通过，覆盖三尺寸、
三海平面、确定性、软收尾比例、平原/高原保护、经度周期与刻谷约束；
原生生成接口 32 项、地形边界索引 11 项通过。具体画面待玩家新生成地图验收。
扩大分块检查的 `visual_tile_native_bake_test.gd` 在地图边界尺寸不变性断言失败，
旧 `dots_ext_military_demand_v7` 与新 DLL 均为 ref=-0.146431/got=-0.103137，
未改该既有断言或将完整分块检查计为通过。
仅在临时夹具跳过上述既有失败后，其余分块测试通过，覆盖载荷、确定性、
分辨率一致性、边界距离、细节、运河补丁和 horizon 重采样；正式测试文件保持原样。

2026-11-09 天气云方块修复：低/中及移动/Web的廉价值噪声改为无循环的三角格点
梯度噪声，旋转第二层并取消零线折叠；保留分档/双相位。均匀天气GPU回归：
旧方格轮廓反例失败，新LOW/MID/Web通过；7天气变体连续性检查通过。证据见
[云Shader分档验证的后续修复](../cpp-dots-runtime/cloud-weather-shader-quality-2026-11-09.md#后续天气云方块修复)。

2026-11-09 云 Shader 分档：云影桌面 128×64 / 256×128 / 512×256，移动/Web
128×64 / 192×96 / 256×128；单相位云形采样2/4/6次。天气云LOW主云、MID加卷云、
HIGH加低雾；移动/Web均编译掉解析噪声栈，高档光照不再重复计算邻域云密度。
17个shader变体连续性检查119项与正式节点切档39项通过。RTX4080桌面GL、1600×900
隔离天气云HIGH GPU平均4.5855→0.6353ms；真机移动和浏览器未验。详见
[云Shader分档验证](../cpp-dots-runtime/cloud-weather-shader-quality-2026-11-09.md)。

2026-11-09 云影/天气云视觉平流：删除全图累计位移，改用局地风 + 24 秒双相位有界
位移和零权重重置；新旧风仅在显示端按天气提交间隔混合。天气云经 HexRenderer 的
信号连接复用云影已上传风 LUT，中云/卷云/低雾均接入，Web 裁剪卷云移除固定东向漂移。
Godot 4.6.2 / OpenGL Compatibility 隔离渲染探针：云影、桌面天气云、Web 裁剪天气云
共 21 项通过，周期边界和 12006 秒换风起点的最大像素变化为 1/255。反例仅恢复
风乘总时间，12006 秒换风变化达 0.768627，检查按预期失败。三个宿主脚本解析通过；
尚未覆盖正式会话长时间画面、移动设备性能和浏览器实际渲染。机制见
[云影的世界空间连续性](../cpp-dots-runtime/vision-fog-and-borders.md#云影的世界空间连续性)。

核查日期：2026-11-10。本页只写今天源码里是什么样，以及有哪些运行证据；目标方向见 [design.md](design.md)，迁移进度和待办见 [migration.md](migration.md)。代码与本页不符时以代码和可复现的运行结果为准。

范围：正式玩家会话请求 ACTIVE、十二域掩码 `0xFFF`。“请求 ACTIVE”“实际授权”“POD_ACTIVE”是三件不同的事。

19 处文件增长超限已按职责抽出 22 个脚本助手与 4 个 C++ 文件。
默认长度限制未修改，已有登记只收紧；新文件没有超限豁免。
诊断耗时桶与排版诊断标记分别只有 `WorldDayCostProbe`、`GameHudLayout` 持有；
原生世界、命令序号、保存段、生成算法、编译缓存与日推进所有者不变。
具体实现位置和回调边界见 [源文件职责拆分](source-module-splits.md)。
后续修复补齐后台/内联开局保存、未完成经济结算时的保存拒绝、正式读档继续、军事完整段比较、
军事建筑外观与植被节点释放。十组显示检查、时代推进服务与理念抽取流程已纳入默认回归。
固定气候样本以当前内容重建，保留旧内容拒绝测试。
OSOA4 块 13 保存已采样降雨标记与冻结门槛；旧 OSOA3 不兼容。

2026-11-08 经济平衡：C++仍为唯一结算权威，生存/生活需求评分寄生于既有市场循环。
基本生活采用75%需求均值与25%最弱项；适用且职业正权重的舒适/奢侈需求分别提供
70%→100%与90%→100%的综合分上限。环境需求恰为零时不制造最小需求。
正式失业计划补齐12类生活需求；开局规划已接入真实全局倍率并纠正软投入语义。
没有新增保存列、调度阶段、跨模块写边或第二套评分。数值、运行证据及尚未覆盖的全时代
校准范围见 [经济平衡记录](../cpp-dots-runtime/economy-balance-2026-11-08.md)。

2026-11-09 永昼视觉：共享日照 shader 按当地纬度与当日赤纬取正午高度
`max(10°, 90° - abs(latitude - declination))`，日内时角在 ±70° 内浮动，默认一个游戏年完成两个 Shader 日，按实际游戏日历进度映射，水面高光与实例层同源，GM 手动方向优先。
生产与性能验证项目的日历映射回归各 26 项通过，覆盖 365/360/10 日年历及固定日历时的倍速/帧 delta 独立性。
Shader 日/游戏年比例也已接入 HexRenderer.shader_days_per_game_year；生产/性能验证项目各42项通过，含小数比例跨年和运行时调参。
永昼调参已集中到 HexRenderer 的角度 export；实际 renderer/渲染层传参检查和 GPU uniform 调整检查在 Compatibility、D3D12/Mobile 各 43 项通过。
Godot 4.6.2 的 Compatibility 与 D3D12/Mobile 实际 shader 检查各 23 项通过；
地被桌面/移动/分块档回归 28 项通过。详见 [TOD 光照](../cpp-dots-runtime/vision-fog-and-borders.md#tod-光照)。

2026-11-22：地表覆盖边界优化。`ResourceGroundCover` 为每个覆盖格维护一张 R8
邻域差异 LUT，Shader 保留最近邻的群落 ID，只把该权重与已有地形 `edge_distance`
结合做连续透明度衰减。低成本路径增加一次 R8 LUT 读取和一次 `smoothstep`，不重新采样
邻居地被图层。默认边界混合强度为 0.85，旧的画质档位和 `[1, 1, 3]` 邻域采样配置保留。
本机未安装 Godot 可执行文件，未完成图形运行验证；已完成 `git diff --check`。

2026-11-23：海洋/海岸同属水面，但原有 `open_ocean_w` 只由水深决定，没有乘以
`water_ctx_type_mix(B_OCEAN/COAST)`。海岸主格中的远洋色块因此持续到主导类型切换，
造成接缝处的突兀扭曲。现改为复用已有主/次水体权重抑制远洋宏观色场，不新增纹理采样。

## GM 界面与事件屏蔽

正式玩家 GM 的 `ui.suppress_popups` 在 Host 设置后通过 `gm_toggle_changed` 同步到
PlayerController 的年度报告、叙事、时代奖励、家族创立和理念抽取流程。所有流程在展示前
拦截，并在开关运行时切换时清理已排队或已锁定的弹窗，恢复由弹窗持有的时钟暂停，避免
“屏蔽事件”仍偶发暂停。时代晋升大典也会只同步基线而不创建暂停演出。
另有 `ui.hide_all_except_gm` 开关，隐藏 HUD、面板、模态层和过场层，只保留 DebugLayer
中的 GM 面板；关闭后恢复切换前的可见性。
GM 总览的时钟诊断还显示 `last_pause_source`、`last_pause_day` 和
`authority_fault_hold`，用于区分 UI 自动暂停与运行时故障保护。
2026-11-20：事件弹窗改为「窗口开着就静置」。玩家反馈事件极端频繁、且每次都强行打断正在读的
窗口。根因两处：① `GameUIManager.show_narrative_event_offer` 在展示前直接
`close_country_panel()`，科技 / 经济(税收) / 军事 / 政治 / 外交卷宗被事件关掉；② 弹窗节奏按
游戏日计（全局 60 日 + 每格每年两次），x5 速度下 60 日只有约 12 秒。改法：窗口开着时不展示、
不改模态锁，由 `NarrativeEventFlow` 自己 `pause(true)` 并播一次提示音（复用已烘焙的
`ideology_reveal`，未新增 FMOD 事件），暂停快照在静置那一刻登记一次，玩家中途自己按继续不会被
按回去；窗口关闭路径（国家卷宗 / 营造 / 家族档案 / 军务档案 / 派遣 / 议和 / 史册 / GM / 时代
纸笺）回调 `GameUIManager.notify_workspace_closed()`，内部延后一帧重查，流程另有 0.2 秒兜底
重试。额度收紧为每格每游戏年一次，脉冲放行 25%→12.5%、AI 预热 4%→2%、事实 20%→10%。
同日再次收紧（玩家反馈仍太密）：脉冲 12.5%→6.25%，AI 预热 2%→1%、事实 10%→5%、局势上限
40%→20%。按脉冲模型估算两次弹窗间隔从约 220 天拉到约 380 天（≈ 每游戏年一次；x1 约 6 分钟、
x5 约 76 秒、x10 约 38 秒）；实际略高频于估算，因为事实通道与定时后续不走脉冲骰子。
`min_popup_gap_days`(60) 与 `pulse_interval_days`(20) 未动，本次只改概率，便于单独回退。
验证：新增 `tests/game/narrative_window_deferral_test.gd`（30 项）与
`tests/ui/narrative_workspace_gate_test.gd`（5 项，须不带 `--quit` 运行）；
`narrative_popup_suppression_test.gd`（24 项）、`narrative_event_runtime_test.gd`（108 项）、
`narrative_event_people_test.gd`（38 项）、`narrative_family_bridge_test.gd`（28 项）、
`narrative_war_bridge_test.gd`（21 项）、`narrative_effect_radius_test.gd`（47 项）通过。
`narrative_event_waterworks_chain_test.gd` 仍有 2 项既有失败：`narrative.levy.labor_satisfaction`
的卡面百分比断言（该 stat 是点数不是百分比）与测试内 `_stat_key_for` 映射表未覆盖该键，属内容/
用例漂移，本次未动。`player_country_ui_smoke_test.gd` 已按静置语义更新（待阅事件先决定掉，并断言
卷宗没被挤掉），但它在本机无头环境世界启动后即 ACCESS_VIOLATION（HEAD 同样崩），本机无法用它取证。

2026-11-19：恢复玩家叛乱事件链的会话接线。回归测试先复现了旧档已有第 4 阶动员却未投递事件，
再验证首次提交补发、弹窗暂停、玩家选择、升阶续接及待独立队列序列化。叛乱服务 15 项、
叙事运行时 108 项、弹窗屏蔽 24 项均通过，正式 PKSV 整档往返 0 失败。

2026-11-09：修正叙事自动确认未持有暂停锁却恢复默认「暂停 / 1倍速」的问题
（截图入口 `_restore_clock:125`）。恢复只消费真实弹窗或读档弹窗登记的
`restore_pending`，并保留其他弹窗忙碌时的延后恢复。验证入口为
`tests/game/narrative_popup_suppression_test.gd`（24 项通过）、
`narrative_event_runtime_test.gd`（36 项通过）和 `gm_runtime_host_test.gd`（PASS）。
GM 屏蔽开关返回补齐实际 `enabled`。未新增时钟或模拟权威；
扩大检查的 `player_controller_contract_test.gd` 仍有既有的逐帧更新约束及两项殖民派遣文案失败，未计为通过。

## 部队指挥 UI（2026-11-10）

已接入固定指挥区、路径/区域/探路草稿、显式确认/取消、停止任务与姿态。探路只生成中心 +
半径的选点并提交 `army.explore`，不调用路径预览；Native 任务、战斗暂停/恢复、返程与
PKMI v6 已落地（section 23 探路 / 24 采购订单 / 25 维护行），Host 只合并 explored-only trail。部队页为 520 设计像素单页，
军事权威与存档边界不变。输入/接线、原生探路集成、视野、存档契约及 1280/1920/520/21:9
真实渲染夹具已验证；100k 军事日 p95 与征兵 smoke fixture 仍未达标，详见
[部队自动探路计划](../plans/army-auto-exploration-plan.md) 与
[部队指挥交互](../ui/military-army-controls.md)。

## 军事长期失败清理（2026-11-13）

军事短测试已跟随当前接口和目录：render snapshot 替身改用 `render_snapshot`，兵种与科技
断言读取当前编译目录，纸片 fallback 允许新兵种，军队拆编在目标格没有 soldier cohort 时
使用随军 lane 自己的 signature。12 个专项测试中 9 个通过；原生自测和小图性能通过。
仍有三类未收口：100k 军事基准 p95 超过 2ms、活世界 smoke 的 Economy/Military 读数在
worker 延迟下不同步且中立空格 station 回流未读到、装备科技生产链一致性测试的 17 个内容
缺口。内容缺口保留给军事目录与科技树决策，不改基线。

2026-11-14：`military_index_continuation_test` 的原生自测（`military_core_selftest.cpp`）失败于
「army pay: 10 garrisoned at A, 40 with the formation」。单独编译 `military_core*.cpp` 跑自测：上游
origin/master 全过，本分支 HEAD 失败。回归由合并提交 cf14a1842 带入的 11-13 花名册修复引起：
`reconcile_soldier_roster` 新增的补齐分支（`total < expected_garrison` 时按 Economy 人数补 lot）
在登船回执落地前会把已登船的人头补回驻地。同一提交把 reconcile 挪到 `apply_due_commands`
之前，此时 `_lane_intents` 总为空，`pending_embark` / `pending_disembark` 的扣减不起作用。
删掉补齐分支和这两个变量后，单独编译的自测全过。经确认已删（2026-11-14）。同日按负责人决定，开局收编分支也删除：士兵只经 Military 的 ENLIST/LEVY 进入，Economy 的 `building_employment` 不再给 soldier 岗位和国家业主席位挂招聘与流动目标。

同日 `military_runtime_smoke_test` 的失败根因：ENLIST/LEVY 是 POD 行，worker 在发布第 E 天快照之后才执行
`commit_pending_commands`，所以第 E 天生效的转换要到 E+1 的提交才可见。桥
（`collect_military_economy_receipts`）在 committed == E 时回读到 0 人，末尾的纪元边界兜底块又把未结算的
POD 行判为失败。结果是 Economy 已转换、军事名册却被剥掉，配额反复打开：Economy 累积 30 名士兵，名册为 0。
此前的补齐/收编分支掩盖了这个错误。修复：POD 行等到 committed > E 再回读，兜底块只处理带 request_id 的旧入口行。
烟测的名册一致断言按核心对账规则改为「已提交人数 + 在途入伍 = 名册」。修复后 10 个军事测试只剩 100k 基准
p95 门槛失败（上游同样失败）；military 回放（22 天）与 military20 存档点续跑全部一致。

## 军需需求接入市场（2026-11-08）

已接通零库存军需报价、受资金约束的未满足采购预测、D+1 替换命令和 Economy 通用采购需求汇总；商人补货目标、生产规划与投资共享该汇总。预测只传递购买意愿，实际货物/现金仍由原采购结算处理。装备成交桥改传真实商品编号。继续态复用现有命令队列，没有新增存档字段。定向回归覆盖提前生效、撤销/重复/替换、零国库、未来需求 ECP2 保存及十日逐日完整经济哈希一致，并运行原生军事自测。

验证证据：Debug/Release GDExtension 均构建成功；军需定向用例（含完整原生军事自测）与整图 ACTIVE POD 用例通过。相同弓箭营地开局五日累计产量：无军需 12,745，有军需 15,895（GOODS_SCALE）。模块 API、C++ 依赖及 Resolve/Apply 检查均为 0 violations。本轮未跑全量性能/长年测试；行数护栏仍有 14 个未触及的既有脚本超限。殖民与科研采购的旧基线字节断言仍失败，但修复前 `dots_ext_equip_v1` DLL 与本次 DLL 的两份测试输出逐字段完全一致，未更新基线。

## 脚本侧原生访问护栏（2026-11-11）

阶段 2 第 1–2 步完成。核实 `Project/project-keynes/scripts/` 下登记目录全部存在；`events` 继续使用 `scripts/narrative`，依据是模块地图的 Events 脚本入口与该目录内的 narrative 服务/流程文件。`script_dirs` 使用相对 `Project/project-keynes` 的路径（因此写成 `scripts/...`），`demo` 登记为单文件 `scripts/main.gd`。本轮未改任何 `.gd`、C++ 或 `Project/perf-validation` 文件，也未迁移调用点。

新增 `check_script_native_access.py`，复用 `world_ext_bindings.py` 的绑定清单；扫描正式项目中的全部 `.gd`，排除 `tests/`、`addons/`、`.godot/`，并冻结 `tmp/` 中已跟踪脚本的现状。候选包括点调用和 `has_method`/`call`/`callv`/`call_deferred`/`Callable` 的绑定名字符串。最终接收者规则、facade 规则和词法限制见 [feature-guides.md](feature-guides.md) 的“脚本原生访问边界”。

首次基线为 49 个文件、102 个文件—模块组合、918 处越界。`--write-baseline` 只在首次生成或减少时写入；已有基线遇到增加仍失败。报告如下：

```text
script native access report (cross-module references):
core: 11 files, 217 references
   109 Project/project-keynes/scripts/geography/map_generator.gd
    40 Project/project-keynes/scripts/geography/hex_cell.gd
    24 Project/project-keynes/scripts/main.gd
    20 Project/project-keynes/scripts/rendering/map_baker.gd
    10 Project/project-keynes/tmp/family_baseline_test.gd
runtime: 6 files, 105 references
    87 Project/project-keynes/scripts/geography/map_generator.gd
    10 Project/project-keynes/scripts/geography/native_loading_tasks.gd
     3 Project/project-keynes/tmp/manual2_research_replay.gd
     2 Project/project-keynes/scripts/rendering/bakers/atlas_encoders.gd
     2 Project/project-keynes/scripts/rendering/map_baker.gd
climate: 2 files, 159 references
   131 Project/project-keynes/scripts/geography/map_generator.gd
    28 Project/project-keynes/scripts/rendering/map_baker.gd
economy: 14 files, 115 references
    61 Project/project-keynes/tmp/family_baseline_test.gd
    10 Project/project-keynes/scripts/geography/map_generator.gd
     7 Project/project-keynes/scripts/simulation/systems/economy_daily_system.gd
     7 Project/project-keynes/scripts/ui/economy_data_recorder.gd
     7 Project/project-keynes/tmp/preview_reference_both.gd
country: 15 files, 66 references
    24 Project/project-keynes/scripts/geography/map_generator.gd
    11 Project/project-keynes/scripts/game/game_save_coordinator.gd
     4 Project/project-keynes/scripts/game/save_modules/history_state.gd
     3 Project/project-keynes/scripts/game/runtime_forensics.gd
     3 Project/project-keynes/tmp/manual2_research_audit.gd
military: 3 files, 5 references
     2 Project/project-keynes/scripts/rendering/military_map_layers.gd
     2 Project/project-keynes/scripts/rendering/military_render_feed.gd
     1 Project/project-keynes/scripts/geography/map_generator.gd
effect: 15 files, 96 references
    22 Project/project-keynes/scripts/simulation/systems/effect_runtime_system.gd
    20 Project/project-keynes/scripts/game/world_runtime_daily_adapter_part2.gd
    12 Project/project-keynes/scripts/geography/map_generator.gd
     7 Project/project-keynes/scripts/game/game_save_coordinator.gd
     6 Project/project-keynes/scripts/country/country_facade.gd
modifier: 5 files, 16 references
     6 Project/project-keynes/scripts/game/save_modules/rules_state.gd
     6 Project/project-keynes/scripts/geography/map_generator.gd
     2 Project/project-keynes/scripts/simulation/systems/modifier_daily_system.gd
     1 Project/project-keynes/tmp/family_baseline_test.gd
     1 Project/project-keynes/tmp/modifier_catalog_probe.gd
ideology: 6 files, 29 references
    10 Project/project-keynes/scripts/geography/map_generator.gd
     6 Project/project-keynes/scripts/game/save_modules/rules_state.gd
     4 Project/project-keynes/scripts/game/world_runtime_daily_adapter_part2.gd
     4 Project/project-keynes/scripts/simulation/systems/ideology_runtime_system.gd
     3 Project/project-keynes/scripts/game/game_save_coordinator.gd
trigger: 8 files, 41 references
    11 Project/project-keynes/scripts/game/world_runtime_daily_adapter_part2.gd
     7 Project/project-keynes/tmp/technology_save_audit.gd
     6 Project/project-keynes/scripts/game/save_modules/rules_state.gd
     6 Project/project-keynes/tmp/manual2_research_audit.gd
     4 Project/project-keynes/scripts/simulation/systems/trigger_daily_system.gd
events: 4 files, 34 references
    20 Project/project-keynes/scripts/data_core/gameplay_event_bus.gd
    10 Project/project-keynes/scripts/geography/map_generator.gd
     3 Project/project-keynes/scripts/simulation/systems/gameplay_effect_system.gd
     1 Project/project-keynes/tmp/family_baseline_test.gd
generation: 4 files, 10 references
     4 Project/project-keynes/scripts/rendering/bakers/terrain_baker.gd
     2 Project/project-keynes/scripts/rendering/bakers/climate_baker.gd
     2 Project/project-keynes/scripts/rendering/bakers/terrain_index_baker.gd
     2 Project/project-keynes/scripts/rendering/map_baker.gd
bake_encoders: 3 files, 5 references
     2 Project/project-keynes/scripts/rendering/hex_renderer.gd
     2 Project/project-keynes/scripts/rendering/map_baker.gd
     1 Project/project-keynes/scripts/geography/native_loading_tasks.gd
visual: 5 files, 17 references
     8 Project/project-keynes/scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd
     3 Project/project-keynes/scripts/game/world_runtime_visual_adapter.gd
     2 Project/project-keynes/scripts/economy/economy_facade.gd
     2 Project/project-keynes/scripts/geography/native_loading_tasks.gd
     2 Project/project-keynes/scripts/simulation/systems/bio_occupancy_daily_system.gd
demo: 1 files, 3 references
     3 Project/project-keynes/scripts/ui/tile_data_recorder.gd
script native access guard: 603 scripts; 1408 native references; 49 files / 102 file-module pairs / 918 cross-module references; 0 problems
```

`--audit` 的精度统计为：2018 个候选；规则 a 命中 1216、未命中 802；规则 b 命中 1113、未命中 905；a-only 295、b-only 192、两者均命中 921、两者均未命中 610；计入样例和排除样例各 10 条已由命令完整打印。该统计是词法护栏的精度参考，不是运行时调用图。

验证：`check_script_native_access.py`、`world_ext_bindings.py`、`check_world_ext_bindings.py` 均通过；`test_architecture_guards.py` 为 43 项全过；其余现有架构护栏通过。除 `check_skill_mirrors.py` 仍报告既有的 1 条可收紧 baseline（`project-keynes-ideology-runtime/references/pitfalls-and-build.md`）外，其余现有架构护栏通过；本轮未修改其他护栏 baseline。

精度样例（`--audit` 原样抽取）：

```text
counted samples (10):
  Project/project-keynes/scripts/annual/annual_report_session.gd:90 [country/call; receiver=_ext; a=1 b=0; outside=0] _ext.mark_annual_report_presented(report_id)
  Project/project-keynes/scripts/game/game_save_coordinator.gd:552 [country/string; receiver=country_ext; a=0 b=1; outside=1] if country_ext != null and country_ext.has_method("get_country_peer_protocol_status"):
  Project/project-keynes/scripts/annual/annual_report_session.gd:21 [country/string; receiver=_ext; a=1 b=1; outside=0] if _ext == null or not _ext.has_method("configure_annual_reports") or handle == 0:
  Project/project-keynes/scripts/country/country_facade.gd:627 [effect/call; receiver=_world_ext; a=1 b=0; outside=1] return _world_ext.bind_era_reward_player_country(handle) if _configured \
  Project/project-keynes/scripts/game/game_save_coordinator.gd:553 [country/call; receiver=country_ext; a=0 b=1; outside=1] out["country_peer"] = country_ext.get_country_peer_protocol_status()
  Project/project-keynes/scripts/annual/annual_report_session.gd:27 [country/call; receiver=_ext; a=1 b=1; outside=0] var result: Dictionary = _ext.configure_annual_reports(handle, clock.days_per_year(),
  Project/project-keynes/scripts/country/country_facade.gd:628 [effect/string; receiver=_world_ext; a=1 b=0; outside=1] and _world_ext.has_method("bind_era_reward_player_country") else {
  Project/project-keynes/scripts/game/game_save_coordinator.gd:555 [country/string; receiver=None; a=0 b=1; outside=1] out["country_should_run"] = bool(country_ext.country_should_run(int(out["day"])))
  Project/project-keynes/scripts/country/country_ai_facade.gd:26 [country/string; receiver=_world_ext; a=1 b=1; outside=0] if _world_ext == null or not _world_ext.has_method("configure_country_ai"):
  Project/project-keynes/scripts/country/country_facade.gd:646 [country/call; receiver=_world_ext; a=1 b=0; outside=0] return _world_ext.get_country_report() if _configured else {"configured": false}
excluded samples (10):
  Project/project-keynes/scripts/annual/annual_report_flow.gd:55 [country/string; receiver=_host; a=0 b=0; outside=0] if _host != null and _host.has_method("mark_annual_report_presented"):
  Project/project-keynes/scripts/annual/annual_report_flow.gd:56 [country/call; receiver=_host; a=0 b=0; outside=0] _host.mark_annual_report_presented(id)
  Project/project-keynes/scripts/data_core/command_buffer.gd:63 [core/call; receiver=_world; a=0 b=0; outside=0] var occupied_idx: int = _world.entity_count() + _pending_create_count
  Project/project-keynes/scripts/data_core/dc_system.gd:98 [core/call; receiver=w; a=0 b=0; outside=0] var c: int = int(w.component_id(comp_name))
  Project/project-keynes/scripts/data_core/view_adapter.gd:252 [core/string; receiver=_world; a=0 b=0; outside=0] if _world.has_method("entity_count"):
  Project/project-keynes/scripts/data_core/world.gd:217 [core/string; receiver=None; a=0 b=0; outside=0] "entity_count": _entity_count,
  Project/project-keynes/scripts/diagnostics/daily_simulation_breakdown.gd:95 [core/call; receiver=_dcc_w; a=0 b=0; outside=1] if _dcc_w != null and _dcc_w.is_bound():
  Project/project-keynes/scripts/diagnostics/daily_simulation_breakdown.gd:265 [core/call; receiver=_dc_w; a=0 b=0; outside=1] if _dc_w != null and _dc_w.is_bound():
  Project/project-keynes/scripts/era/era_advancement_service.gd:178 [economy/string; receiver=_economy; a=0 b=0; outside=1] or not _economy.has_method("set_country_procurement_policy"):
  Project/project-keynes/scripts/era/era_advancement_service.gd:181 [economy/call; receiver=_economy; a=0 b=0; outside=1] var result: Dictionary = _economy.set_country_procurement_policy(_handle, true,
```

## 存档边界续跑修复（2026-11-12）

合并上游后，进程内存档续跑（checkpoint）与不存档的原始运行在气候域分叉。原因有两处，都已修复：

- `map_generator.gd` 的 `advance_save_boundary()` 构造 `SusTickContext` 时把季节相位和速度倍率两个参数传反。
- ACTIVE 模式下气候由 worker 负责时，主线程的原生日图仍会发布气候结果。现在 `native_daily_sim_job.gd` 在 `native_daily_climate_suppressed()` 为真时不启动新一轮，日图切片完成时按 `climate_authority_suppressed` 跳过气候相关发布。

验证（宿主机）：`check_committed_replay.py --checkpoint --trace --days 10` 四段一致；年度自动存档（`--autosave --year-days 16 --save-day 16 --days 24`）四段一致；`check_replay_matrix.py` 的 save2、calendar5 四段一致；三个存档边界测试和五个架构护栏通过。

未解决，推送前处理：

- 第 1 天存档在新进程读档后，第 2 天的 ECONOMY 哈希不同，第 3 天起恢复一致。原因是首日的视野解算顺序：原始运行在第 1 天结束前还没按玩家国家解算过战争迷雾，全图可见；读档后立即解算，只有玩家周边可见，殖民逻辑读到的视野不同。没有持久状态分叉，所以矩阵默认用例由 save1 改为 save2，没有为它增加存档字段。
- ~~multicountry5 的 checkpoint 在最后一天 EFFECT 哈希偶发不同；military20 的 resume 在读档后第一天 COUNTRY 哈希不同~~（2026-11-14 已修，原因是命令落地日取决于帧时序，见下文 golden 主路径一段）。

2026-11-14 单时间线迁移后的审查（Codex）又查出三处存档与重启问题，已修：

- worker 停在日尾闸门前时存档会照常出包：包的已提交日是 D，主线程第 D 天的日尾（军事、自然资源）却还没跑，读档又把日尾标成已做，军事与资源状态落后一天。现在 `service_save_request` 先等 `main_day_tail_pending()` 为假；主线程轮询存档时 `_process` 照跑，日尾会推进。
- 存档丢掉预取的未来环境帧，却保留了它们的发布水位（自 bc5ca724b 起就有）：读档后 `next_environment_day()` 跳过 D+1，worker 一直等那一天。现在丢帧时水位退回已提交日。
- 策略重启新 worker 时，主线程提交游标沿用旧 worker 的代数，新代数从 0 起，所有提交都被挡住，日尾闸门停住。现在启动前把 `_runtime_commit_generation` 清零。

验证（宿主机）：19 个存档、重启、执行边界测试全过；探针显示丢帧路径在 `runtime_opinion_input_lifecycle` 里走到，等日尾路径这批测试没走到。

未修：Economy 拿到的 Modifier 副本只在 worker 的 Modifier 阶段提交时刷新。Economy 归 worker、Modifier 留在主线程的部分权威模式下，主线程后来的 Modifier 改动不会进 Economy。默认整图两者都在 worker，不受影响。

2026-11-14 golden 主路径偶发分叉已修。复现：同一 DLL 连跑 3 次，第 2 次第 4 天 COUNTRY 分叉，第 14 号操作（DISCOVER）一次在封口日 5 送达、另一次在 6。根因是 Trigger 效果的交接时机：worker 上的 Trigger 发出 `effective_day = 事件日 + 1` 的效果，主线程在某一帧交给 Effect，Effect 镜像成 Country 命令，ACK 走 Trigger 队列。交接发生在日尾标记前还是后取决于帧时序，旧封口日取 `next_environment_day()`，它按帧时序跑在前面，所以同一条命令落在不同的日子。改了四处：

- 有日尾闸门时封口日 = `max(已提交日 + 1, 日尾完成日 + 2)`。worker 最多已开始日尾完成日 + 1，日尾完成日只由主线程推进，所以主线程在标记第 D 天日尾前从 D 派生的命令都落在 D+1。
- Trigger 队列的主线程入口 `queue_trigger_pod_command` 也取封口日，原来是 0（尽快）。worker 端的事件转发不经过它。
- `_mark_runtime_day_tail` 标记前先消费 Trigger 快照并交接全部待交效果（每次最多 512 条）；交接因拿不到边界锁而推迟时，日尾停在 D-1，下一帧重试。
- 删掉 `handoff_trigger_effects` 在 worker 暂停时拒绝交接的分支：worker 等环境帧时处于暂停态，这个分支让交接是否发生取决于时序。

新封口规则又带出三处问题，也已修：

- 读档续跑第 4 天 COUNTRY 分叉（committed checkpoint 和 save2 的 resume 段）。worker 启动时，日尾完成日取的是调用方的日历日，读档后日历比已提交日多一天，封口日因此晚一天，第 3 天交出的 Trigger 效果落在第 5 天，原始运行落在第 4 天。现在 `start()` 把日尾完成日设为起始的已提交日；存档前已经等过日尾。
- Ideology 队列的主线程入口 `submit_ideology_commands` 在 worker 拥有 Ideology 时也取封口日。原来按请求日执行，同一帧提交的 Country 科技授予被封口推后后，Ideology 的发现命令先执行，因前置不满足被拒（`runtime_economy_worker_restart_test` K3）。worker 上 Trigger 和 Effect 阶段写 Ideology 队列的路径不经过这个入口。
- annual 365 的 checkpoint 段第 366 天 ECONOMY 偶发分叉（全量回归里一次，追踪里少了 worker 当天的 `[economy-input]`）。worker 没有在途日时，`capture_economy_day_inputs` 会替它预采下一天的经济输入，读的是主线程气候槽；worker 自采时叠的是当天已提交的 Climate。年度存档那几帧 worker 停着，主线程抢先采了第 366 天，worker 就跳过了自采。现在 worker 拥有 Economy 时主线程只响应它的采集请求，不预采。

另有一处与封口无关：military20 两次全新运行从第 1 天起整体经济哈希就不同（12 次里 5 次），各域哈希和追踪都相同。分段探针定位到财政日志：同一笔 FISCAL_COLLECT 一次请求号 14/15，另一次 30/31，其他字段都一样。主线程入口（Country、Modifier 命令）和日执行者（Country AI、Economy 采购与资产请求）共用一个请求号计数器，开局主线程的 17 次取号插在 worker 取号之前还是之后取决于帧时序；请求号是财政日志的键，也进了哈希。现在日执行者用自己的计数器，号码打上第 62 位标记；两个游标都存进 TCQ1，读档时恢复出的号按标记回到各自的计数器。GDScript 按游标翻 Country 回执时 AI 回执本来就跳过，看到的仍只有主线程入口的号。

请求号修好后 military20 仍偶发整体哈希不同，EFFECT、EVENTS、MODIFIER、TRIGGER_INPUT 从第 2 天起不同。把 worker 首日人为推迟 300 ms 能稳定复现：命令环里多出 12 条 Country AI 决策（生产者 AIC1），都在 worker 第 1 天之前提交。根因在授权窗口：ACTIVE 请求某域后，`authoritative_domain_mask()` 要等 worker 第一次日提交覆盖它才生效。这段时间里，Country、Effect、Modifier、Ideology、Trigger、Climate 的主线程日入口和日图只看已生效授权，照常推进；它们产出的命令进了 worker 的时间线，进多少取决于 worker 首日何时提交。Economy 本来就按请求停推，不受影响。现在这些入口统一改查 `domain_main_thread_suppressed()`，域已归 worker 或处于授权窗口都停推，原来的 `domain_grant_pending()` 并进了这个函数。Economy 输入采集仍只看已生效授权。主线程不再重复跑 worker 的域，基线哈希因此变了。worker 首日推迟 0、300、1000 ms 时前四天哈希一致，AIC1 命令为 0 条。

验证（宿主机，授权窗口修复后）：military20 `--checkpoint` 4 并发 × 3 轮共 12 次，四段都一致，12 次全新运行的 28 天各域哈希逐字相同；golden 主路径 4/4 一致；意图基线 7 个夹具 × 3 次一致；`run_regression_checks.py --full` 90 项里 89 项通过，年度 365 天、续跑矩阵（save2、calendar5、military20、multicountry5）、committed checkpoint 都在内，只剩已知的 `military_index_continuation_test`（army pay 自测，见上文）；静态护栏全过。

未修：玩家视野解算（`_service_country_visual_refresh_budgeted`）按帧预算延后，解出的观测（`submit_observation_batch`）和发现信号的落日、所用的已提交视图都取决于帧时序，测试中尚未观察到分叉。

## 非玩家国家的采购政策（2026-11-14）

PR #6 第 14 项 T1。外国 AI 不再设研究日预算：`think_research` 先按目标算出研究份额（每日可支配现金的 bp，暂定 clamp 到 50–200），发 `CountryAiProcurementIntent`，由 Economy 的 `queue_country_ai_procurement` 下发 `set_country_procurement_policy(国库 10000, 研究份额)`；只在要开自动采购时发 9 号命令。pkai 读档和切换模式时按记忆里的份额重推。Country 的绝对研究预算（原 `1000 × MONEY_SCALE` 兜底）、`SET_RESEARCH_BUDGET` 和玩家的 `research.set_budget` 全部删除。

采购冻结为每国写 `_epoch_research_daily`：有政策且开着自动采购、还有未完成研究时按政策算；从未下发政策的国家按 profile 默认 200/5000 bp；关闭时为 0。财政的科研底线读同一个值，所以只在有研究排队时才扣。AI 当天的殖民意图在冻结前计入殖民需求，远征第一个周期不再拿到 0 预留。

验证：`runtime_country_ai_test` 18/0（夹具补了研究信号，否则 `available()` 为空、AI 无科技可排）；`fiscal_reservation_cash_cap_regression_test` 改为按研究份额 0/1000/10000 和真实入队的科技验证，通过；补贴在有政策的国家实测发放。`runtime_country_parity_test` 5 条、`economy_fiscal_reservation_continuation_test` 2 条失败与改动前相同，属第 9 项。未覆盖：AI 研究速度受科技点供给限制（约 8–10 点/日，石器科技 2100–6800 点），见 `gameplay-pending-decisions.md` 12e。


## 现代经济测试口径与默认国家的修正器挂接（2026-11-14）

PR #6 第 14 项 T5。`configure_economy` 在没有调用 `configure_country` 时会建一个默认国家，这条兜底路径原来没有把 Modifier runtime 挂到国家上。带 Modifier 的科技只有在 Modifier 应用后才激活，所以在这条路径上会一直停在待定状态。`world_ext_economy.cpp` 已补上与 `configure_country` 相同的双向挂接。这个问题是 `modern_economy_runtime_test` 的科技授予用例查出来的。

`modern_economy_runtime_test` 有两处改动：
- 夹具补了三个环境槽：`cell_temp_365d`、`cell_weather_type`、`cell_cover`。之前缺槽会报 `required_environment_slot_missing`，后面的账本和电力断言跟着连锁失败。
- 科技授予改为从目录反读解锁目标建筑的科技，补全前置后再授予；档位改为从升级族反读。

验证：
- `modern_economy_runtime_test` 117 条通过、0 条失败。
- `modern_economy_catalog_test` 5301 条通过、18 条失败，失败都是内容问题，见 `gameplay-pending-decisions.md` 12b、12g。

## 军事装备核心槽与低品级替代（2026-11-14）

PR #6 第 14 项 T2 的代码部分。`military_catalog.json` 的 49 个装备槽标了 `core`，每个兵种至少一个。采购只给核心槽买达到 `min_quality` 的商品；次要槽在同类里先挑达标的，再按价格和行号挑，买不到达标的就用低品级。训练单按槽记录实际交付的最低品级，lot 的战力按这个品级折算（kit 因子）。AI 按（类别，最低品级）估价，核心槽没有达标报价时跳过这个兵种。PKMI 升到 v7，保存 lot 的 kit 和训练单逐槽品级。目录编译器的 `slot_accepted_goods` 是审计测试与原生解析共用的接受规则。

产业链测试（`technology_industry_chain_balance_test`）的升级检查扩到单位工人产出、总产出、单位投入产出三项，并加了同时代雷同建筑的机械判据；军队装备槽算作硬消费后，26 条"商品没有消费者"闭合。现在剩 33 条，解锁一致性测试剩 16 个装备槽无可生产商品，都要改内容或数值，按维护者意见暂缓，见 `gameplay-pending-decisions.md` 第 4、6c 节。

`military_runtime_smoke_test` 在真实数据下仍失败于建兵营（`construction_materials_insufficient`）。根因不在 T2：8⑤ 取消材料组合并后，`warrior_lodge` 的 turf_block 单独成组，而草皮的科技不在兵营前置里，见待定文档 12b。把配方临时换成合并前的等价组后全程 0 失败，PKMI 往返也通过，数据已还原。排查时还修了测试自身的一处问题：拆编把 4 人的军队拆成 3+1，部分转移后拆出的军队就空了，后面的整编转移报 `command_unknown_army`；现在拆出的军队至少留 2 人。

同日 T1 引入的 5 处 Economy → Country 头文件依赖改为标量接口 `queue_research_procurement_policy`，`check_cpp_deps.py` 回到 0 违规。

## 读档后外国 AI 采购政策丢失（2026-11-14）

T1 之后 `check_replay_matrix.py --military` 的 military20 续跑在第 21 天起与检查点分歧，COUNTRY 与 ECONOMY 哈希每天都不同。用合并前的等价兵营配方跑检查点和续跑，逐日打印 `country_procurement_snapshot`：续跑后两个外国 AI 都变成 `policy_default`，研究份额从 50 bp 变成默认 5000 bp，研究日预算翻倍，第 21 天现金差 21，正好是一个居民组多出的收入。

根因在读档顺序。PKEC 先恢复，PKAI 恢复后按记忆把研究份额重推进 Economy 的采购收件箱；宿主启动 worker 时 `EconomyAuthorityTransfer::restore_before_country` 又把同一份 ECP2 套用一次，`prepare_restore_candidate_scratch()` 里的 `clear_procurement_runtime_state(true)` 把收件箱清空。改法与同一函数里保留 `_trade_topology` 的做法一致：二次套用前取出收件箱，套用后放回，放在期间新排入的请求之前；`requested_policy`/`requested_era` 以期间新排入的为准。

验证：同一场景 8 个续跑日的各域哈希和其余行字段与检查点全部一致。剩下的差异只有第 21 天快照里的 `research_cash_spent_last_epoch`，它是不存档的上期统计，不进哈希，第 22 天恢复。真实数据下 military20 的原始模式仍在建兵营一步失败，原因是待定文档 12b，与续跑无关。

同期修了 `building_visual_catalog_test`：8⑤ 之后目录列出全部建造材料组，视觉档位按"材料里的最高档"算，纺织厂因为一行钢材变成钢结构档，与电脑厂相同。改为按第一种（主）材料定档，与 8⑤ 之前的视觉结果一致。


## 经济输入准备性能改造（2026-11-15）

建筑升级链的固定要求改为每次配置整理一次，避免每格重新扫描目录；标签只计算实际消费者
需要的指标，仍访问全部地块；科技可用表和领土表以完整句柄及实际输入逐项比较后复用。
恢复与重新配置使派生缓存失效，不新增存档字段，不改变公式、结算顺序或地理标签范围。
第一轮仅缩小指标和缓存国家输入的收益处于噪声内；第二轮固定目录预编译才取得主要收益。

独立冻结的经济版本与改前版本完成各模式 3 组交替计时：60×40、4 国、开局人口 160、
seed 20260718、5 日预热后测 100 日。CORE 吞吐三次中位 28.706670 → 51.749201 天/秒
（+80.3%）；DETAIL 为 27.933967 → 48.271028（+72.8%）。DETAIL 三轮阶段均值的中位：
标签 14.824 → 0.756 ms、经济公式 19.272 → 4.732 ms、worker 总计 23.124 → 8.368 ms。
CORE 改后仅 2/3 次达到原 50 天/秒门槛，DETAIL 为 0/3；不能称为全部性能验收通过。
所有有效样本的账本、人口、货币和货物误差为 0。监测到外部构建重叠的样本另存，未按分数挑选。

黄金完整状态、表外状态各 3 次、7 类操作各 3 次，改前改后逐字段相同；诊断读取修复前会
在所有权交接前误读部分人口镜像，两侧采用相同的所有者读取修复，字段、顺序和日期保持不变。
聚焦功能检查 374 项通过。财政确认顺序的独立修复使 57 项续跑检查通过；它属于真实缺陷修复，
不能宣称所有旧错误行为也相同。原始证据在 `/tmp/keynes-perf-redesign-20261114/comparison.json`、
`golden-owner-comparison.json` 和 `economy-snapshot.json`；这些结果对应冻结的经济版本，
不能代替后续军事、视觉与线程交接修改后的最终版本验收。

## 军事性能改造（2026-11-15，前三轮阶段记录）

已接入按需周边范围、按付款对象分组发薪、单次战争汇总、交战成员反向索引、战线删除位置
索引和驻军链查询；进一步去掉同日战争输入重复复制，市场结构在单日内复用而每步额度仍
独立，空驻军地图从链元数据找候选。原 4165 行核心拆到存储、人员、命令、工资等职责文件。
目录数值、工作频率、处理顺序、PKMI v7 字段和 0.5 / 2 ms 门槛均保持不变。

三轮均使用原规模、每组 3 对交替计时。小场景为 2400 格、400 部队、实际 18 条初始交战边
（请求上界 64），第三轮 p95 中位 0.345 →0.332 ms，改后全部通过 0.5 ms。大场景为
99,974 格、2048 部队、4096 条交战边：第一轮 14.859 →5.158 ms，第二轮 4.872 →3.174 ms，
第三轮 3.195 →2.938 ms。各轮是各自的配对结果，不能把不同窗口拼成一次配对收益。
第三轮仍全部未达 2 ms；战斗阶段原约 10.5 ms 尖峰已降至约 1.33 ms。下一步应依据
子阶段证据定位剩余成本，不能提高预算或减少实际工作。

第三轮纯 C++ 自测 761 项通过，150 天逐日全字段与操作顺序、3 份完整存档逐字节一致；
三次大场景均为 76,067 操作、4,188 次占领、账本差 0，前后哈希相同。市场每次共建 30 次、
复用 30 次；驻军候选访问 61,440 条元数据、实际 head 为 0，替代原逐日扫描近十万空格。
军事回放军营夹具已补真实材料、确认建造回执和 4 名民兵，保留第 20 日存档与后续战争断言；
此前合并版本四模式对照和完整默认回归通过。这是第三轮的历史记录，当前修复与验证状态见文末本轮收尾。
证据 `/tmp/keynes-military-third-evidence-20261115/{validation,benchmark-comparison}.json`；
16 个既有“装备槽无可生产商品”的内容错误前后相同，未修改内容隐藏它们。

## 库存审计与线程完成通知修复（2026-11-15）

军需回归暴露两轮结算间 ADD_STOCK 的期初漏计：OwnedState 已写入货物，但结果接回未
登记变化位置，下一轮清掉显式增减计数后仍沿用旧结存。新增固定步骤自测在修复前稳定报
`owned_stock_audit_idle_opening_missing_800000`；ADD_STOCK / REMOVE_STOCK 接回各补一次
去重通知后通过，库存写入和显式记账保持原样。实际军需世界连续 30 日账目平衡，PKMI
保存/恢复哈希及重新编码字节一致，恢复后续跑 4 日仍平衡。该测试有 2 项明确跳过：未造出
付费未到货在途保存，以及缺少按采购类别拆分的财政明细；不能算作这两项已覆盖。
证据 `/tmp/keynes-perf-redesign-20261114/combined-military/stock-audit-evidence.json`。

主线程完成服务请求时，用等待线程同一把锁保护请求位清除，避免通知落在检查与等待之间。
真实方法体的 32 组受控交错和客户位隔离通过；去掉锁的负例按预期失败，既有 32 组控制
等待检查与全部 44 项架构检查通过。没有修改日尾顺序、理念刷新位置或 5 ms 等待值。
这些检查证明唤醒协议修复，不单独证明总吞吐收益；最终版本性能另测。

加压黄金检查还暴露首日取样竞态：启动线程可能已提交第 1 日，测试在调用 `_run_day(1)`
之前读取到 `commit_day=1/revision=1`，却据此声称第 1 日开始前已有民意。固定延后观察者
可在冻结经济版和当前版稳定复现同一失败，两版完整业务结果仍一致。测试改为保存每个
已完成日的民意供下一天核对，增加逐日发布与上一日来源检查；原有理念提交和来源断言
保留，第 2–8 日必须已有正确的上一日民意并完成提交。相同延后场景在两版均为
202 checks / 0 failures；修正前后四份
完整业务结果逐字段相同，未更新黄金基线。证据
`/tmp/keynes-perf-redesign-20261114/golden-opinion-observer-validation.json`。

## 加载目录准备改造（2026-11-15）

已接入请求内重复目录复用、实际行循环分帧、显示资料分帧与大型理念资源异步加载。
同步公开入口仍走相同编译体；默认内容在生成期间只读，显式覆盖资源按内容区分并冻结。
已验证 `loading_catalog_cooperative_test.gd` 2158 checks / 0 failures，逐字段比较
Economy、Modifier、Effect 目录、Effect 扩展和十一项显示资料；覆盖返回值隔离、覆盖输入
修改、编译中输入修改（包括独立 .tres 子资源）、profile冻结与取消；真实异步文件加载取消后，上下文释放且请求被完整回收。`runtime_loading_exit_test.gd` 14 checks / 0 failures（含目录编译中退出，世界与上下文均释放）。
代码长度检查 1192 files / 0 violations。证据在 `/tmp/keynes-loading-catalog-external-freeze.log`、
`/tmp/keynes-loading-exit-final.log`。这些是功能证据，不代替性能验收。

外部子资源冻结与暖缓存取消回收补齐后，已完成 24 次独立进程对照：冷/暖目录缓存、
两种地图大小，各 3 组交替运行。请求 8×6 被既有 MapConfig 钳为 10×8（80 格），
60×40 为 2400 格；两侧使用相同原生库、种子与原有门槛（p95 ≤33 ms、max ≤100 ms）。
改后 12 次全部达标，初始 Country/Economy 完整哈希一致。以下是三次运行的中位数：

| 缓存 / 实际大小 | 总时间改前 → 改后 | 最长帧改前 → 改后 |
|---|---|---|
| 冷 / 10×8 | 6.103 → 3.389 s | 2445.9 → 88.7 ms |
| 冷 / 60×40 | 7.864 → 5.107 s | 2489.1 → 86.5 ms |
| 暖 / 10×8 | 1.544 → 1.765 s | 72.3 → 68.3 ms |
| 暖 / 60×40 | 3.168 → 3.452 s | 73.1 → 66.3 ms |

暖缓存总时间没有改善，增加约 9–14%；两侧响应门槛均通过。冷缓存只指目录快照不存在，
未清操作系统文件缓存。完整样本、命令和进程监测在
`/tmp/keynes-loading-evidence-20261115/comparison.json`。测量脚本自身额外上报进度造成的
前两次无效尝试保存在 `instrumentation-invalid`，未放宽正式进度断言。

`loading_snapshot_cancel_test.gd` 10 checks / 0 failures，实际六文件异步批次的取消、
坏 .tres 加载失败均不发布半批结果，全部请求最终被回收，后续完整批次仍正常加载。
证据 `/tmp/keynes-loading-snapshot-cancel-second.log`，其中坏文件的两条引擎错误是预期故障注入。
失败面板既有测试通过；headless 下剪贴板和截图明确跳过。

## 理念派生日志层的四处静默失败（2026-11-16）

`docs/plans/agent-notes-tagstress.md` 在第 128 轮留下四条「顺手记录、未修」的产品缺口。四条都不是算错，而是**让失败读起来像成功**：一次被拒绝的 reconcile 在报告里和「这张卡什么都不做」没有区别；一个永远为 0 的计数器被当成「这一步没跑」；一个只被请求、永远拿不到授权的域在主线程上永久消失且没有任何报错；一次丢掉了在途折叠的 drain 返回 `{ok:true, complete:true}`。现在四处一起修。

**1. `step_effect_instance_refresh` 吞掉 reconcile 错误。** `ideology_runtime_effects_derived.cpp` 用局部 `std::string ignored` 接收 `reconcile_effect_activations` 的错误，失败时 `get_ideology_report()["last_error"]` 仍为空：`submit_instances` 被拒（列非法、行被拒、authority 不可用）时实例集合没变、签名也不会盖章，于是这次访问被计进 `instance_refresh_visits`、什么都没建，而报告一个字都不提。现在错误写进 `_last_error`（与命令路径同一规则），并新增 `effect_reconcile_failures` 计数。同一个静默也存在于 `reconcile_country_effect_activations`（读档收尾与 `reconcile_effects_for_test` 的入口），一并修掉。计数与 `last_error` 分开保留：`last_error` 会被后续无关错误覆盖，「曾经失败过」只能靠计数回答。

**2. `cell_layer_collect_count/_rows/_ideas` 是死计数器。** 三个成员在 `ideology_runtime.h` 声明、初值 0、在 `ideology_runtime_queries.cpp` 导出，**从来没有赋值**，报告因此永远读 0，会被读成「collect 这一步没跑」。现在在 `step_derived_rebuild` 的 collect 分支一次性写入，语义写死：`count` = 交给 fold 的目标格行数，`rows` = 去重后的（国家、卡、等级、program）行数，`ideas` = 至少产出一行的卡数；三者与 `_derived_collect_ms` 一起按天清零，所以「当天的 collect 没跑」读 0 是真话，而不是上一天的数字。

**3. `authoritative_domain_mask` 与 `domain_main_thread_suppressed` 的差异是静默陷阱。** 产品门是后者：ACTIVE 请求了某域、worker 还活着、还没有一日提交覆盖它时同样为真（授权窗口）。只按前者判断的调用方会对一个已经停推的域回答「主线程还拥有它」；而一个永远拿不到授权的请求（本会话没有一天提交）会把这个域永久丢掉，且没有任何报错——tagstress 的 12 条命令就是这样排队 30 天。现在启动回复、`get_runtime_thread_report()`、`thread_report` 与 perf snapshot 都导出 `main_thread_suppressed_domain_mask` 与 `authority_window_domain_mask`，外加具名的 `authority_window_blocker`（优先当日授权计划的失败原因，否则 `awaiting_first_commit` / `awaiting_domain_commit`）。掩码由逐域调用 `domain_main_thread_suppressed()` 本身算出，导出值不可能与真正抑制工作的门不一致。实现放在 `world_ext_simulation_host_internal.h`：`native_simulation_host.h` 与 `runtime_pod_protocol.h` 都已超 `check_size_ratchet.py` 的基线，往报告 POD 里加字段会让它们继续变长。

**4. `drain_derived_cell_layer(day)` 在静默重置后仍返回 `{ok:true, complete:true}`。** `step_derived_rebuild` 把「day 不一致」当成「epoch 输入变了」，清空累加器与 fold；drain 却只看剩下的 `derived_rebuild_pending()`。现在 drain 动手前记下在建的那一天（新增 `NativeIdeologyRuntime::derived_rebuild_day()`），跨天时返回 `reset:true, reason:"day_changed", discarded_day, requested_day`；循环里第一步的 `step_error` 过去被直接丢掉，现在作为 `error` 报出。

验证：

- `gdext` `platform=windows target=template_debug` 构建通过。
- `ideology_tag_snapshot_stress_test` **43 checks / 0 failures**（38 → 43，原有 38 条未改一字）：新增断言看到 `suppressed=0x802 window=0x802 granted=0x0 blocker=awaiting_first_commit`（0x2 CLIMATE 与宿主自动加入的 0x800 COMMIT 都在窗口里，未请求的 IDEOLOGY 不在），以及错误日 drain 的 `reset=true reason=day_changed discarded=31 requested=30`。
- `ideology_b10_multi_country_test` **24 checks / 0 failures**（+2）：`cell_layer_collect_count/rows/ideas = 3200/2/2`（两个国家、两张卡、各 1600 格），正确日的 drain `reset=false`。
- 静态护栏 `check_size_ratchet.py`、`check_cpp_deps.py`、`check_module_api.py`、`check_module_map.py`、`check_world_ext_bindings.py`、`check_script_native_access.py`、`check_module_contracts.py`、`check_committed_views.py`、`check_runtime_switches.py`、`check_save_contracts.py`、`check_cross_domain_inventory.py`、`check_resolve_apply.py` 全 0 违规。`test_architecture_guards.py` 42/43 通过：失败的 `test_control_wakeup_check_to_wait_transition` 与 `test_trace_paths_and_artifact_detection` 都要求用 `clang++`/`g++` 现编 `gdext/tests/*.cpp`，本机没有这两个编译器（`shutil.which` 返回 None），改前改后一致。
- 回归对照：`ideology_b1_many_countries_test` 有 3 条失败（`last_error='ideology_support_threshold_not_met'`、每国 8 张而非 12 张、总计 512 而非 768），**与本次改动无关**——把 `gdext/src` 暂存回基线重建后逐字相同，属既有内容/阈值问题，另行处理。

未覆盖：`effect_reconcile_failures` 的正例（一次真被拒绝的 reconcile）没有夹具主动触发，只由代码路径保证；`authority_window_blocker` 的「当日授权计划失败原因」分支同样没有夹具（现有夹具都停在 `awaiting_first_commit`）。


## 四块性能改造本轮收尾（2026-11-15）


- 经济：按实际使用范围准备标签指标、复用临时空间、按完整输入复用国家派生资料、配置时整理建筑升级要求，并迁移日尾重复颜色编码。
- 军事：按需准备周边格、合并工资与战争扫描、维护反向索引、复用单日市场和战斗输入，保持原支付与处理顺序。
- 资源显示：变化通知与去重队列、完整初始扫描、共享逐帧预算、原生分段构造及新区域输入准备。
- 加载：请求内目录复用、实际循环分帧、异步资源请求及取消回收；保持正式默认加载入口。
- 修复同步上游发现的财政域准入、错误线程回调、动员保存段遗漏、恢复残留、同步新建国家首都字段遗漏及固定UI节点归属问题。

### 本轮已验证

- 调试版与发布版均编译成功。debug SHA256：869eff22a7abba4d279ec6cd352397929b5f0a9a81273ebd70a905644c69da54；release：2933423c1127bbdc45ee6a96f204bd27973b8dc80d3b8e10e784dd7560a0f294。
- 17项静态检查均已取得通过结果；修复后相关6项复核通过，没有提高大小或依赖限制。
- 13组定向检查全部通过：财政续跑57项、现金上限、动员保存97项、国家68项、建筑保存及恢复后生产、大文件保存9项、界面结构/顶栏/昼夜、军需维护、加载目录2164项、加载退出14项及取消10项。
- 军需维护保留2项明确未覆盖：付费未到货状态的保存，以及分采购类别的财政明细。
- 当前两臂军事纯C++自测354/791项通过，150天逐日状态、1747条有序操作和3份完整PKMI字节相同。
- 完成的定向检查期间，源码、资源与库身份一致；只新增合法导入元数据。

### 本轮少量性能观察

各做一对，原场景、时间门槛与工作规则未改。存在其他项目持续或间歇测试负载，没有把这些数据当作空闲环境的最终验收。

| 项目 | 改前 | 改后 | 边界 |
|---|---:|---:|---|
| 经济，60×40，4国，100测量日 | 31.595天/秒 | 58.325天/秒 | 两样本守恒及有效性检查通过；本次改后达到50天/秒，未重复验证稳定性 |
| 军事，99,974格/2048部队/4096初始交战，p95 | 25.448ms | 5.446ms | 状态、活动量、场景相同；本次仍未达到2ms门槛，负载会影响结果 |
| 资源显示，8000格/600帧，p95 | 2.941ms | 0.885ms | 改前3080实例/7区，改后3610实例/8区，不能称严格相同完工量对照；改后达到既有完整3610实例目标及1ms门槛，仍有观察扫描待处理 |
| 加载 | 本轮未重新计时 | 本轮未重新计时 | 当前加载功能检查通过；旧独立版本24次对照保留为历史，不套到新上游 |

历史加载对照中，冷缓存60×40总时长7.864→5.107秒、最长帧2489.1→86.5ms；暖缓存总时间反而增加约9–14%。这些属于同步c7之前的版本。

### 未完成的验收

本轮没有完成修复后全量回归、年度自动保存/365日/完整回放矩阵、最终黄金/操作全集对照、修后发布版10项运行检查和各模块多轮空闲环境性能验收。上一轮全量回归的保存分叉虽已有根因修复和定向绿灯，不能据此宣布所有长流程都通过。之前年度退出出现过一次未复现的ObjectDB泄漏，未宣称已修复。无GPU帧率或截图视觉验收。

加载计时准备在改前复制项目导入阶段被日志检查拦住，日志所列为已有FMOD缺少macOS库错误；未启动本轮正式加载计时，未为此放宽正式项目检查。

证据：`/tmp/keynes-perf-redesign-20261114/limited-closeout/{validation.json,quick-performance.json,military-one-pair/comparison.json}`；完整失败与中止记录继续保留在上级upstream-final-validation、upstream-fixed-validation和upstream-fixed-build-interrupted-size。最终主工作区同步以 ../final-main-sync/applied.json 为准。未提交或推送。

主工作区已完成454项内容同步；分支、暂存区与用户universal库保留，未提交/推送。5945份已验证源码/资源及两份库身份复核一致；主目录资源导入与97项动员存档检查均通过。最终差异空白检查通过。

## 政体满意度幅度校准（2026-11-16）

体制章程卡的「拥护／反对」只读 Modifier 定义里的 satisfaction 条目，而两份政体条目原本是
±100~200 bp（100 bp = 满意度 1.0 点，满分 100 点）：低于一张限时叙事事件（±250~500 bp），
也低于理念卡等级项（±200~600 bp）。政体是唯一「无成本、全民、永久」的来源，但玩家在卡上
读到的只是 1~2 个点，改行前后难以察觉。本轮只改内容幅度与配套文案，**公式、通道、钳制、
存档列均未改动**：

| 阶层 | 早期氏族（旧 → 新） | 地方议会（旧 → 新） |
| --- | --- | --- |
| 佃农 / 农奴 | +150 → **+600** | — |
| 家庭小农 / 自给农民 | +100 → **+450** | — |
| 地主 | +100 → **+300** | −150 → **−600** |
| 商人 | −100 → **−600** | +200 → **+750** |
| 工业资本家 | — | +150 → **+600** |
| 工匠 / 熟练工 | — | +150 → **+450** |
| 工人 | — | +100 → **+300** |

改行一次的职业间落差因此为：商人 +13.5 点、地主 −9 点、佃农/农奴 −6 点、小农 −4.5 点、
工匠/熟练工 +4.5 点、工业资本家 +6 点、工人 +3 点（满分 100 点，社会压力五档分界为
20/40/60/80，可跨一档）。幅度梯与「政体核心阶层 ±450~750 bp、受损阶层至少 −450 bp」的
写作规范写进 [satisfaction-runtime.md](../cpp-dots-runtime/satisfaction-runtime.md)。

改动文件：`data/modifiers/default_modifier_catalog.tres`（12 条 term 与两条 description）、
`data/country/default_political_regime_catalog.tres`（两段 detail 文案）、
`tools/add_satisfaction_source_definitions.py`（生成器与目录同值，避免二次运行写出旧值）。

验证：`satisfaction_sources_runtime_test.gd` **107 checks / 0 failures**（原 91，新增
`_test_regime_balance` 逐阶层钉住出厂表 16 项）；`country_regime_runtime_test.gd`
**0 failures**；`politics_workspace_test.gd` **0 failures**（真实 Modifier 目录经
`RegimePresenter` 渲染，卡面显示 +6% / +4.5% / +3% / +7.5% / −6%）。
`tests/probes/probe_regime_balance.gd` 打印玩家可见表与改行落差，作为人工复核入口。

边界：bias 加在天花板之前，实际增量是 `min(raw+bias, ceiling) − min(raw, ceiling)`，
基本生活或舒适不足的阶层会被封顶吃掉一部分，所以名义幅度是上限；本轮没有跑正式开局长跑，
±6~7.5 点是否适合长期节奏仍需实际开局校准。内容身份改变会让旧档按既有规则被拒绝加载。

## 政体国策条目与卡面「国策」行（2026-11-16）

满意度是情绪通道，本身有天花板，撑不起「换一种国家」。上一节把幅度调到 ±6~7.5 点之后，
政体的另一半改成结构性乘数：`PoliticalRegimeDefinition` 的 `modifier_definition_keys`
本来就接受任意 COUNTRY 定义，`RegimeEffectBinding.reconcile` 也只按 key 应用、不筛统计量，
所以这次只加内容与展示，**没有改 C++**——六个统计量早已在 epoch 边界冻结成国家表
（`modifier_runtime.cpp` 的 `country_sector_output_factor` / `country_construction_cost_factor`
/ `country_trade_capacity_factor` 等），加行不产生热循环成本。

| 政体 | 国策条目（全部 MULTIPLY，常驻） |
| --- | --- |
| 早期氏族 | 全国建设成本 ×0.94（−6%）、农业部门产出 ×1.04（+4%）、社会领域研究效率 ×0.95（−5%） |
| 地方议会 | 国内贸易容量 ×1.08（+8%）、制造部门产出 ×1.04（+4%）、全国建设成本 ×1.06（+6%） |

两组各带一条代价（社会研究效率、建设成本），避免政体变成无脑最优解；地方议会的
建设成本上浮同时呼应它没有国库营造权。

展示链路：`RegimePresenter.charter_for()` 读同一批定义，用 `ModifierCatalog.present_stat_delta()`
生成「全国建设成本 −6%」这类文案（与理念/科技卡同一套措辞），并在 `LOWER_IS_BETTER`
里翻转成本/死亡率类的收益配色。卡面新增 `Margin/Column/CharterRow/Charter` 一行
（HFlowContainer 芯片，绿=收益、红=代价，悬停注明「体制常驻，相乘叠加」）。
权能行仍只列本国拥有的权能，失去的权能由改行代价提示说明。

验证：`satisfaction_sources_runtime_test.gd` **121 checks / 0 failures**（107 → 121，
新增 `_test_regime_charter` 14 项，钉住两份定义均为 COUNTRY 域、仅 MULTIPLY、六个系数逐值）；
`politics_workspace_test.gd` **0 failures**（真实目录渲染，地方议会卡恰好 3 条国策，
文案含「贸易容量」「全国建设成本」）；`country_regime_runtime_test.gd` **0 failures**；
`_probe_satisfaction_definitions.gd` **PASS**（目录仍全部可编译）。

改动文件：`data/modifiers/default_modifier_catalog.tres`（`regime.*.charter` 两组定义、6 条 term）、
`data/country/default_political_regime_catalog.tres`（两份体制各声明 cohesion + charter）、
`scripts/ui/regime_presenter.gd`、`scripts/ui/components/regime_charter_card.gd`、
`scenes/ui/regime_charter_card.tscn`、以及对应测试与 `tests/probes/probe_regime_balance.gd`。

边界：乘数与理念、科技、时代奖励同表相乘，2~8% 的实际价值远高于同点数的满意度，
所以没有按满意度的点数直觉给；本轮同样没有开局长跑，`1.08` 贸易容量若要收敛，先降到
`1.05` 再观察。满意度条目与国策条目共用一条「改行时整组换行」的生命周期，读档不重放。



[返回专项记录总目录](feature-status.md#历史记录)
