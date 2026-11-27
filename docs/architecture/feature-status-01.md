# 主线程镜像、面板与地图绘制

## 主线程镜像入口与停等位（2026-11-27）

从 `33f5a656` 核对直接调用、按名调用、原生成员指针和停等位写入。Effect 和 Trigger 的旧写入口只有世界重建测试调用，Ideology 的旧入口只有绑定。整图日尾直接更新规则对象并发布读视图，三个旧入口及其专用快照缓冲已删除。空闲停等位 `0x08` 无置位点。诊断继续使用原有财政和经济输入的编号。

世界重建测试从 Effect 后台请求和 Modifier 已发布结果核对新世界与同一世界重启，从 Trigger 后台请求、回执和发布代次核对推进。脚本方法清单从 677 减到 674。

macOS 重建 Debug 和 Release 成功。Godot 4.6.3 导入、147 个回归脚本、年度自动存档及存档往返均通过，世界重建为 446 项检查、0 失败。与改前候选逐字段比较 10 次均无差异。独立回放四个场景各比较读档后 8 天，工厂 211 项测试及 CI 的 18 个静态护栏全部通过。

## 正式会话的推进、镜像与脚本（2026-11-26）

核对起点为 `cfd9fb70`。八项推进者的线程与登记相符。资源恢复公式在经济输入阶段，登记的是日尾交付入口。两个主线程入口登记的是存档同步调用点，正式帧从每日适配器进入。四个镜像绑定中，Modifier 正式调用，Effect、Trigger 只有测试调用，Ideology 无调用方。调用点与六种停等位见[前台尚存的模拟工作](current-state.md#前台尚存的模拟工作)。

经济输入采用源码核对。成功建立初始经济输入后，整图执行器按日复制并采集，同日已开周期直接继续。`godot --version` 输出 `4.6.3.stable.official.7d41c59c4`。本工作树只有扩展描述文件，缺少 `addons/dots_ext/bin`；检查整棵树也没有 macOS 动态库。`git submodule status gdext/godot-cpp` 显示 `-9e0650a0`（未初始化）。无界面运行未实跑，未取得停等次数。

### simulation 目录逐文件核查

从 `project.godot:14`、`scenes/main_menu.tscn:3` 出发，`scripts/ui/main_menu.gd:570` 新建会话，`scripts/game/game_flow_service.gd:7`、`:240` 切入玩家场景，`scenes/player_game.tscn:8` 挂载宿主，`scripts/game/player_game.gd:76` 配置会话。依次核对场景资源、自动加载、全局类名、继承、预加载、注册、按名转发、启动和退出回调。正常领取从 `world_runtime_daily_adapter_part1.gd:143` 进入。默认原生日任务注册成功在 `map_runtime_system_registration.gd:316` 返回，旧气候等任务在其后才注册。整图接管后，`native_daily_manual_tick.gd:33` 在调用旧调度器之前返回。

统计单位为 .gd 文件。按引用来源，74 个脚本中 73 个有产品代码引用，0 个仅由测试或工具引用，1 个无引用。按默认玩家会话的实际入口，47 个可运行（含开局装配、图形显示、按需诊断和卸载），另 26 个只找到兼容配置或工具入口。“条件引用”保留这些文件的产品引用关系。表内“模拟计算”也包含开局计算或调用原生计算，角色及条件按实际方法说明。目录总计 24,843 个物理行。`wc -l` 数到 24,842 个换行符，`sus_tick_context.gd` 的末行没有换行符。以下是静态调用链核查。

| 文件（相对 `scripts/simulation/`） | 默认会话 | 职责 | 运行条件和用途 | 关键引用（相对 `Project/project-keynes/`） |
|---|---|---|---|---|
| `biology/transpiration_pass.gd` | 运行 | 模拟计算 | 桌面开局的蒸腾计算，调用原生实现。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:196` |
| `climate/async_climate_diagnostics.gd` | 条件引用 | 工具 | 仅显式运行异步气候基准时进入。 | `scripts/simulation/climate/wind_heat_transport.gd:721`、`scripts/simulation/climate/async_climate_diagnostics.gd:6` |
| `climate/climate_async_inputs.gd` | 条件引用 | 调度 | 旧日作业采样，默认开局走标量参数入口。 | `scripts/simulation/climate/climate_daily_runtime.gd:663`、`scripts/simulation/climate/runtime_climate_capture.gd:119` |
| `climate/climate_daily_runtime.gd` | 条件引用 | 调度 | 旧日作业的气候运行对象。 | `scripts/simulation/systems/climate_daily_system.gd:55`、`scripts/game/map_runtime_system_registration.gd:316` |
| `climate/climate_math.gd` | 运行 | 模拟计算 | 生成地图时计算纬度温度基线。 | `scripts/geography/map_generation/native_generation_bridge.gd:696` |
| `climate/climate_runtime_finalization.gd` | 条件引用 | 调度 | 旧日作业的气候收尾。 | `scripts/simulation/climate/climate_daily_runtime.gd:50` |
| `climate/generation_loading_steps.gd` | 运行 | 调度、模拟计算 | 加载进度、开局季节几何。 | `scripts/geography/map_generation/native_generation_sequence.gd:350`、`scripts/simulation/climate/wind_heat_transport.gd:761` |
| `climate/mapgen_climate_passes_a.gd` | 运行 | 调度 | 图形桌面开局预热气候、海洋、海冰及蒸腾。Web 和无界面会话跳过这次预热。 | `scripts/game/world_runtime_visual_adapter.gd:86`、`scripts/simulation/climate/mapgen_climate_passes_a.gd:178` |
| `climate/mapgen_native_daily_runtime.gd` | 运行 | 调度、显示 | 开局配置和发布后的生态贴图更新。 | `scripts/game/map_runtime_system_registration.gd:83`、`scripts/game/world_runtime_adapters.gd:481` |
| `climate/native_daily_bundle_builder.gd` | 运行 | 调度 | 探测原生日任务并组装初始气候参数。 | `scripts/simulation/climate/native_daily_registration.gd:121`、`scripts/simulation/climate/runtime_climate_capture.gd:52` |
| `climate/native_daily_front_signatures.gd` | 条件引用 | 显示 | 旧天气发布计算锋面签名。 | `scripts/simulation/climate/native_daily_publish.gd:573`、`scripts/simulation/climate/native_daily_publish.gd:667` |
| `climate/native_daily_job_steps.gd` | 条件引用 | 调度 | 旧原生日作业的分片调度，整图已接管且没有未结束轮时不运行。 | `scripts/simulation/climate/mapgen_native_daily_runtime.gd:295`、`scripts/simulation/sus/jobs/native_daily_sim_job.gd:63` |
| `climate/native_daily_manual_tick.gd` | 运行 | 调度 | 开局或切换会话重置调度器。整图路径在手动逐日入口第 33 行返回。 | `scripts/game/world_runtime_generation_adapter.gd:44`、`scripts/simulation/climate/native_daily_manual_tick.gd:155` |
| `climate/native_daily_pass_inputs.gd` | 运行 | 调度、模拟计算 | 开局整理并计算气候参数。 | `scripts/simulation/climate/native_daily_bundle_builder.gd:23`、`scripts/simulation/climate/runtime_climate_capture.gd:178` |
| `climate/native_daily_publish.gd` | 条件引用 | 显示、调度 | 旧作业和旧天气的结果发布。 | `scripts/simulation/climate/native_daily_job_steps.gd:20`、`scripts/simulation/climate/pass_b.gd:535` |
| `climate/native_daily_registration.gd` | 运行 | 调度 | 配置原生世界、检查输入、登记任务。 | `scripts/game/map_runtime_system_registration.gd:83`、`scripts/game/map_runtime_system_registration.gd:306` |
| `climate/pass_a.gd` | 运行 | 模拟计算 | 桌面开局向原生温湿度计算传入参数并接收结果。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:178` |
| `climate/pass_b.gd` | 运行 | 模拟计算 | 开启局地耦合时，桌面开局计算局地气候。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:181` |
| `climate/runtime_climate_capture.gd` | 运行 | 调度、模拟计算 | 开局准备并发送世界环境种子。 | `scripts/game/world_runtime_generation_adapter.gd:313`、`scripts/simulation/climate/runtime_climate_capture.gd:448` |
| `climate/runtime_climate_reference.gd` | 条件引用 | 工具 | 手动运行时采集对拍参考。 | `scripts/simulation/climate/native_daily_manual_tick.gd:30`、`scripts/simulation/climate/runtime_climate_capture.gd:666` |
| `climate/sea_ice_stage_machine.gd` | 运行 | 模拟计算 | 开局的海冰步骤使用经过日数和日照函数。 | `scripts/simulation/sea_ice/daily_pass.gd:56`、`scripts/simulation/sea_ice/daily_pass.gd:152`、`scripts/simulation/climate/mapgen_climate_passes_a.gd:309` |
| `climate/season_native_passes.gd` | 运行 | 模拟计算 | 构造开局植被参数。 | `scripts/simulation/climate/season_refresh_coordinator.gd:560`、`scripts/simulation/climate/season_native_passes.gd:335` |
| `climate/season_refresh_coordinator.gd` | 运行 | 调度、模拟计算 | 准备初始季节参数。 | `scripts/simulation/climate/runtime_climate_capture.gd:456`、`scripts/simulation/climate/season_refresh_coordinator.gd:540` |
| `climate/season_round_b_plus.gd` | 条件引用 | 模拟计算 | 旧季节任务的计算。 | `scripts/simulation/systems/season_refresh_system.gd:261`、`scripts/simulation/climate/season_refresh_coordinator.gd:357` |
| `climate/season_round_publication.gd` | 条件引用 | 显示、调度 | 旧季节轮的发布。 | `scripts/simulation/systems/season_refresh_system.gd:288`、`scripts/simulation/climate/season_refresh_coordinator.gd:602` |
| `climate/weather_stage_refresh.gd` | 运行 | 调度 | 开局检查天气是否支持原生发布。 | `scripts/simulation/climate/native_daily_registration.gd:105`、`scripts/simulation/climate/weather_stage_refresh.gd:127` |
| `climate/wind_heat_transport.gd` | 运行 | 模拟计算、调度 | 开局准备风热输运与季节输入。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:188`、`scripts/geography/map_generation/native_generation_sequence.gd:350` |
| `economy/map_resource_deposits.gd` | 运行 | 模拟计算 | 计算开局矿藏参数。 | `scripts/simulation/economy/map_resource_initializer.gd:151` |
| `economy/map_resource_initializer.gd` | 运行 | 调度、模拟计算 | 初始化并发布资源分布和储量。 | `scripts/game/map_runtime_system_registration.gd:180`、`scripts/game/map_runtime_system_registration.gd:186` |
| `generator_context.gd` | 运行 | 调度 | 各开局协作者借此基类访问生成器。 | `scripts/geography/map_generation/native_generation_bridge.gd:1`、`scripts/simulation/climate/pass_a.gd:7` |
| `ocean/land_pass.gd` | 运行 | 模拟计算 | 桌面开局调用原生陆地热输运。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:186` |
| `ocean/ocean_currents_worker_visual.gd` | 条件引用 | 显示 | 旧洋流任务处理显示查询，测试也显式调用。 | `scripts/simulation/sus/jobs/ocean_currents_visual_round.gd:221`、`tests/runtime/ocean_currents_visual_query_test.gd:272` |
| `ocean/water_pass.gd` | 运行 | 模拟计算 | 桌面开局调用原生水域热输运。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:184` |
| `runtime_climate_hash.gd` | 运行 | 模拟计算 | 计算开局目录和参数的校验值。 | `scripts/simulation/climate/runtime_climate_capture.gd:278`、`scripts/simulation/climate/runtime_climate_capture.gd:484` |
| `sea_ice/daily_pass.gd` | 运行 | 模拟计算 | 桌面开局计算海冰。 | `scripts/simulation/climate/mapgen_climate_passes_a.gd:192` |
| `sus/jobs/native_daily_sim_job.gd` | 运行 | 调度 | 装配原生日任务；默认日推进由执行器负责。 | `scripts/simulation/climate/native_daily_registration.gd:150` |
| `sus/jobs/ocean_currents_diagnostics.gd` | 运行 | 调度 | 开局探测读取洋流状态。 | `scripts/simulation/sus/jobs/ocean_currents_job.gd:368`、`scripts/simulation/climate/native_daily_bundle_builder.gd:334` |
| `sus/jobs/ocean_currents_job.gd` | 运行 | 调度 | 装配洋流对象；初始输入读取洋流状态。 | `scripts/simulation/systems/ocean_currents_system.gd:53`、`scripts/simulation/climate/native_daily_bundle_builder.gd:143` |
| `sus/jobs/ocean_currents_physical_round.gd` | 条件引用 | 模拟计算 | 旧洋流任务的物理切片。 | `scripts/simulation/sus/jobs/ocean_currents_job.gd:519` |
| `sus/jobs/ocean_currents_visual_round.gd` | 条件引用 | 显示 | 旧洋流任务的显示切片。 | `scripts/simulation/sus/jobs/ocean_currents_job.gd:523` |
| `sus/jobs/weather_front_mirror.gd` | 条件引用 | 显示 | 旧天气任务同步天气锋。 | `scripts/simulation/sus/jobs/weather_refresh_job.gd:431` |
| `sus/jobs/weather_refresh_job.gd` | 条件引用 | 调度 | 旧天气任务才创建。 | `scripts/simulation/systems/weather_system.gd:61` |
| `sus/jobs/weather_refresh_slices.gd` | 条件引用 | 调度 | 旧天气任务分片。 | `scripts/simulation/sus/jobs/weather_refresh_job.gd:553` |
| `sus/sus_job.gd` | 运行 | 调度 | 向已登记任务注入世界。 | `scripts/simulation/sus/sus_scheduler.gd:262`、`scripts/simulation/sus/sus_job.gd:96` |
| `sus/sus_policy.gd` | 运行 | 调度 | 创建和读取调度策略。 | `scripts/simulation/systems/season_refresh_system.gd:63`、`scripts/simulation/sus/sus_scheduler.gd:171` |
| `sus/sus_scheduler.gd` | 运行 | 调度 | 接收开局任务登记。 | `scripts/data_core/dc_system_scheduler.gd:332`、`scripts/simulation/sus/sus_scheduler.gd:246` |
| `sus/sus_scheduler_diagnostics.gd` | 运行 | 显示 | 需要时读取调度诊断。 | `scripts/ui/perf_mini_hud.gd:92`、`scripts/game/world_runtime_host.gd:407`、`scripts/simulation/sus/sus_scheduler.gd:692` |
| `sus/sus_tick_context.gd` | 运行 | 调度 | 正式开局创建探测用的任务上下文。 | `scripts/simulation/climate/native_daily_registration.gd:118`、`scripts/simulation/sus/sus_tick_context.gd:25` |
| `systems/bio_occupancy_daily_system.gd` | 运行 | 调度、显示 | 开局登记，提交后安装后台物种分布。旧 tick 不在默认日循环。 | `scripts/game/map_runtime_system_registration.gd:296`、`scripts/game/world_runtime_daily_adapter_part3.gd:110` |
| `systems/climate_daily_pass_steps.gd` | 条件引用 | 调度 | 旧气候任务分步调度。 | `scripts/simulation/systems/climate_daily_system.gd:699` |
| `systems/climate_daily_publication.gd` | 条件引用 | 显示 | 旧气候任务的结果发布。 | `scripts/simulation/systems/climate_daily_system.gd:731` |
| `systems/climate_daily_system.gd` | 条件引用 | 调度 | 原生日任务注册成功在第 316 行返回，该分支才创建旧气候任务。 | `scripts/game/map_runtime_system_registration.gd:331` |
| `systems/climate_daily_tick.gd` | 条件引用 | 调度 | 旧气候逐日入口。 | `scripts/simulation/systems/climate_daily_system.gd:694` |
| `systems/country_daily_system.gd` | 运行 | 调度 | 装配国家任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:44` |
| `systems/dynamic_atlas_native_commit.gd` | 条件引用 | 显示 | 旧贴图切片的原生提交。 | `scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd:618` |
| `systems/dynamic_atlas_stride.gd` | 运行 | 显示 | 退出或更换世界时清理显示准备，旧逐日分批更新另有调度入口。 | `scripts/game/world_runtime_lifecycle.gd:85`、`scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd:551`、`scripts/simulation/systems/dynamic_atlas_stride.gd:184` |
| `systems/dynamic_atlas_tick.gd` | 条件引用 | 显示 | 旧贴图任务的 tick。 | `scripts/simulation/systems/dynamic_visual_atlas_upload_system.gd:506` |
| `systems/dynamic_visual_atlas_upload_helpers.gd` | 条件引用 | 显示 | 旧提交队列的贴图上传。 | `scripts/simulation/systems/dynamic_atlas_native_commit.gd:40` |
| `systems/dynamic_visual_atlas_upload_system.gd` | 运行 | 显示 | 装配动态贴图任务，整图领取另走帧发布。 | `scripts/simulation/climate/native_daily_registration.gd:240` |
| `systems/economy_daily_system.gd` | 运行 | 调度 | 装配经济任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:49` |
| `systems/effect_runtime_system.gd` | 运行 | 调度 | 装配效果任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:151` |
| `systems/enum_atlas_upload_system.gd` | 运行 | 显示 | 装配分类贴图上传任务。 | `scripts/simulation/climate/native_daily_registration.gd:233` |
| `systems/gameplay_effect_system.gd` | 运行 | 调度 | 装配玩法效果任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:155` |
| `systems/ideology_runtime_system.gd` | 运行 | 调度 | 装配理念任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:39` |
| `systems/military_daily_system.gd` | 运行 | 调度 | 装配军事任务，执行器日尾推进军务。 | `scripts/country/map_country_initializer.gd:477` |
| `systems/modifier_daily_system.gd` | 运行 | 调度 | 装配修正任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:23` |
| `systems/native_environment_runtime_system.gd` | 条件引用 | 调度 | 显式开启环境探测时登记。 | `scripts/game/map_runtime_system_registration.gd:402`、`scripts/simulation/climate/native_daily_registration.gd:215` |
| `systems/natural_resource_daily_system.gd` | 运行 | 调度 | 装配资源任务，默认由原生经济恢复储量。 | `scripts/game/map_runtime_system_registration.gd:293` |
| `systems/ocean_currents_system.gd` | 运行 | 调度 | 装配洋流任务并交出内部对象。 | `scripts/game/map_runtime_system_registration.gd:269`、`scripts/simulation/systems/ocean_currents_system.gd:53` |
| `systems/sea_ice_daily_system.gd` | 条件引用 | 调度 | 单独的海冰任务在旧调度路径装配。 | `scripts/game/map_runtime_system_registration.gd:341` |
| `systems/season_refresh_system.gd` | 运行 | 调度 | 登记季节任务；开局探测读取季节状态。 | `scripts/game/map_runtime_system_registration.gd:239`、`scripts/simulation/climate/native_daily_bundle_builder.gd:152` |
| `systems/trigger_daily_system.gd` | 运行 | 调度 | 装配触发任务，后台接管逐日结算。 | `scripts/game/map_rules_initializer.gd:34` |
| `systems/weather_system.gd` | 条件引用 | 调度 | 旧天气调度任务。 | `scripts/game/map_runtime_system_registration.gd:363` |
| `weather/weather_feedback.gd` | 无引用 | — | 无全局类名，未找到其路径、资源 UID 或脚本入口的调用。正式天气使用 `scripts/weather/feedback.gd`。 | — |

## 地块展板与图例工具栏互斥动效（2026-11-21）

- 展板入场时两级图例工具栏淡出，鼠标交互即时禁用；展板完全退场后工具栏再淡入。
  分类、图层请求及工作区对工具栏根节点的显隐控制保持独立。
- `UIAnimation.fade_visibility()` 处理反向过渡、减少动效、暂停和打断滑动后的坐标归位。
  展板退场增加进行中标志，快速重新显示时取消旧动画，避免迟到回调重新隐藏展板。
- 全项目编辑器编译无脚本错误；`cell_board_toolbar_transition_test.gd` 通过正常开关、
  退场中间态、打断次级栏入场、同帧重入、恢复淡入中再次入场、暂停、工作区隐藏、减少动效检查；
  `cell_board_test.gd` 回归通过。
- 带渲染探针在 1600×900、1280×720、2560×1080、720×480 验证展板显示时工具栏隐藏、
  退场后恢复；人工复核 1280×720 的两态截图。截图使用固定 QA 数据，未跑正式世界快进。
  渲染退出仍有 FMOD debugger 与资源清理提示。

按功能记录最近一次改动后的现状、验证证据和未覆盖范围；带日期的条目写在这里。
运行架构的现状（十二域、跨模块交接、存档、哈希）在 [current-state.md](current-state.md)，本页不是它的替代。

## 无界面性能录制（2026-11-26）

迁移旧仓库 [PR #85](https://github.com/hrhgit/Project.Keynes/pull/85) 的逐日录制。
批次回归在迁移前的 `f9984153` 漏掉第 6 天，导出 49 行；修复后逐日导出第 6 至 55 天，
共 50 行。录制器测试的 98 项检查通过。

Godot 4.6.3 在 macOS 的正式 60×40 开局做了两次 3 天记录验证。两次都在预热 2 天后
导出第 3 至 5 天，批次诊断另存，结算账目无错误。第一次低于现有 50 日/秒门槛，
返回退出码 9。补齐批次诊断检查后的第二次退出码是 0。未重跑完整性能对比。

## 后台领取、普通面板与地图出图（2026-11-24）

在 fork 的 `d2e0e7d93` 上拆开三个入口。默认每个处理帧领取，普通面板按领取的日期刷新，
地图按原画质和帧率档绘制。选格位置和可见范围随实际画出的地图切换。
`independent_presentation_test.gd` 检查定时领取、迟到帧、暂停时的年报和军事查询、
国家面板在同一天恢复刷新、旧世界清理和同日视野交接。

桌面用正式玩家场景验证。每 100 ms 领取时，冻结地图仍能看到顶栏日期前进、收到操作回执、
打开暂停菜单。鼠标拖动和滚轮缩放均生效，冻结画面上的点击仍落在原位置，恢复绘制后点击随新镜头移动。
暂停普通面板后地图可以继续绘制。窗口缩放后重新读档，首张地图与界面都使用存档日期，
旧地图已解除绑定。截图和窗口日志在本机 `~/.keynes-factory/evidence/presentation-decoupling.VEJpPi/behavior-release/`。

地表缓存测试还复现了旧版本的一处显示错误。单格视野变了，编码器报告一格变化，旧版在
100%、75%、再回到 100% 时地表版本都停在 1。生成显示表时共用了上一份数据的数组，
新旧比较因此相等。改用独立工作副本后，三次版本分别从 2 到 3、3 到 4、4 到 5。
同一份第 6 日存档有 2,400 格，其中 66 格可见。直接读回显卡上的迷雾数据，原版有 2,382 格
与存档恢复的视野值不同。给旧版单独加上迷雾修复后，旧版和解耦版都达到逐格一致。
固定镜头、日照和雾动画时，两版窗口截图有 99.998% 的像素完全相同。
证据见 `land-before/`、`land-release/`、`fog-validation.json` 和 `fog-comparison.jpg`。

桌面对照使用 Apple M2、Godot 4.6.3 / Metal、高画质、1600×960、垂直同步和 60 帧档。
地图为 60×40 格、四国、种子 20260718。镜头和操作序列固定。1× 取前 8 日，
50× 取前 180 日，逐日比较业务摘要和回执。只采用
全程窗口可绘制的运行。原 fork 与首版解耦提交的逐帧记录在 `pairs/`。这组 50× 的实测帧率
从 27.4 升至 59.4 FPS，同时改变了实际绘制的迷雾范围。

为单独测量解耦的影响，给旧版加上相同的迷雾修复，再与 `be3b7cffc` 交替运行。
下表汇总每轮实测帧率与 P95 帧间隔的中位数。帧率用实际绘制间隔数除以这些间隔的总时长。

| 游戏速度 | 对照组数 | 解耦前 FPS | 解耦后 FPS | 解耦前 P95 | 解耦后 P95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1× | 5 | 60.00 | 60.00 | 17.08 ms | 17.04 ms |
| 50× | 3 | 60.12 | 60.01 | 17.09 ms | 17.13 ms |

1× 的首轮三组中，机器的一分钟负载一度升至 158。解耦前最长绘制间隔为 674 ms，解耦后为 979 ms。
随后反转运行顺序再做两组，负载在 3.5–8.4 之间，四次运行均约 60 FPS，最长绘制间隔为 19.7 ms。
这五组全部保留。逐帧记录在 `pairs-release/` 和 `pairs-1x-repeat/`。

50× 每 100 ms 领取与默认逐帧领取均得到相同的第 1–180 日业务摘要和操作回执。
第 20、80、141 日的三个待答事件及选择回执完全一致，生效日依次为 21、81、142。
定时读取的原始记录在 `interval-release/`。

年报场景的旧断言检查了玩家的暂停按钮。改前和改后的窗口都自动打开年报，且在 24 日的测试年末
由后台停在第 24 日等待确认，玩家设定的 50× 继续保留。年报场景测试现核对后台的暂停状态、
待答原因和停住的日期。两版的读数在 `annual-observed-baseline/` 和 `annual-observed-candidate/`。
通过正式场景入口跑默认逐帧领取和 100 ms 领取，两次均通过。验证汇总见同一目录的
`validation-summary.json`，包括 19 项导入、回归和存档检查。

PR #74 审查回归中，旧实现把尚未绘制的视野当成未探索，丢弃提交失败的地图更新，并在重置时清除了面板刷新回调却保留排队标记。对应测试在旧实现上失败，修复后均通过。
正式窗口分别使用后台线程和内联执行器验证了冻结地图选格、暂停普通面板、恢复刷新、窗口缩放和读档。窗口测试等待后台提交和前台实际领取均抵达目标日期。
年报测试在种子 251891501 的第 20 日遇到待答剧情。固定该种子并通过玩家入口选择选项后，年报在第 24 日打开、后台等待确认、玩家保留 50 倍速，存读档断言也通过。日志在 `k74-annual-fixed/`。
两种执行器通过同一个日历发布入口发出日期变化，季度和年度的面板更新现在也跟随画面发布。窗口日志和截图见同一证据目录的 `k74-worker-window/` 和 `k74-inline-window/`。

另一次测试暂停模拟，冻结同一张地图，交替测窗口只画界面、以及在界面下面再合成这张地图。
两种情况各取 225 帧，窗口绘制的 CPU 耗时中位数分别为 0.144 ms 和 0.137 ms。
Metal 接口在这次测量中没有返回可用的 GPU 耗时。原始记录见 `composite/`。

## 地图按需领取生态贴图数据（#83，2026-11-25）

改前 `c81ebf871` 通过 `GameFlow` 启动正式玩家场景（Godot 4.6.3，种子 `20260718`，60×40 格，
四国，60 帧档，50×）。直接启动窗口未进入游戏，macOS `open` 返回 `kLSNoExecutableErr`。
随后用 `player_scene_handoff_probe.gd --overload --simulate-frames` 在无窗口场景运行到第 75 日。
第 41 至 55 日连续领取 15 批记录，贴图停在第 40 日，编码和提交均为零；领取结果仍带有 15 对
各 2,400 字节的 `transition_age` 和 `previous_vitality`，共 72,000 字节。
`DCWorldExt::poll_runtime_commit` 在构造领取结果时分配数组并复制，早于 `apply_pending_worker_map`
检查帧预算。两列只供生态贴图编码使用。分类变格同时更新地块详情所读的地形、地貌、植被和覆盖分类。
改前逐帧及逐日记录见 `/private/tmp/keynes-83.5xQarw/first/headless/`。

改前在数组分配及复制处加计时后，同一复现得到 15 次读取、72,000 字节。每次分配与复制耗时
中位数 3.667 微秒，P95 为 4.750 微秒，范围 1.875–4.750 微秒，合计 52.710 微秒。
原始日志在 `/private/tmp/keynes-83.5xQarw/instrumented-base/`。该次取样与本机编译重叠。

改后用同种子、命令和脚本复现，第 41 至 55 日仍逐批领取，复制和贴图提交均为零。
第 55 日解除帧负担后读取一次 4,800 字节，贴图直接追到第 55 日。两版第 1 至 75 日业务摘要、
命令生效日和回执顺序逐日一致，均在第 20 日收到剧情待答。改后记录见
`/private/tmp/keynes-83.5xQarw/first/candidate/`。

`player_map_publication_test.gd` 通过正式场景分别每日更新和延迟更新。延迟组在第 2 至 20 日
按 100 ms 间隔领取，19 日内没有复制贴图列；已放行到第 21 日的执行器在第 20 日等待玩家选择。
暂停并在同一世界重启执行器后，只读取一次第 20 日的完整数据。最终贴图字节、20 日业务摘要和有序
回执与每日更新组一致。测试还验证了拒绝错误地图、日期、提交编号或格数，读档与换局释放旧发布，
以及地图积压时完成正式保存。日志为 `/private/tmp/keynes-83.5xQarw/formal-map-final.log`。

`cell_lut_incremental_test.gd` 在不同日分别改变两个地块，逐字节对照合并更新与每日更新，
共 71 项通过。`simulation_presentation_coalescing_test.gd`、`independent_presentation_test.gd`、
原生接口握手、世界生命周期、正式存档往返和两组逐日校验也通过。两组逐日校验改前、改后各跑三轮，
全部与改前首轮一致。天气表通过 111 项，跳过两个需要实际图形后端的读回。游戏设置和内联执行器
存档测试的初次运行受系统目录写入限制，改用临时用户数据目录后分别通过 34 项和 46 项。
构建和回归日志在 `/private/tmp/keynes-83.5xQarw/`。

无窗口取证命令如下。给每次运行单独的存档目录和记录文件。

```sh
PK_SAVE_DIR="$saves" godot --headless --path "$project" \
  --script res://tests/game/player_scene_handoff_probe.gd -- --fps=60 --speed=50 \
  --through=75 --answer-story --command-log --overload --simulate-frames --frames="$trace"
```

窗口复测用同一版 `player_scene_handoff_probe.gd` 和 `player_scene_handoff_timings.gd`。
在改前源码副本应用证据目录的 `baseline-copy-timing.patch`，分别编译两份项目的调试库并导入。
下列两次调用各交替运行三组。面板样本从派遣按钮收到鼠标事件开始，到派遣面板首次参与窗口绘制为止。
地图间隔和落后天数取自独立地图窗口完成的绘制。后台每秒推进的天数按连续逐日提交时刻计算。

```sh
python3 tools/perf/run_rendered_player_handoff.py "$base_project" "$candidate_project" \
  --output "$normal_output" --fps 60 --map-reads
python3 tools/perf/run_rendered_player_handoff.py "$base_project" "$candidate_project" \
  --output "$busy_output" --fps 60 --map-reads --overload --expect-pacing
```

本次配对试跑的第一组和 `independent_presentation_window_test.gd` 均在 macOS 启动阶段失败。
桌面工具也拒绝操作 Godot，实际地图绘制间隔、落后天数和点击反馈仍待可见窗口验证。

审查修复使用正式时钟以 5× 推进，逐步放开时钟可请求的日期以进行逐日对照，并在 60 帧档的帧开始后
占用一整帧时间。无窗口回归确认第 2 至 20 日照常结算并领取记录，贴图列复制为零。
时钟请求第 21 日时，后台停在第 20 日的剧情选择处。解除负载后
只复制一次第 20 日的数据。错误的提交编号会记录具体原因并保留上次贴图。
性能汇总要求整次运行至少有一次有效的复制计时，因此整次缺少数据会报错，已测量的忙帧仍可显示零次复制。
91 项性能工具测试和 18 项架构检查通过。窗口脚本通过语法检查，macOS 仍未能启动测试窗口。
日志见 `/private/tmp/keynes-83-review.LA4Vcp/`。

## 按帧率推迟地图更新（#63，2026-11-24）

### 改前取证

基线 `0f32d0072` 通过 GameFlow 打开正式玩家窗口。Apple M2、Godot 4.6.3 / Metal，
1600×960、高画质、开垂直同步、固定地图中心镜头，种子 `20260718`、60×40、四国、50×。
各档覆盖前 180 日。在已领取第 40 日至第 55 日前，探针每帧额外占用一个生效档的预算。

| 档位 | 实际结算日 | 绘制间隔样本 | 绘制间隔 P95（范围） | 天/秒 | 地图更新/秒 | 落后游戏日中位数（范围） |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 30 | 25–74 | 27 | 42.3 ms（25.7–43.0） | 51.70 | 27.94 | 1.5（0–3） |
| 60 | 27–75 | 35 | 29.3 ms（25.8–30.9） | 50.15 | 37.19 | 1（0–2） |
| 自适应 | 25–75 | 37 | 27.1 ms（25.7–27.3） | 49.96 | 35.75 | 1（0–2） |

分开计时 `MapRuntimeBridge.poll_runtime_commit()`、气候与视野写入、
`publish_worker_climate_visuals()` 的地块和天气图准备，以及
`CellLutUpload._process()` 的提交。绘制间隔来自 `frame_post_draw`。
领取的中位耗时为 0.009–0.013 ms，贴图准备和提交为 1.55–1.70 ms。
所以降频范围选地块和天气贴图。领取推进后台的八日快进放行窗口，每帧继续照常领取。
三档第 1–180 日的逐日业务摘要与回执一致。另跑的无窗口记录从第 1 日出现差异，
配对验收按同档同窗口比较。采集跨过 #65 启动，各档系统负载不同。

逐帧、逐日、后台耗时、系统负载、实际命令与汇总见本机
`~/.keynes-factory/evidence/issue-63-window.atXH6A/fixed-1600/summary.json` 及同目录日志。
桌面会话可直接以 1600×960 启动 `tests/game/player_scene_handoff_probe.gd`。

```sh
sample_dir=$(mktemp -d /tmp/keynes-63-window.XXXXXX)
for fps in 30 60 adaptive; do
  sample="$sample_dir/baseline-$fps"
  PK_SAVE_DIR="$sample.saves" PK_RUNTIME_WATERFALL_CSV="$sample.waterfall.csv" \
    godot --path Project/project-keynes --windowed --resolution 1600x960 \
    --log-file "$sample.engine.log" --script res://tests/game/player_scene_handoff_probe.gd -- \
    --fps="$fps" --speed=50 --through=180 --answer-story --require-rendered \
    --overload --frames="$sample.jsonl" > "$sample.log" 2>&1
done
```

### 改后验证

理念回执的回归在 `ideology_draw_flow_test.gd` 复现。改前通过第 2 日抽卡和第 4 日重抽的拒绝回执及
提示检查，首次改后四处失败。`runtime_narrative_scenario.gd` 会断开自动展示剧情的
`PlayerController._on_simulation_committed()`，首次改动把 `IdeologyFacade.drain_receipts()` 放进了该回调。
第 1 日缺少民意的拒绝走边界回执，所以该项仍通过。普通理念回执现在由领取日记录的代码直接交付。
同局重启执行器时，原生启动流程可把发布编号归零。按旧编号接收会丢弃接续日期的地图更新。
`simulation_presentation_coalescing_test.gd` 用第 31 日的编号 90 接第 32 日的编号 1 复现。
按本局已显示和待显示日期判断后，保留两批变格并显示第 32 日。换局及读档仍清空上一局待显示内容。

改前窗口的三档记录均未满足「忙帧继续领取并暂缓贴图」的判据。以 `9ddb12734` 为改前版本，
同一正式玩家场景在无窗口条件下跑了相同命令记录。1× 的前 8 日、50× 的前 180 日，
改前改后的逐日业务摘要及有序回执一致。三条预定命令分别在第 2、2、5 日按序结算，
剧情在第 20、80、141 日等待，答复分别在第 21、81、142 日结算。

在无窗口玩家场景中用 `--simulate-frames` 触发帧预算判断。补测中 30、60、自适应档分别有
6、12、11 帧继续领取并暂缓地图，三档都在第 55 日追上。三档前 180 日的业务摘要及回执
仍与同条件的改前记录一致。合并测试验证仅在较早批次变化的格子、分类、整图标记和最新生态
过渡数据，还验证视野更新优先、恢复显示频率和换局清理。窗口行为探针另外检查忙时切档、拖动、
缩放、顶栏点击，以及实际贴图读回与第一帧揭雾。
补测逐帧、逐日数据和命令见 `/private/tmp/keynes-63-verify.nm8ULe/headless-pair/summary.json`。

剧情暂停和答复、年报第 365 日保存续跑通过。普通和表外模块的确定性检查分别通过三轮。
补测日志保存在 `/private/tmp/keynes-63-verify.nm8ULe/`。设置切换、天气表和迷雾表用例通过，
无窗口天气表用例跳过两项图形回读。
负载检查原命令被 `ps` 读取权限阻断。补测只替换系统负载记录，保留原有七进程实测负载的验证、
业务比较和存档续跑断言。三项均通过，证据在 `/private/tmp/keynes-63-verify.nm8ULe/load-observed/summary.json`。

剧情暂停策略测试在常规运行通过，在并发负载下和改前版本都复现同一条断言失败。
`submit_narrative_choice_request()` 受理后唤醒后台，测试随即调用 `capture_narrative()`，
可能赶在 `service_narrative_requests()` 写入之前。两次失败的回执都给出第 3 日，
读取到的等待列表为空，策略仍在第 3 日应用。改前复现见
`/private/tmp/keynes-issue63.zOmKne/popup-baseline-pressure/test.log`。

地图覆盖层冒烟用例在第 0 日偶发读到零次刷新。用同一种子在改前注入长帧，复现了同一断言。
用例在下一帧执行宿主处理前完成固定 120 ms 的计时并读数，当时刷新尚未运行。
诊断日志为 `/private/tmp/keynes-issue63.zOmKne/overlay-baseline-early-sample.log`。
本轮地图覆盖层用例和完整无窗口回归均通过。已导入的临时副本上，`run_regression_checks.py --roundtrip`
共通过 128 项检查，包括正式存读档往返。引擎在编辑器导入时报告 macOS 系统证书读取错误，
导入关卡未通过。运行和导入日志分别是 `/private/tmp/keynes-63-verify.nm8ULe/regression-isolated.log`
和 `/private/tmp/keynes-63-verify.nm8ULe/isolated-import.log`。

审查修复的定向用例验证了无地图批次保留积压变格、拒绝残缺生态数组、贴图失败后日期继续推进，
以及宿主负责帧信号和保存时的视野同步。生态用例在仓外构建的 macOS arm64 扩展和脚本编码路径
同时通过。定向日志见 `/private/tmp/keynes-63-review.qKdUuF/logs/`。
审查修复版和 `9ddb12734` 的无窗口对照中，1× 前 8 日和 50× 三个帧率档的前 180 日
逐日业务摘要和回执一致。模拟忙帧时，30、60、自适应档分别有 8、13、14 帧继续领取结果并
暂缓地图，三档均合并积压并在恢复区间追上。记录见 `/private/tmp/keynes-63-review.qKdUuF/headless/summary.json`。
18 项静态检查、211 项工厂测试通过。无窗口回归批量运行通过 127 项，包括正式存读档往返。
存档列表用例首轮读到了复制来的旧测试存档，换用空目录的副本后通过全部 26 项检查。
改前和改后导入均报系统证书和编辑器目录错误，运行及导入日志见同一目录下的 `logs/`。

macOS 桌面上的常规配对跑完 36 次窗口，另有 18 次注入忙帧窗口。全部前 180 日或前 8 日的
逐日摘要和命令回执一致，两种速度共有的前 8 日也一致。采集期间 #66 有并行编译。
逐轮设置、原始记录和耗时见
`~/.keynes-factory/evidence/issue-63-ab.JTevdp/report.md`。
这批采集未逐帧验证 macOS 窗口可绘制，耗时包含窗口不可绘制区间的风险。

30 帧档的诊断自然复现了 311.247 ms 的绘制记录缺口。缺口内多次前台处理耗时约 37–40 ms，
持续领取模拟日，窗口一直报告不可绘制，绘制前后信号和引擎绘制计数同时停在原处。
Godot 可在没有可绘制窗口时为待处理渲染资源执行绘制步骤，因而只看到 Metal 和绘制回调
不足以证明窗口可绘制。另一轮诊断中，可绘制窗口上的最长间隔为 48.691 ms。
诊断记录位于 `~/.keynes-factory/evidence/issue-63-draw-cause.Eig7bx/`。

采样用例在 macOS 将窗口置顶并请求焦点，逐帧记录可绘制状态。配对工具拒绝缺少可见性证据
或窗口不可绘制的录制，窗口可绘制时的长帧仍保留。此约束只在配对采集工具执行。
同一台 M2 以 Godot 4.6.3、Metal Mobile、1600×960、高画质和相同种子复测 30 帧、50 倍速。
下表给出三个共同游戏日区间的改前 → 改后结果。基线为 `9ddb12734`，改后为 `c5c3eff65`。
样本数和范围均按完成绘制之间的间隔计算。三对窗口逐帧可绘制，模拟摘要和回执与原录制的前 180 日一致。
过载轮的改后版本通过合并积压和追上更新的检查。

| 负载 | 共同游戏日 | 绘制 P95（ms） | 绘制间隔样本 | 绘制范围（ms） | 后台天/秒 | 地图更新/秒 | 最大显示落后（游戏日） |
|---|---:|---:|---:|---:|---:|---:|---:|
| 常规，改前先跑 | 26–75 | 49.0 → 45.7 | 29 → 85 | 30.2–49.4 → 32.8–57.2 | 48.7 → 15.0 | 29.6 → 10.7 | 3 → 4 |
| 常规，改前先跑 | 85–134 | 37.1 → 48.1 | 32 → 90 | 33.0–38.7 → 42.8–56.2 | 43.1 → 12.2 | 28.8 → 5.7 | 2 → 3 |
| 常规，改前先跑 | 147–174 | 41.2 → 46.9 | 15 → 55 | 37.6–41.2 → 42.8–62.4 | 43.6 → 11.1 | 25.5 → 5.2 | 2 → 3 |
| 常规，改后先跑 | 26–75 | 37.4 → 38.4 | 27 → 62 | 30.5–49.7 → 32.8–43.1 | 51.4 → 22.7 | 29.5 → 21.4 | 2 → 3 |
| 常规，改后先跑 | 86–135 | 36.8 → 43.3 | 31 → 54 | 31.9–37.1 → 39.5–43.5 | 44.7 → 21.2 | 29.2 → 6.1 | 2 → 4 |
| 常规，改后先跑 | 146–175 | 41.4 → 49.5 | 16 → 38 | 37.7–41.4 → 42.1–49.9 | 44.1 → 16.5 | 25.6 → 5.1 | 2 → 3 |
| 注入忙帧 | 25–74 | 52.0 → 48.5 | 41 → 41 | 28.6–55.6 → 29.8–55.9 | 32.0 → 30.0 | 26.1 → 7.9 | 2 → 16 |
| 注入忙帧 | 85–135 | 42.1 → 49.9 | 46 → 38 | 34.0–43.4 → 41.4–51.8 | 27.0 → 28.6 | 24.4 → 5.7 | 2 → 6 |
| 注入忙帧 | 146–175 | 43.4 → 52.1 | 24 → 22 | 41.1–43.6 → 44.5–54.6 | 26.8 → 26.3 | 22.7 → 5.4 | 2 → 6 |

窗口持续可绘制的测量区间内，改后最长间隔为 62.4 ms。两对常规窗口的改后后台速度较低，改前和改后
采集时系统负载不同。数据保留这个差异，具体原因仍待定位。
每组共同日界、样本数、波动和复现结果见
`~/.keynes-factory/evidence/issue-63-draw-cause.Eig7bx/report.md`。

同一基线与改后版本补测 60 帧和自适应档。常规、注入忙帧各一对，先跑的版本交替安排。
每个窗口逐帧可绘制，分辨率、画质、镜头及场景参数和 30 帧复测一致。四对的前 180 日
模拟摘要和命令回执均与 30 帧记录一致。注入忙帧时，两个档位的改后版本均合并积压并追上最新结果。

| 档位与负载 | 共同游戏日 | 绘制 P95（ms） | 绘制间隔样本 | 绘制范围（ms） | 后台天/秒 | 地图更新/秒 | 最大显示落后（游戏日） |
|---|---:|---:|---:|---:|---:|---:|---:|
| 60 帧，常规 | 25–75 | 27.0 → 27.0 | 37 → 37 | 25.9–27.0 → 25.7–27.0 | 49.7 → 50.1 | 37.9 → 10.0 | 2 → 6 |
| 60 帧，常规 | 87–134 | 29.5 → 26.5 | 32 → 35 | 26.0–30.1 → 25.6–26.8 | 50.3 → 50.0 | 35.9 → 9.6 | 2 → 6 |
| 60 帧，常规 | 146–174 | 26.9 → 29.3 | 19 → 19 | 26.2–26.9 → 26.8–29.3 | 51.8 → 50.5 | 37.6 → 8.9 | 2 → 7 |
| 自适应，常规 | 26–75 | 26.9 → 27.6 | 36 → 36 | 25.9–26.9 → 25.8–27.7 | 49.8 → 49.9 | 37.9 → 9.2 | 2 → 7 |
| 自适应，常规 | 85–134 | 27.0 → 29.2 | 36 → 34 | 26.0–27.1 → 26.0–30.8 | 50.1 → 50.7 | 37.9 → 9.3 | 2 → 6 |
| 自适应，常规 | 146–175 | 29.9 → 27.0 | 20 → 21 | 26.4–30.8 → 25.8–27.1 | 49.4 → 50.5 | 35.5 → 10.3 | 2 → 6 |
| 60 帧，注入忙帧 | 26–74 | 26.8 → 28.9 | 35 → 34 | 25.9–26.9 → 25.6–29.1 | 50.2 → 50.2 | 37.9 → 7.2 | 2 → 18 |
| 60 帧，注入忙帧 | 87–135 | 29.6 → 26.9 | 35 → 36 | 25.9–30.6 → 25.6–27.1 | 49.0 → 50.1 | 36.6 → 9.3 | 2 → 6 |
| 60 帧，注入忙帧 | 146–174 | 28.6 → 26.8 | 19 → 20 | 26.2–28.6 → 25.7–26.8 | 51.7 → 51.2 | 37.0 → 10.9 | 2 → 6 |
| 自适应，注入忙帧 | 25–74 | 27.1 → 26.8 | 36 → 36 | 25.9–27.2 → 25.8–27.0 | 50.0 → 50.4 | 36.8 → 7.2 | 2 → 19 |
| 自适应，注入忙帧 | 86–135 | 29.6 → 26.6 | 35 → 37 | 26.1–31.2 → 25.5–26.7 | 49.1 → 49.8 | 36.0 → 9.1 | 2 → 7 |
| 自适应，注入忙帧 | 146–174 | 27.1 → 29.5 | 19 → 20 | 26.1–27.1 → 26.4–29.7 | 51.9 → 47.6 | 37.6 → 10.2 | 2 → 6 |

常规 50 倍速下，60 帧和自适应档改后后台推进分别为 50.0–50.5 和 49.9–50.7 天/秒。
改后常规绘制 P95 分别为 26.5–29.3 和 27.0–29.2 ms，
两档在这个桌面场景中的目标预算都是 16.7 ms，显示仍无法稳定达到 60 帧。注入忙帧的区间内，
二者均减少地图更新，显示落后随之扩大，压力解除后均追上。30 帧在逐帧确认窗口可绘制的复测中，
改后最长间隔为 62.4 ms，P95 仍超过 33.3 ms 的档位预算。三档采用相同画质，比较只
测整个显示的间隔与分段耗时，未单独量到 GPU 耗时。每档两种负载各有一对，表中的波动范围指同一对
各区间内的样本。逐轮系统负载和原始数据见 `~/.keynes-factory/evidence/issue-63-draw-cause.Eig7bx/verified/additional-drawable-pairs/summary.json`。

配对采集使用两份已导入的项目、对应版本的本地扩展和相同的
`player_scene_handoff_probe.gd`、`player_scene_handoff_timings.gd` 和
`player_scene_display_checks.gd`。在有绘图权限的 macOS 桌面终端运行以下命令。

```sh
verified_dir=~/.keynes-factory/evidence/issue-63-draw-cause.Eig7bx/verified
baseline_copy=$verified_dir/before
candidate_copy=$verified_dir/after
engine=/Applications/Godot.app/Contents/MacOS/Godot
sample_dir=$(mktemp -d /tmp/keynes-63-pairs.XXXXXX)
python3 tools/perf/run_rendered_player_handoff.py "$baseline_copy" "$candidate_copy" \
  --godot "$engine" --fps 30 --fps 60 --fps adaptive --output "$sample_dir/alternating"
python3 tools/perf/run_rendered_player_handoff.py "$baseline_copy" "$candidate_copy" \
  --godot "$engine" --fps 30 --fps 60 --fps adaptive \
  --overload --expect-pacing --output "$sample_dir/overload"
```

单独验证交互和贴图读回，在上面的窗口探针命令中使用改后项目，并在 `--fps=60`
的过载轮加 `--exercise-display`。两条配对命令各档轮流运行三次，保留逐帧、逐日、
提交耗时和实际设置。汇总报告每轮实际绘制间隔 P95、样本数和范围，以及同一范围内的
后台天/秒、地图更新/秒和延后游戏日数。

## 海拔和风向专题图（#66，2026-11-24）

改前基线为 `9ddb12734`。每日提交先由 `WorldRuntimeDailyAdapter` 安装气候显示，
再标记当前专题图。请求合并后，原本每次到期都由 `DataOverlayBaker.bake_cell_lut()`
逐格生成 RGBA8、计算统计并创建或更新纹理。海拔来自地块装配、地图列回写和读档，
正式每日气候不写海拔。风向的色相读两个方向分量，亮度还读风速。三个风输入来自后台
求解及校正后的写回，开局和兼容路径也能安装这三列。每日变格表和提交日期无法说明
海拔或三列风是否与上次画出的值一致。

在 Godot 4.6.3 macOS arm64 无窗口环境，用种子 `20260718`、60×40、四国、高画质，
分别只打开海拔图或风向图，以 50 倍速推进。按第 1–50 日及首次打开统计。实际输入变化
为相邻可见请求之间逐字节比较，生成与上传分别在逐格生成入口和纹理创建或更新分支记数。

| 专题图 | 版本 | 请求 | 合并进待刷新 | 输入变化 | 到期含首次 | 生成 | 上传调用 | 其中重复输入的到期次数 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 海拔 | 改前 | 50 | 40 | 0 | 10 | 10 | 10 | 9 |
| 海拔 | 审查修正后 | 50 | 40 | 0 | 10 | 1 | 1 | 9 |
| 风向 | 改前 | 50 | 40 | 5 | 10 | 10 | 10 | 4 |
| 风向 | 审查修正后 | 50 | 40 | 5 | 10 | 6 | 6 | 4 |

每轮首次打开各生成及上传 1 次。海拔图少生成和少上传各 9 次，风向图各少 4 次。
四轮的逐日业务摘要和回执一致。原始记录在 `/private/tmp/keynes-66-review.RTpQ8A0D/`
下的 `before-*.jsonl.overlay`、`final-*.jsonl.overlay`，汇总为同目录的
`counts-final-through-50.json`。两层到期时都用已发布的内容标记或原数组存储判断，
定向用例也核对了不同存储的同值发布可以只靠标记跳过生成。

逐字节定向用例覆盖持续不变、单格海拔、风向两个分量、仅风速、合批后恢复原值、
交叉输入、切层、纹理重建、同尺寸换图、格子顺序变动和信息缺失。正式读档用例核对两层
的贴图和统计与保存时逐字节一致。三轮黄金对照与改前结果一致。
宿主显示对照原先把 `RefCounted` 替身赋给 `DataOverlayLayer`，在运行 22 项图层检查前退出。
替身改为实际图层的子类，诊断只在海拔或风向做过输入检查后追加该项，资源和生物图层的
既有对照断言全部保留。`world_runtime_presentation_test.gd` 的 84 项检查通过。
玩家场景的生物图层合批旧用例在改前也失败。探针记录显示，109 ms 的到期点落在长帧内，
用例在 172 ms 时先于宿主执行检查，请求仍在队列。审查修正后，用例等待真实刷新间隔，
在到期帧的宿主处理后检查结果，并验证提前刷新会失败。原合批断言保留。

本轮四组定向检查和正式存读档通过。日志位于同目录的 `verified-focused/` 和 `golden/`。
复验用已导入的隔离副本，副本使用系统证书文件以适配当前沙箱。
macOS 窗口探针未能连上图形服务，没有收到绘制回调。实际窗口帧耗时与 GPU 回读待验。
本地 Qodo 未登录，工作树待工厂提交后评审。

## 分域洋流绘制（#65，2026-11-24）

`MapRuntimeBridge` 注册洋流系统。分域调度经 `MapGenerator.sus_tick_daily()` 和
`OceanCurrentsSystem.run_slice()` 进入洋流任务。改前任务先算快照摘要、复制 12 组全图数组，
再判断是否需要开画。现在先读已安装快照的身份与日期，开始新一轮时才读取并固定整份物理数据。

在 macOS arm64、Godot 4.6.3 无窗口模式，用高画质、60×40、种子 `20260718`、四国开局。
正式场景开局、接收第 1 至 3 日的结果及显式调用分域入口，两版的洋流任务入口、完整查询、
开画和提交均为 0 次。开局贴图由初始烘焙生成。定向组把同场景已提交的物理场交给洋流系统，
在首次绘制的切片之间发布第 4 日结果。移动端条件由桌面用例在首轮提交后跨季触发。

| 每次运行的情形 | 任务入口 | 完整查询改前 → 改后 | 开画 | 提交 | 单次查询范围改前 → 改后（µs） |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 图层关闭 | 2 | 2 → 0 | 0 | 0 | 54–67 → — |
| 首次开画 | 1 | 1 → 1 | 1 | 0 | 61–65 → 66 |
| 继续绘制 | 30 | 30 → 0 | 0 | 0 | 52–78 → — |
| 仅提交已绘完的像素 | 2 | 2 → 0 | 0 | 2 | 52–66 → — |
| 同季空闲 | 1 | 1 → 0 | 0 | 0 | 55–61 → — |
| 移动端首轮后跨季 | 1 | 1 → 0 | 0 | 0 | 54–56 → — |
| 下一季重新开启 | 1 | 1 → 1 | 1 | 0 | 54–56 → 60–64 |

代码修改前单独测得 38 次查询，耗时中位数 56 µs，范围 52–69 µs。用保留的改前副本和改后
副本各复测两遍，完整查询每次运行累计由 2.288–2.323 ms 降至 0.126–0.130 ms。
计时范围是完整查询调用。

正式场景三天与定向场景两次绘制的洋流、上升流、风场数据摘要全部一致。同格数换图和切换
来源的对照中，最终绘制字节与提交切片一致。`ocean_currents_visual_query_test.gd` 的 27 项
检查覆盖同季重新开启、续画固定数据、来源切换与失去授权，以及地图、提交版本和数组
校验失败时保留上一次显示。macOS Debug 和 Release 均在仓外构建并通过该用例。其余五项
定向回归、18 项静态检查均通过。`check_golden_determinism.py --runs 3` 改前改后各三次，
第 1 至 8 日逐日一致。

原始记录在 `/private/tmp/keynes-65.FSUTJL/`，包括 `measure-before.log`、
`measure-after.log`、`paired-*.log`、`comparison.json`、`switch-*.log` 和 `golden-*/summary.json`。
窗口尝试遇到 macOS 图形服务连接错误，真实窗口的帧耗时待验证。

## 水波查找表只重画变化页（#62，2026-11-23）

改前基线 `14235fef2` 的水波表代码与票据基准 `5b69be27c` 一致。正式场景在每帧推进
显示时间后调用 `RendererShaderWater.sync_ripple_lattice`。第一页用 `cycles.xy` 与种子 71，
第二页用 `cycles.zw` 与种子 133，第三页用固定种子 211 和 307。旧入口对四个周期一起
做比较，任一分量变化就让 `RenderDataTable` 请求整张 256×768 纹理重画。
[刷新入口](../../Project/project-keynes/scripts/rendering/renderer_shader_water.gd#L526)
· [三页输入](../../Project/project-keynes/shaders/water_ripple_lattice.gdshader#L6)

非 Compatibility 的独立桌面水面绑定这张表，包括桌面低档。水面细节为 0 时跳过波浪取样。
原生 Android/iOS 的中、高着色器档绑定，自动和低档省略。正式中档波浪取第一页和固定页，
高档波浪也取第二页。Web 普通档、Web PC High、Compatibility 和合并陆水路径省略这张表。
#54 的 Mac 记录与 #59 的 iPhone 16e 记录使用移动低档，#59 省略的是整层水面。
[纹理声明](../../Project/project-keynes/shaders/include/water.gdshaderinc#L283)
· [取样档位](../../Project/project-keynes/shaders/include/water.gdshaderinc#L459)
· [手机档位](../../Project/project-keynes/scripts/game/player_game.gd#L471)

在 Godot 4.6.3 无窗口环境驱动实际同步入口，流动速度用正式场景的 `2.28`，初次填完后
按 1/60 秒步进 3,600 次。下表记录待画的矩形和各页的提交次数。首次创建和重挂入每次各画
三页。固定时间 `0 → 4.3 → 5.0 → 6.4 → 8.5 → 12.7` 覆盖首次、仅第二页、不变、
仅第一页、仅第二页和两页同变。原始逐次记录为 `/private/tmp/keynes-62.4yUYDpOv/` 下的
`baseline-replay.log` 和 `candidate-replay.log`。

| 60 秒内的刷新帧 | 帧数 | 改前矩形 | 修改后矩形 |
| --- | ---: | --- | --- |
| 仅第一页变 | 5 | 256×768 | 第一页 256×256 |
| 仅第二页变 | 10 | 256×768 | 第二页 256×256 |
| 两页同变 | 4 | 256×768 | 顶部 256×512 |
| 均未变 | 3,581 | 跳过 | 跳过 |
| 各页提交次数 | | 19 / 19 / 19 | 9 / 14 / 0 |
| 提交矩形覆盖像素数 | | 3,735,552 | 1,507,328 |

局部更新保留一个画布、一张纹理和每次刷新最多一次矩形绘制。同帧的请求合并后由同一
绘制提交。GPU 有可能仍要加载和写回整张纹理，净收益须在真实绘制中测量。
[Godot 清除和按需更新规则](https://docs.godotengine.org/en/4.6/classes/class_subviewport.html#enumerations)

`render_data_tables_test.gd` 无窗口检查覆盖正式绑定入口、不同周期组的矩形、同帧合批、
切档重建和 100%→75%→100%，36 项通过。`fog_cell_field_test.gd`、`terrain_render_scale_test.gd`
和 `web_water_pass_node_test.gd` 通过。有图形后端时，以整表绘制逐页比较全部像素，并用
会变色的测试纹理检查实际绘制范围。使用 `-- --require-draw` 要求执行图形回读。

`water_ripple_coast_capture.gd` 复用 #54 的正式场景入口和 #59 的海岸路线。种子 20260718、
60×40、四国，镜头 1.75× 从 `(1059.36377, 924)` 向右移动 320。固定日历并关闭迷雾以露出
海岸，显示时间由正式渲染器以 1× 推进，60 个显示秒走完路线。

```sh
godot --path Project/project-keynes --windowed --rendering-method mobile \
  --script res://tests/rendering/water_ripple_coast_capture.gd
```

默认高档，添加 `-- --medium` 选中档。脚本参数 `--check-pixels` 在同一海岸镜头对照
三次换周期前后画面并检查水面确实取样。用同一脚本在改前和改后轮流采样，文件记录实际
绘制尺寸、同步设置、逐帧周期、
提交矩形、绘制次数、应用绘制回调间隔和带 CPU 时间戳的子视口计时。Metal 的 GPU 时间和
真实屏幕间隔需以 Game Performance 跟踪对齐进程及帧。区分首次、单页、双页和无刷新，对比
各轮样本数、中位数、P95 和波动，子视口 CPU 绘制开销单列。

本环境的 macOS 图形服务无法启动 Godot 窗口，桌面自动化未获 Godot 授权，CoreDeviceService
无法完成初始化。逐页图形回读、海岸画面、真实 GPU 时间和屏幕呈现间隔待验，因此尚无净收益结论。

## 跨天气发布复用风场（#61，2026-11-23，已撤回）

改前以合入 #60 的 `7a9fa7373` 为基线。正式玩家场景用种子 `20260718`、60×40、
四国、50 倍速跑到第 180 日。无窗口取证逐字节比较 166 对相邻天气发布中的三列风，
150 对相同，16 对变化。求风日期命中这 150 对，其中没有同日期异字节或不同有效
日期同字节的样本。166 份物理写回中 165 对相邻快照有 150 对相同。旧路径已经
带着求风日期发布，每次写回仍复制风，每次天气发布仍用 #60 的共用入口重做风图。
复用该日期的后台维护成本为零。前台每次命中核对固定数量的数组存储与发布记录。

同输入对拍在 12 格的非顺序布局中覆盖九次发布。格编号风图、天气过渡字节、天气表四层
的写入字节和层号完全一致，整图风编码从 9 次降至 4 次，写风层从 10 层降至 7 层。方向和速度
分别只改一格，同帧合批覆盖风在准备后、实际上传前改变。`weather_table_layout_test.gd`
还覆盖 A→B→B→B、无效记录、换图、尺寸变化和恢复时补齐两层。

正式场景的无窗口原始记录里，前后匹配的 135 份物理快照与地图风字节相同，
第 1–180 日业务摘要与回执一致。改后样本跳过 129 次三列风写回、129 次风图编码及
113 次天气表风层上传。存读档、日历、气候 C5 和两组各三次的黄金对照通过。
气候存读档用例检查了同日三列复用、原地编辑、同图重绑和读档后首次全量写回。天气表
布局通过 160 项检查，实际图形后端的三组回读跳过。LUT 合批和关闭云影的检查通过。
原始字节、引擎日志和逐日参考放在 `/private/tmp/keynes-61.DqknPB/`。

### 50 倍速交替测量

Apple M2、24 GB、macOS 27.2.1、Godot 4.6.3。两侧使用各自编译的 macOS arm64
调试库、高画质和固定地图中心视角，无窗口视口为 64×64。顺序为改前/改后、
改后/改前、改前/改后。逐对取第 25–75、85–135、146–175 日内两侧共同观测到的
首尾日期。六次运行的第 1–180 日业务摘要和回执一致。测试期间的一分钟系统负载
为 5.58–8.23。

| 轮次 | 未变/变化发布数（前 → 后） | 实际复制的风数组 | 整图风编码 | 天气表风层上传 | 发布帧 P95（ms） | 全部帧 P95（ms） |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 76/11 → 92/11 | 261 → 33 | 87 → 11 | 87 → 22 | 12.45 → 12.29 | 37.38 → 38.20 |
| 2 | 87/10 → 73/10 | 291 → 30 | 97 → 10 | 97 → 20 | 13.14 → 9.51 | 35.22 → 42.39 |
| 3 | 106/10 → 82/10 | 348 → 30 | 116 → 10 | 116 → 20 | 16.23 → 12.37 | 33.48 → 42.78 |

改后三轮分别跳过 92、73、82 次三数组复制及地图写入，同样次数的整图编码，以及
81、63、72 次天气表风层上传。以 #60 每次发布编码一次为基准，每次跳过的一组
数组复制相当于 28,800 字节。写回标记维护中位 10.02–10.21 μs，P95
为 13.21–15.13 μs。每次天气发布的标记查询、风层检查及登记中位 21–23 μs，
P95 为 26–30 μs。整图编码总用时逐轮为 255.27 → 37.04、298.82 → 27.73、
462.69 → 35.51 ms。前台合批使两侧的发布次数可不同。

九个共同日期区间的全部帧 P95 均上升。最慢 5% 的样本全部出现在未发布天气的帧，
这些帧的前台回收中位数在 0.034–0.043 ms。依据重复观测到的无窗口整帧退化，
保守撤回这版候选实现。
候选实现及测试留在 `/private/tmp/keynes-61.DqknPB/issue-61-candidate.patch`。
逐轮计数在 `headless-trials/summary.json`，长帧明细在
`headless-trials/whole-frame-tail.json`。

真实窗口未完成测量。最小绘制探针连接 macOS 图形服务失败，应用启动返回
`kLSNoExecutableErr`，桌面工具未获访问 Godot 的批准。窗口的发布帧、绘制间隔
和图形端四层回读仍待验证。保留的 `compare-timing.py --rendered` 用于两份已构建
副本在图形环境交替测量，并要求实际绘制回调。
最小窗口探针仍在等待回调，执行环境拒绝向该进程发送终止信号。

## 海岸平移基准（2026-11-23）

常规复测在同一台电脑上进行。本次在 M2、Metal Mobile 低档、1600×960 下完成两轮，每轮四段各
240 帧，第二轮能读取第一轮保存的基准。两轮完整画面的应用帧间隔 P95 为 27.417 和 19.016 ms，
反映同一版本的运行波动。旧 Mac 系统跟踪重新配对后，完整和隐藏水面分别观测到 477 和 476 个
显示间隔，四段中有 3 个提交请求没有找到匹配的内屏换面。无窗口错误和设置文件隔离已验证。

iPhone 16e 的一次历史诊断保留作资料，当时有两条自检失败，无法用作基准。完整画面 480 个游戏绘制间隔 P95 为 17.152 ms；共同末段 110 帧的 GPU P95 为 17.056 ms，109 个内屏换面间隔 P95 为 16.674 ms。[基准、运行和比较方法](../../tools/perf/coast_pan/README.md)。

## 同一次天气发布的风图编码（#60，2026-11-23）

改前取证使用 `5b69be27c`、Godot 4.6.3、种子 `20260718`、60×40、四国和 50 倍速。
无窗口玩家场景通过正式开局，探针补绑无窗口模式略过的天气上传与云影取风入口。
同一个显示世界和地图的发布 `14802048`（微秒时间戳）上，天气表和云影的风向、风速
数组摘要一致，各进入逐格编码一次，分别用时 1.419 和 1.407 ms。2,400 格各自填入
2048×2 风图（16,384 字节），两侧字节完全相同。天气表的布局准备与重排用时 13 μs，
60×40 表的提交调用用时 7 μs，云影检查复用并提交纹理用时 3 μs。共观察到 8 次两侧都
取风的发布，包括首次绑定。

天气 LUT 上传后，`_publish_weather_table_from_luts()` 通过 `build_bytes()` 调用
`build_image()`。云影随后看到同一个发布时间戳，在 `WeatherWindSource.update()` 中
又调用 `build_image()`。#58 检查能否复用纹理时，云影已经跑完了第二次编码。
原始输入摘要、两次取风及四层的写入字节保存在
`/private/tmp/keynes-60.YvfpoO/exact.jsonl.wind`。

即时上传和同帧合批现在在同一处编码风图。天气表使用按地图行列重排的字节，云影直接
使用同一次发布里的格编号顺序字节。显示世界记录来源地图、风纹理尺寸和发布时间。

### 输出对照

在同一基线的两份副本上比较连续两次正式发布。60×40 天气表的四层上传字节和层号一致，
层号从 0 翻到 1。2048×2 风纹理的前后两张图逐字节一致，首次使用同一张图，
第二次保留上一张作为过渡起点。两种读取顺序、换图、尺寸变化、无效输入恢复、同帧合批
和关闭云影由 `weather_table_layout_test.gd`、`cell_lut_incremental_test.gd` 和
`cloud_weather_quality_test.gd` 覆盖。新的关闭云影用例在改前读取了更新但尚未发布的风向，
改后读取该次发布的风向。常规和 `--external-only` 黄金测试在两侧各重复三次，逐日结果一致。

### 50 倍速交替测试

使用已包含 #57 的本地 `fork/master`（`8f1872cc8`）制作改前改后副本。两侧使用同一个
macOS arm64 调试扩展和相同设置（种子 `20260718`、60×40、四国、高画质、地图中心）。
依次跑改前/改后、改后/改前、改前/改后。取每对在第 25–75、85–135、146–175 结算日
各自都采到的首尾边界，按真实发布所在的主循环帧计时。同帧有多次发布时，编码分别计数，
帧间隔只采一次。六次运行的第 1–180 日业务哈希和回执一致。

| 轮次（改前 → 改后） | 发布次数 | 编码次数 | 编码总耗时（ms） | 发布帧样本数 | 发布帧间隔 P95（ms） |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 100 → 106 | 200 → 106 | 286.6 → 203.2 | 100 → 106 | 7.11 → 7.27 |
| 2 | 88 → 118 | 176 → 118 | 302.0 → 208.8 | 88 → 118 | 9.16 → 6.37 |
| 3 | 83 → 113 | 166 → 113 | 289.6 → 194.9 | 83 → 113 | 7.97 → 6.43 |

每轮单次发布的编码用时中位数为 2.85–3.78 → 1.76–1.90 ms。发布帧间隔 P95
的轮间范围为 7.11–9.16 → 6.37–7.27 ms。前台合批受主循环节奏影响，发布次数可以随之
变化。样本期间的 1 分钟系统负载均值为 3.30–5.16。

以上为无窗口主循环数据。macOS 图形服务连接失败，窗口绘制间隔、天气表图形回读及
`render_data_tables_test.gd` 的画面端点检查待验证。
`/private/tmp/keynes-60.YvfpoO/` 保留临时探针、连续两次发布的原始字节和全部逐帧逐日记录。
`headless-trials/summary.json` 记录每对共同结算日区间，`headless-trials/publication-metrics.json`
记录上表的逐轮汇总。

[返回专项记录总目录](feature-status.md#历史记录)
