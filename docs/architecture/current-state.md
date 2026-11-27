# 当前运行状态

本页只写运行架构的现状。单个功能的现状与验证记录见 [feature-status.md](feature-status.md)。

## 十二域

经济上游冷启动仍在 `NativeEconomyRuntime` 内实现：多层派生投入进入同一格的
确定性队列，访问标记阻止循环回边；取样时由企业需求 EMA 重建空货架替代品的
冻结种子，并按真实投入槽活动约束数量。没有增加脚本模拟、持久列、API 或调度阶段。
定向回归覆盖零工坊/零采掘场、多层需求、首座实际产出、三账守恒及 scalar/worker
逐日全哈希。运行证据与完整回归限制见
[上游冷启动验证](../cpp-dots-runtime/upstream-demand-cold-start-2026-11-10.md)。

每日表在 `native_simulation_host.cpp` 的 modules 表，域内函数在 `native_simulation_stage_<domain>.cpp`。表顺序与 `runtime_domain_stage_order()` 由 `static_assert` 核对。

| 域 | 真正写入者与边界 | 对拍情况 |
| --- | --- | --- |
| INPUT_CAPTURE | Host 冻结输入清单与哈希 | 无双算 |
| CLIMATE | RuntimeClimateAuthority；plan/commit 在模块循环**之前**完成，表内只登记结果 | ACTIVE 关闭完整输出哈希 |
| COUNTRY | RuntimeCountryPodAuthority；`NativeCountryRuntime` 保留初始化、查询和适配，国家 dense 状态包含政治体制与能力位 | parity 钩子仍被调用；缺同日参考时报 uncompared |
| TRIGGER_INPUT | Trigger POD；ACK 等待等列出的原因可软完成 | ACTIVE 抑制旧 run_daily |
| IDEOLOGY | Ideology POD；首次快照未发布等列出的原因可软完成 | parity 默认关闭 |
| EFFECT | Effect POD 与 intent/ACK；同日重访幂等 | 影子推进只在 SHADOW 分支 |
| MODIFIER | Modifier POD；部分授权时仍可内嵌 Effect | 不走 SHADOW 管线 |
| GAMEPLAY_EFFECT | Host 解码、去重，排入 Events/Ideology 命令 | 无双算 |
| ECONOMY | StageOps 调度 `NativeEconomyRuntime` 的真实计算；POD_ACTIVE 时绑定 OwnedState | 默认 ACTIVE_ONLY；显式 ACTIVE_WITH_PARITY 才跑影子 |
| EVENTS | RuntimeEventsAuthority 写事件日志与消费者游标 | 沿用 `events_probe_enabled`，名称含 probe 但用于生产 |
| VISUAL | Host 产生刷新意图，`publish_day` 排序去重；实际显示归 Godot | 无双算 |
| COMMIT | 记完成位，检查请求域全部完成，由外层发布 | 无双算 |

政治体制不增加新的每日域。`NativeCountryRuntime` 保存 `regime_id` 与
`capability_bits`，`CountryReadView` 将能力位冻结进 Economy epoch；政治页面只聚合
Country 体制快照与现有 Ideology 快照。`treasury_construction` 在报价和结算两处均由
Economy 原生门控，UI 隐藏入口只负责展示体验。

非直观的地方：

- 默认请求 `0xFFF` 来自 `world_runtime_host.gd`；Host 的 auto POD 默认 false，正式 PlayerGame 明确设为 true，镜像完整且空闲边界满足后才切换。经济是“原计算实现 + 可切换的数据承载”，不是两份公式二选一。
- 模块表之前有气候实际提交，之后有 Events 补调用、覆盖检查和日故障点。这不是全域原子提交，COMMIT 完成位也不证明每个域都推进了业务状态。
- Ideology 的日内续跑门闩由 `DCWorldExt.ideology_needs_daily_continuation(day)` 提供；`map_generator.gd` 和 `IdeologyRuntimeSystem` 在旧版扩展缺少该绑定时探测回退，分别使用 runtime graph 的硬 pending 和当前 slice 的 `done`，避免保存边界因 DLL 与脚本不同步而中止。

## 阶层组织度（2026-11-13，M1 原生核心）

Economy 新增稀疏的 per-(地块 × 职业) 组织度表（`StratumMobilizationStore`，`runtime_economy_stratum_mobilization.h`）。行只在职业有不满或曾在链中时存在；更新复用 `publish_country_development_facts()` 既有的 `_market_cells × for_each_in_cell` 扫描，不新增全图循环，也不新增日域。阶段 0–4 与触发哈希在 `economy_runtime_stratum_mobilization.cpp`；跨阶发 `GAMEPLAY_FACT_STRATUM_MOBILIZATION`（事件 18 / payload 26）。

- 存档：PKEC `SCHEMA_VERSION` 64，`SAVE_SECTION_STRATUM_MOBILIZATION = 37`（稀疏行，跨 chunk）。
- Country：PKCN v16 新增每国 `capital_cell`；bootstrap 包可选 `capital_cells`，缺省回退首块领地；`CREATE_COUNTRY` 把首都设为新格。首都格的组织度封顶在示威（stage 3），不会走独立。
- Military：每日 ration 发布时顺带 sparse 推送 per-cell 驻军人数到 Economy 的 `_cell_garrison_heads`；割地路径的 `transfer_garrison_owner(from<0)` 修复为"该格全部驻军 lot"。
- 查询：`get_cell_mobilization_snapshot` / `get_country_mobilization_summary`；GDScript 见 `economy_facade.gd`。
- 玩家动荡的判定、叙事与效果由后台执行，国家转移和军事效果按提交日处理。地块档案、地图告警和顶栏展示后台发布的结果。
- 军事：`MCMD_WAR_DECLARE_FORCED = 43`（跳过攻方必须有兵）与 `MCMD_GARRISON_TRANSFER_CELL = 44`（清 controller、驻军随城转移）；独立后由原主权国强制宣战。
- 已验证：`country_capital_test.gd` 16/0、`satisfaction_runtime_test.gd` 58/0（含 9 项组织度/概率/结算）、`military_native_binding_test.gd` 自测 PASS（含割地转移与强制宣战）、`narrative_event_runtime_test.gd` 71/0、`stratum_unrest_service_test.gd` 7/0；地块档案与地图层 parse PASS。
- 未实现：无（长跑平衡校准可作为后续平衡工作）。黄金 v4/v2/v3 与外部位移 v5 已按 5 次捕获更新并通过：`golden_day_hash_test` 176/0、`golden_external_advancers_test` 338/0。详见 [stratum-mobilization.md](../cpp-dots-runtime/stratum-mobilization.md)。

Android/iOS 与桌面现在默认使用同一 native worker 执行十二域日计划，取消手机默认
同步执行整日的特殊分支；时钟仍由会话持有的 `RuntimeClockBinding` 在执行器启动后
同步并持续通知。主线程领取已提交的地图和显示数据，军事、资源恢复与视野随原生日计划推进。诊断时
`PK_MOBILE_NATIVE_WORKER=0` 或 `PK_NATIVE_DAILY_INLINE=1` 可选已有 inline 路径。
执行器及数据所有者没有新增，公式、日计划和保存格式不变；验证范围见 feature-status。

## 放行、命令与发布

桌面、Android 和有线程的 Web 默认由后台原生执行器推进。无线程 Web 调用同一张
原生日计划，在调用线程上完成结算。开局和恢复时，前台交付一次配置、地理和存档数据。
从首日开始，后台完成每日输入、计算、跨域交接和提交，无需前台确认日尾。

- **放行**。时钟按倍速和经过的现实时间给出允许结算到的日期。1× 时最多超前已提交日
  一日，后台可以在玩家查看当前日时计算下一日。高速时允许一次放行多日，最多到前台已领取日加八。到达放行日期、
  明确暂停、进入存档安全边界，或遇到待答复事项时，执行器在日界停住。
- **命令**。后台受理时立即取请求日、已封口日加一和已提交日加一的最大值，在回执里
  返回生效日。未受理的命令回执带原因。已排队的命令在生效日接受领土、科技和资源等规则检查，失败时发布结果。1× 下下一日若已封口，当前发出的命令最早在再下一日生效。
  同一份带生效日的命令日志在不同帧率和负载下逐日复现。外部命令按批发布，执行器按游标取走；
  封口、取收件和制作存档无需持有前台的受理锁。科技面板按终态的发布序号翻页，用请求编号关联结果。
  开拓在生效日复核当日路线、占用和人口，时代晋升在当日国家结算后、经济开始前处理采购请求。
  同日军费修改依序合并，超过 100% 的一条在结算时拒绝。
- **发布**。后台按日发布轻量记录，并保留最新的显示帧。主线程每帧一次取走全部可用日记录，
  保留逐日回执、账本和通知的顺序。气候、分类、资源和视野副本随领取安装。贴图跨帧积累变格，
  帧时间允许时读取最近已领取的生态贴图数据并应用。视野实际变化时同帧更新迷雾贴图及依赖图层。
  季节历史保留为整份只读数据，面板选中地块时才切出该格。
  无线程 Web 逐帧读取待处理的建筑显示地块，沿用同一套原生实例规划和区块上传。
- **等答复**。年报、时代奖励、剧情、家族扶持和理念候选都由执行器在提交边界判定和发布。
  同时待答时依次处理时代奖励、剧情及其外部输入、年报、家族扶持、理念。处理一项后可以在
  同一日继续等另一项。前台按发布原因开窗、转发答复和显示回执。年报状态和详情来自发布记录，
  确认失败保留待处理项。年报界面挂载或弹窗层恢复显示时，前台打开待展示的年报，玩家关窗后才转发确认。
  在途 AI 请求在读档会话绑定后交给请求客户端，回包仍按原定日结算。
- **候选**。GM 隐藏弹窗是有生效日的会话命令。生效后，玩家地块的家族候选保留并允许继续推进。
  理念抽取与重抽按实际受理日结算。手动暂停时，执行器自行放行到该命令的日期，候选发布后停住。
  关闭理念候选发送一次对应代际的确认，候选及手动暂停状态保留。0× 与手动暂停停止日历放行，
  待答命令仍可按其受理日结算。家族和理念候选保存在各自
  的原生存档段。关闭过的理念代际、待生效设置与命令所需的放行随 PKSR 保存。
- **剧情设置**。默认选项停住，通知继续。设置分别控制八个类别的选项与通知，共十六项，
  选择类不停时由后台自动选择。设置是有生效日的会话命令并随剧情存档。时代大典只控制演出，
  时代奖励的待答状态由执行器处理。
- **外部 AI**。后台在请求日取样并发布请求。普通 AI 回复固定在请求后第 90 日处理，
  普通请求之间至少相隔 60 日。预约后续在落地日前 90 日发出，预约时不足 90 日则当天发出。
  后续按原定日落地，预约独立于普通请求的间隔。可同时保存数条在途请求。前台发送 HTTP 并回送结果
  或作废。关掉本局 AI 后停止新请求，已发请求照原日期处理。后台在落地日根据目录和
  当日余额复核资格、货物和效果额度，该日缺回复时停在上一提交日。已发出的请求和已收的
  回复随剧情存档，有待回的请求按原内容和日期继续。全局 AI 偏好和本局已生效的设置各自保存。

验证范围见 [feature-status.md](feature-status.md)。

执行器打包变格、账目、通知历史和回执。领取推进时钟日期。贴图应用后推进界面显示日期。
贴图发布失败时界面日期继续前进，保留本批待显示内容以便在下一次可更新的帧重画整图。

## 十二域以外的推进

默认整图授权下，六项由执行器推进，两项由主线程领取。后台和原生单步共用日计划；单步时，同样的计算在调用线程执行。
`tools/ci/runtime_advancers.json` 是入口登记。后台入口在 `native_simulation_host_worker_section_run_authoritative_days.inc:121`，原生单步入口在 `native_simulation_host_commands_inline.cpp:198`。日尾顺序在 `gdext/src/native_simulation_host.cpp:382`，日计划通过检查后依次交付资源、更新物种、推进军事、更新视野，再经过其余日尾阶段发布。

| 推进者 | 执行位置与触发条件 | 读写与交接 |
|---|---|---|
| family | 执行器，经济 `FAMILY_COMMIT`（`economy_graph_stage_dispatch.cpp:270`） | 读经济中的家族、人口、市场及国家、修正输入，更新家族、分支、影响力和供行为取样的索引。 |
| person | 执行器，经济 `PERSON_COMMIT`（同文件第 292 行） | 读人物、家族和经济岗位，处理退场、任职、权益及晋升，更新人物和索引。 |
| natural_resource_recovery | 执行器，当日经济生产前恢复储量，日尾交付变格 | `economy_runtime_environment_capture.cpp:101` → `economy_runtime_building_commit.cpp:260` 根据储量、恢复参数、活动格和日期更新资源。登记入口 `native_simulation_host_day_tail.cpp:14` 收取经济增量与待显示格，随提交发布。 |
| bio_occupancy | 执行器，资源交付后，十二域全部完成且已装配物种（`world_ext_bio.cpp:319`） | 读当日气候、冻结地理、资源储量、经济引入的物种及原分布，逐格完成当天更新，每八日扩散一次。写入物种分布，把符合科研条件的新观察排到次日。 |
| military | 执行器，物种之后，已装配军事且整图已请求并完成（`native_simulation_host_military.cpp:139`） | 读国家、经济、修正、地形和此前已探索格；到期运行军务，更新军队，向经济交付驻军与配给，发出次日命令并转交军事事件（`world_ext_military_digest.cpp:403`、`:503`、`:511`）。 |
| vision | 执行器，军事之后，十二域完成且已装配视野（`world_ext_vision.cpp:556`） | 读领土、科技、部队位置与轨迹、物种分布。首次绑定玩家、领土、远程视野科技或部队源变化，或轨迹新增探索格时重算。写入可见格、探索格和迷雾，观察提交至 D+1。 |
| visual_delivery | 主线程，处理帧领取新提交（`world_runtime_daily_adapter_part1.gd:143`、`world_runtime_daily_adapter_part3.gd:36`） | 安装已发布的资源、物种和视野，交付逐日记录，按变格合并地图与贴图更新。 |
| climate_writeback | 主线程，领取新的已授权气候日（`world_runtime_daily_adapter_part3.gd:64`、`:161`） | 按日期与代数安装已提交气候快照，写回 DataCore 槽和 MapData，读档可从 CLM2 重建首次显示。 |

两个主线程项登记的 `world_runtime_host.gd:8` 和 `:9` 是存档前同步时的调用点；正常帧经 `world_runtime_adapters.gd` 转入上表的每日适配器。后台按当日冻结的温度和位置计算天气所需的热赤道，随日提交发布物理场和风轨迹。年度气候沿用环境输入日期，第 364 份输入采样第 365 日。地图专题图的共享纹理由显示会话核对有效性和格子顺序。地图天气和生态贴图可以跨帧合并，在天气插值读取前上传。海拔和风向专题图按各自的已安装数据刷新。

## 前台尚存的模拟工作

### 主线程镜像

PlayerGame 领取整图提交后更新国家读视图和 Modifier 镜像。`world_runtime_daily_adapter_part3.gd:118` 经 `world_runtime_daily_adapter_part2.gd:80` 调用 `world_runtime_modifier_writeback.gd:15`。适配器检查 Modifier 授权位 `0x040`，经 `map_generator.gd:79` 和 `map_rules_initializer.gd:99` 调用原生 `apply_runtime_modifier_snapshot`。

整图会话的全国、地块和综合面板从 Economy 冻结的税表读取税率和计税方式。已占地块即使当天无人纳税，也显示适用的税策。综合面板的国库、国家修订号和已完成科技来自已领取当天的 Country 日尾。

开局及读档首帧用同帧 Country 和 `ModifierReadView` 计算起始显示值。开局税率帧在执行器启动前校验。日常领取时先安装，再发 `map_fields_received`。税率帧被拒时，领取结果用 `modifier_display_error` 和 `modifier_display_retained_day` 报告错误及保留的税率日期，当天记录、地图和通知照常发布。帧末仍可查询已领取的税率。公开的修正求值、解释和列表等查询仍使用主线程镜像。

整图执行器在日尾更新 Effect、Trigger、Ideology 的规则对象并发布读视图。Effect 报告、Trigger 发展进度、Ideology 卡片与回执从这些视图取得。部分授权下，回退查询仍读旧适配对象，后台结果未进入这些查询时，读到的是开局、读档或本地适配的数据。见 [模块地图](module-map.md#每日域模块)。

### 日中途停等

正式 PlayerGame 已配置 Economy、执行器按默认整图授权启动时，经济阶段不会因缺少同日环境或建筑输入而向主线程请求采集。这个结论来自以下条件。

1. `world_runtime_generation_adapter.gd:289` 请求 ACTIVE、全部十二域和 ACTIVE_ONLY。第 313 行先安装开局环境，失败就返回。已配置的经济随开局环境获得经济输入（`world_ext_simulation_host_save.cpp:510`、`world_ext_simulation_host_save_section_economy_capture.inc:82`）。
2. 执行器从同日已提交输入或世界环境取得当日包（`native_simulation_host_environment.cpp:83`）。准备新一天时复制经济输入并改成当天日期（`runtime_world_environment.cpp:344`）。经济准备开新周期时先取已提交气候和执行器视野，按需采集环境和建筑输入，写入当日标记。错日或采集失败直接报告故障（`native_simulation_stage_economy.cpp:131`、`:186`，`economy_runtime_environment_capture.cpp:80`、`:95`）。
3. 已开的当日周期继续执行（`economy_runtime_epoch_prelude.cpp:60`），新周期检查上述日期（`economy_runtime_epoch.cpp:20`、`:76`）。兼容路径若缺同日输入才会写请求日。主线程经 `world_ext_runtime_graph_section_runtime_pulse.inc:173` → `world_ext_economy.cpp:442` 回应，由 `native_simulation_host_owner_ports.inc:78` 清除请求并唤醒执行器。

停等位定义在 `runtime_pod_protocol.h:47`。`0x08` 保留为空位，诊断中的财政和经济输入编号仍为 `0x10` 和 `0x20`。一个等待可设置多个位。日循环会把多类原因都记到计时项 `OTHER`（`native_simulation_host_worker_section_run_authoritative_days.inc:459`、`:492`），这项计时不能单独判断在等哪条线程。

| `RUNTIME_DAY_STALL_` 后缀 | 置位点或报告条件 | 谁在等 |
|---|---|---|
| `CLIMATE_CAPACITY` 0x01 | `native_simulation_host_worker.cpp:181` 读取报告时发现环境队列已满。 | 兼容投递方等执行器腾出空间。正式世界由执行器准备逐日环境。 |
| `COUNTRY_PEER` 0x02 | `native_simulation_host_country_stage.cpp:514` 等到期资产的最终结果，`:584` 等国家意图回执；`native_simulation_host_worker.cpp:187` 也会按待决意图数报告该位。 | 整图内 Country 等 Economy 或 Effect。部分授权可由前台适配器交付结果。 |
| `EFFECT_ACK` 0x04 | `native_simulation_host_country_stage.cpp:584` 与 COUNTRY_PEER 一起设置。路径分流在同文件第 206、276 行。 | 全授权时 Country 等执行器内的效果回执，旧适配路径可等前台交付。 |
| `FISCAL_PEER` 0x10 | `native_simulation_host_country_stage.cpp:514`；`native_simulation_stage_economy.cpp:99`、`:116`、`:347`、`:380` 分别对应气候未完成、缺经济对象、已知资产或科研等请求、其他输入待决；整日循环在经济未完成且缺少具体原因时也置位（`native_simulation_host_worker_section_run_authoritative_days.inc:350`）。 | 正式财政路径在后台协调 Country 与 Economy，另有未就绪和未分类原因。单看此位无法判断是否在等前台。 |
| `ECONOMY_INPUT` 0x20 | `native_simulation_stage_economy.cpp:333` 识别两种缺同日输入的原因，写请求日并置位；`native_simulation_host_worker.cpp:184` 按请求日也会报告。 | 兼容路径由后台等主线程采集。正常开局、整图授权、经济已由后台接管时，上述采集先于开周期检查。 |

### simulation 脚本

主菜单进入 PlayerGame 后，开局生成器配置脚本任务并检查原生计算（`main_menu.gd:570`、`player_game.gd:76`、`map_runtime_system_registration.gd:306`）。图形桌面开局仍用脚本调原生气候、海冰和蒸腾计算，也准备季节参数和资源初值。游戏中前台领取并安装已发布的地图数据。整图授权后，旧脚本调度器的每日计算入口提前返回（`native_daily_manual_tick.gd:33`）。

`scripts/simulation/` 有 74 个脚本、24,843 个物理行。47 个有正式调用路径，包括装配、显示与开局计算；26 个有产品代码引用，只经兼容配置或显式工具运行；0 个仅由测试或工具引用；`weather/weather_feedback.gd` 无引用。每个文件的用途与关键调用点见[逐文件核查](feature-status.md#simulation-目录逐文件核查)。经济停等的本机运行条件见[专项核查](feature-status.md#正式会话的推进镜像与脚本2026-11-26)。

## 跨模块交接

- **已提交视图（10 条，`check_committed_views.py`）**：Economy←Climate、Trigger←Events、Ideology←Modifier、Modifier←Effect、Ideology←Economy 意见、年报←Ideology、Country AI←Economy、年报←Country、Family 指标←Economy 意见、税率显示←最近领取的结算帧。所有者发布已提交数据，带 generation/day，消费处检查游标单调。
- **经济意见到思想系统**：后台与原生 inline 在每日执行边界直接复制经济最后提交的意见，并按目标日固定到已有意见缓存；同日继续计算不能换成之后发布的意见。首份意见尚未提交时仍保留未就绪状态，现有测试专用输入也经过同一按日固定。主线程发布延迟不再决定思想点数，SHADOW 仍使用其成对的参考输入。完整读档安装成功时清除旧日期缓存及按发布编号查询的输入接收记录，同一世界执行器重启保留未完成日输入。诊断中的意见日期与版本来自同一条实际接收记录。
- **只读查询**：Economy 读 Country 的 27 种查询经 `CountryReadView`（借用所有者的只读函数表，不保证多次查询共享同一快照）。税率、科技、领土仍在 `capture_country_epoch` 用 `copy_economy_snapshot` 冻结。
- **写入请求**：Economy→Country 的写全部走所有者端口（财政返还/预留/征收、采购、现金与物资转移、科研、国库支出）；`country_writes` 预算为 0，直接调用、别名、成员指针都不能重新引入。
- **请求队列**：Host 通用命令、Country 命令、Economy 命令（含军事 24/30–34）、Trigger 命令共享 `runtime_resolve_contract.h` 的入队与顺序键；Effect→Modifier/Events、Ideology→Modifier 和同步 Effect 批次仍用各自既有协议。请求与保存位置的对照见 [module-boundaries.md](module-boundaries.md#请求与提交)。
- **冻结输入**：`runtime_freeze_contract.h` 的 `RuntimeFrozenInputVersion` 登记 session、day、generation、命令水位和 committed/in-flight；Climate、Country、Economy 已登记。Climate 仍在 day plan 之前完成输入捕获和提交。
- **未迁移的读边**：Ideology←Country（同一指针可发布 plan 预览）、Country←Effect 身份/完成查询（含已接受未安装的 upsert）、Economy（含 Family）←Effect/Modifier、Military←Country/Economy（执行器在军事阶段准备输入，军事适配层仍有即时财政调用）、Climate←Modifier/Economy。23 个域对的逐项处置在 `tools/ci/cross_domain_inventory.json`。

## 软完成（仍保留的兼容债）

| 路径 | 现状 |
| --- | --- |
| Ideology 首个意见/国家快照未发布、未配置 | 保留首次装配兼容；不发伪 ACK，ready=false |
| Trigger ACK barrier / retry / stale / rejected、未配置/未启动 | 保留列出的原策略，不制造新 ACK |
| Effect 同日已提交重访 | 幂等重访；遇 drain/catchup 错误停车，不再宣布完成 |
| Country/Economy peer 等待 | stall、continuation_pending 与超时故障保留；部分旧注释仍称 soft，实际已不完成 |
| Modifier 上游未授权、SHADOW/OFF、Web 回退 | 按原授权策略保留 |

Ideology 的 invalid/shape invalid 与任意 opinion 前缀已不再软完成。保留原因清单由 `check_resolve_apply.py` 核对，新增原因不能静默加入。

## 存档

完整存档 PKSV 由 `game_save_coordinator.gd` 统一等待安全边界后保存；脚本侧 provider 登记在 `world_state_modules.gd`，C++ 段契约在 `tools/ci/cpp_save_section_contracts.json`。开发期不兼容旧档：旧版本明确拒绝，不静默填默认值。

后台与原生 inline 共用 `native_simulation_host_executor_boundary.cpp` 的保存服务：冻结已接收的命令，丢弃可重新生成的未来环境帧，构建 PKSR，并明确发布成功或失败。保存、停止和时钟控制通过 `runtime_control_wakeup.h` 在后台等待所用的锁内发布条件，防止检查条件与进入等待之间漏收通知。后台在日循环的空闲边界保存；inline 在 request/poll 时尝试取得同一把日边界锁，并安装相同的执行上下文。inline 的未完成日标记跨调用保留，整日提交后才清除，因此不能在两次续算调用之间捕获半完成状态。

`_executor_pending_commands` 与未完成日的 `_executor_day_environment` 属于世界，由当前执行器独占访问。后台和 inline 共用待执行列表及冻结输入；停止不销毁它们。`native_simulation_host_lifecycle.cpp` 负责执行器启动：同一世界保持 ACTIVE 且授权范围不变时，只更换执行器，保留业务状态、日期、编号、确认结果、发布游标和日内继续位置；不重新初始化已提交的域。未完成日标记也随后台/inline 交接，不能在替换执行器后保存半日状态。

新世界与重启分开：已启动过的 `DCWorldExt` 再 `configure_country` 时，先要求执行器确实退出，并在私有候选对象中验证配置；失败保留旧世界。成功后解除经济对旧 OwnedState 的借用，替换 Host 并重新连接适配层，Country 对象地址保持稳定，区分新旧世界的 session epoch 继续递增，新的 Host 回复协议编号也从旧值继续增加；同一世界重启则保持编号。`make_new_world_host` 在替换前重新验证并安装已配置的 Modifier、Effect、Trigger、Ideology 规则定义，以及 Modifier 稳定键到内部编号的映射；不复制旧实例、命令、确认记录、输入、意见、快照或读取进度。主线程的规则对象也清理旧实例和读取进度，使新世界从较小编号发布的结果可立即接收；同一世界重启不执行这项清理。Effect 与 Modifier 的状态清理分别集中在 `effect_runtime_lifecycle.cpp` 和 `modifier_runtime_lifecycle.cpp`。旧世界日期及授权证明不会进入新世界。读档则安装存档中的世界状态。未来命令及需要重试的命令不重新挤入实时入口。保存格式仍为 PKSR v5；待执行命令超过原有 4096 条容量时明确拒绝保存并保留现场全部命令。

同一世界重新捕获 Country 输入时，已由原生运行时接管的国家状态取自最近一次已提交副本，不覆盖成冻结的旧同步副本；重复发布同一内容身份的目录不清除请求及确认记录。新的国家配置会经过上述新世界入口。CLOCK_WAIT 在等待锁内复查停止、保存、暂停和速度变化；通知早于实际等待也不会遗失。

正式保存入口按 `worker_day_inflight` 和 `inline_day_pending` 判断 inline 的真实日边界，不能把无后台线程更新的 RUNNING 状态当成仍在计算。inline 返回前同步首次提交授予的归属，关闭 Country/Economy 的旧同步写入口。正式策略重启由 `world_runtime_lifecycle.gd` 等待 `simulation_executor_exited` 后再捕获并启动，失败会传回设置入口。`get_runtime_thread_report` 提供 `executor_serial_only` 检查调用线程的并行配置。重复启动及 inline+SHADOW 冲突在修改执行方式、并行设置、绑定或消耗待恢复存档之前拒绝。

复用对象读档时，已经验证的 PKSR 且旧执行器退出后，地图输入按待恢复存档的日期检查，独立暂存新输入；旧世界的日期与满队列不阻止这一步。启动用暂存输入重新建立队列，不读取旧队列的未来帧。没有待恢复存档或执行器仍运行时，原日期、递增编号和容量检查继续生效。

| 域 | 段 / 版本 | provider | 恢复依赖 |
| --- | --- | --- | --- |
| climate | CLM2 v10 | environment | — |
| country | PKCN v16 | country | environment |
| military | PKMI v6 | country | country |
| effect | PKEF v14 | rules | military |
| economy | ECP2 schema 62 | economy | country、effect |
| family | 在 ECP2 内 | economy | economy |
| technology | 在 PKCN 内 | country | country |
| modifier | PKMD v3 | rules | effect |
| trigger | PKTR v6 | history | economy |
| ideology | PKID v14 | rules | trigger、modifier、economy |
| host | PKSR v5 | simulation_runtime | environment、country、economy |
| annual | PKAR v1 | history | ideology |

provider 的 manifest 版本、段内字节版本、内容身份是三层不同的数，不能互相比较。

继续态里容易漏的字段（每项都曾造成读档后分叉，已修复）：

- ECP2：职业移动冷却、经济发布记忆与上一日意见快照（OSOA 块 8）、资源小数余量与逐格日期（块 9）、生产周期 EMA/累计耗时（块 11）、实物收入累计列 `epoch_in_kind_income`（块 12）、采样降雨边沿与冻结门槛（OSOA4 块 13）、Track-B 分摊投资审查的待续格子表 `_track_b_investment_cells_pending`（CADENCE_STATE 段尾，上游合并后补）。
- PKMI4：lot 原始链、槽位 payload、free-list 与 generation，包括仍挂链的 inactive 行；
  section 23 保存玩家自动探路任务（任务行、选点、seen/visited/blocked、观察点、日期、返程）。
  trail、冻结 explored、fog 和派生索引不入档，恢复时重建。`military_for_each_lot_ordered`
  不能全局过滤 inactive 行，变更型查找依赖原链复用槽位。
- PKSR5：已接纳未执行的 Economy POD 命令与回执（EQC1）、Trigger 传输请求/ACK/发布游标与 Host 请求编号（TCQ1，主线程入口与日执行者两个游标）、军事事件转发进度（MDJ1）。
- CLM2 v10：权威 extras 与天气初始化状态。v9 及更早的 payload 还带一份 365 天逐格温度环
  （`cells × 365 × f32`），只被滚动写入和 `state_hash` 使用，玩法读的是 `temperature_365d_ema`；
  v10 起不再落盘、也不再进 `state_hash`，读 v9 旧档时按旧布局读完并用冻结的 `state_hash_abi8` 复核。
- 天气场辐合（`convergence`）只有「有符号净流入」一种实现：`wf_wind_convergence_idx_{xy,cached}` +
  GDScript 镜像两份，**无运行时开关**（`PK_CLIMATE_CONVERGENCE_LEGACY` 已退役，2026-11-20 W9）。

## 哈希与验证范围

- `simulation_state_hash` 每天只把日期混入前值，不是业务状态摘要；`runtime_day_waterfall.h` 记耗时与完成掩码，也不是状态链。气候 ACTIVE 的 `compute_hashes=false`。
- 整体经济哈希还读同步国家对象与 Modifier 的 ECONOMY 序列；`get_country_state_hash` 取同步对象，`get_country_report` 取 worker 快照副本，二者不是同一提交边界。
- 黄金场景（`tests/runtime/golden_*`，`check_golden_determinism.py`）覆盖开局账目、整体经济、七个 worker 域投影、Country 追加链及表外推进者（军事、资源恢复、家族、人物、视野）。这是投影，不是完整十二域状态。
- 2026-11-11 起按用户快速调参的决定，撤掉提交的黄金和七份 intent 基线；同一个二进制重复运行逐字段一致，不改行为的重构则用仓库外临时候选做改前/改后对照。场景内的守恒、存读档和同日提交检查保留；调参后不需重录基线。此前重录记录属于历史证据，见 migration。
- 保存续跑（`check_committed_replay.py --checkpoint --trace`、`check_replay_matrix.py`）：不中断、重放、保存不中断、另进程读档四条轨迹逐日比较，读档后至少八日。默认矩阵 4 个场景：save1、calendar5、multicountry5、military20；`--military-annual` 单跑 military365（真实年度自动存档，受时序影响不稳定，见 migration 已知问题）；`--full` 另加 save2/5/9 与 mixed5；`--annual` 保存第 365 日；`--annual-neighbors` 保存 364/366（手动档）。
- 未覆盖：其他种子与平台、实际占领与战斗（测试地图路径不可达，只有合成占领自测）、任意 worker 日内命令位置、真实浏览器 Web 导出、图形长跑。

## 规模

- 依赖护栏扫描八个业务域，得到 23 个域对、504 个引用键。其中 294 个债务键合计 931 处，210 个契约键合计 614 处。头文件中的引用为 301 处，两表合计 1545 处。直接写国家预算为 0。
- 长度护栏扫描 2171 个文件，当前无违规。`world_runtime_host.gd` 545 行，`map_generator.gd` 784 行；`economy_runtime.cpp` 649 行、对应头文件 619 行；`native_simulation_host.cpp` 503 行、对应头文件 234 行；`country_runtime.cpp` 655 行。
- `DCWorldExt` 的脚本绑定按 15 个模块登记，入口为 `world_ext_bind_methods.cpp`。模块所有者见 `tools/ci/world_ext_binding_modules.json`；脚本直接访问原生接口的边界由 `check_script_native_access.py` 核对。

## 加载期目录编译入口

2026-11-15：加载期目录编译通过请求级 `LoadingCatalogContext` 复用实际相同输入，
源目录行循环可让出帧，同步调用仍走同一编译过程。Effect 初始化编排归
`map_rules_initializer.gd`。实现契约与验收入口见 feature-guides 的“加载期目录准备”；
是否达到加载帧耗时目标以 feature-status 的实际测试记录为准。

## 地形烘焙 pass（2026-11-18）

视觉地形烘焙的 pass 清单多了一条**侵蚀模式分支**，并新增一个 buffer-encoder pass（均在 bake 期，
运行期零开销、无存档格式变更）：

| pass | 入口 | 现状 |
| --- | --- | --- |
| 融合几何 pass `run_bake_geometry_fields_pass` | `gdext/src/world_ext_bake.cpp` | 进程内串起 terrain-index → 侵蚀 → 河流 SDF → 海岸 SDF → 纬度；**侵蚀阶段新增 `dem_erosion_mode` 分支** |
| `run_bake_erosion_spl_pass`（**新增**） | 同上 | 与融合 pass 共用同一份 `pk_erosion` 管线实现（不复制算法）；只给测试 / A/B probe 喂合成高度场，生产走融合 pass |
| `run_bake_erosion_pass`（液滴，保留） | 同上 | ABI 不变；只在 `carve` / `droplet` 与 legacy 回退路径执行 |

`run_bake_visual_tile_layer_pass` 默认省略诊断用哈希扫描。需要校验产物时，调用方通过
`include_hashes=true` 请求各层字节的哈希和该步骤的耗时。

生成链路里的分支：`MapBaker.bake_world()` 优先调融合几何 pass；侵蚀阶段按 `dem_erosion_mode` 走

- `carve`：几何刻谷（Priority-Flood 填洼 → MFD 汇水 → `log(A)` 映射谷深 → 倒角谷壁）+ 液滴，**逐位回退基线**；
- `spl`（**出货默认**）：建树（填洼 + 最陡受体 + 汇水面积）→ 系数预计算 → 隐式下切 → [沉积/展宽] → 限坡；不跑刻谷、不跑液滴；
- `spl+carve`：SPL 管线 + 浅刻谷（`dem_spl_carve_scale`），诊断模式；
- `droplet`：仅液滴（历史对照）。

**C++ 缺省恒为 `carve`**（不认识 / 缺省的模式串一律回退 `carve`），`spl` 只能由
`terrain_index_baker.gd::DEM_DEFAULTS` 显式开启；`dem_dep_enabled` / `dem_floor_widen` 仍为 `false`。
fused 返回 fallback 时回退 legacy per-pass 编排（terrain-index 或 GDScript ground-truth +
`bake_hydraulic_erosion` + 河流 SDF）。

绑定与清单：`native_binding_manifest.json` 计数 661 → 662（只多 `run_bake_erosion_spl_pass`），
`check_world_ext_bindings.py` 0 problems。改动摘要、验证证据与未覆盖范围见
[feature-status.md](feature-status.md)。
