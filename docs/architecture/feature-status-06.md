# 建筑、绘制、故障诊断与物资

## 建筑亏损成因首屏可视化（2026-11-16）

建筑详情的“生产与岗位”页新增按需渲染的“亏损成因”纸片卡。卡片复用既有对冲条和堆叠条，显示税前总收入、含税总支出，以及原料采购、工资成本、维护支出和营业税费；只有当前经营期利润为负且建筑仍在经营时显示，亏损停产继续显示停产原因。

显示层沿用已发布经济快照：`last_revenue` 为营业税后实收，`last_operating_cost` 为原料、工资应付和维护，`last_business_tax_paid` 单独提供营业税。视图将正营业税同时加回收入和计入支出，保证图形的收支缺口与已发布利润一致。未改 C++、DataCore、存档字段或每日调度。

验证：`tests/building/building_inspector_state_test.gd` PASS；`tests/ui/ui_scene_structure_test.gd` 0 failures；编辑器脚本编译 exit=0 且无 Parse Error / Failed to load script / SCRIPT ERROR；`tests/qa/cell_inspector_screenshot_qa.gd` 已生成建筑页截图，并用临时负利润详情 payload 做了 1280×720 GPU 截图复核。

## 亚麻杆物资名与石器建材替代（2026-11-16）

`good.bast_fiber` 的玩家显示名由“亚麻秆/韧皮原料”改为“亚麻杆”，并同步科技网络、理念摘要和 perf-validation 镜像；稳定 ID、价格、科技标签和存档键保持不变。`primitive_lashing` 建材组仍由 `bast_fiber` 与 `reed_bundle` 共同候选，运行时按当地市场库存择一，不要求两者同时存在。

开局规划读取编译后的建材候选组，并将选中的候选材料写入出生地 bootstrap 库存；所以出生地没有亚麻杆时，只要芦苇候选可达，开局建造不会卡住。现有目录回归已覆盖建材候选展开，殖民建材回归覆盖“仅有芦苇、没有原木和亚麻杆也能出发”的路径。本轮未改 C++、目录 ABI、存档字段或调度。

> **更正（2026-11-17）**：上一段“只要芦苇候选可达”的前提不成立——`tech.reed_harvesting` 是 6800 点的非起始节点，开局不可达。详见下条。

## 石器绑扎槽的开局死锁与采集营地改单槽（2026-11-17）

八个起始科技（思考、狩猎、采集、早期贸易、枯枝采集、河滩淘金、地表银矿拣采、生皮刮制）能产出的货物只有原木、生皮、毛皮、野味、采集植物食物、衣物、黄金、白银和科技值，**没有任何纤维或捆扎材料**。而 `primitive_lashing` 池的两个成员都要研究：`bast_fiber` 需 `tech.wild_flax_collection`（3800，前置亚麻辨识 2100）、`reed_bundle` 需 `tech.reed_harvesting`（6800）。在起始科技内可营造的建筑共 3 个——采集营地、河滩淘金场、露天银矿——**三个都挂了绑扎槽**，即三个都造不出来。开局规划器把种子建筑的候选建材注入 bootstrap 库存只是第一座的一次性补贴，玩家自建第二座时照样死锁。

改动两处：

- `gathering_ground.tres` 去掉绑扎槽，建材改为纯 `primitive_construction` 单槽（`logs` 8686，数量不变）。它是最早的食物建筑，与狩猎营地、早期知识机构、早期商栈的写法对齐。
- `good.raw_hide` 的 `substitution_category_ids` 增加 `primitive_lashing`，作为绑扎槽唯一起始可得的兜底（`tech.hunting`）。默认价 24000 是亚麻杆 7000 的 3.4 倍，运行时按有效成本择优，有纤维时自然让位。已验证没有任何生产配方把 `primitive_lashing` 当投入类别，扩池不影响生产链；弓箭营地的第二槽 category 为空，不受影响。同步 `tools/construction_substitution_migrate.py` 的 `POOL_MEMBERS`（不加进 `ERA_INDEPENDENT`，以免改写建筑的槽解析）与 perf-validation 镜像。

验证：`tests/family/family_colonization_runtime_test.gd` 全过（含“仅靠芦苇开工包出发”“没有原木和亚麻杆仍能出发”）；`tests/ui/modern_economy_catalog_test.gd` 建材候选展开项全过，`pooled` 1339→1338（采集营地少一组），`every construction material group offers a substitute` 报的 15 个单候选材料与改动前逐项一致（`raw_hide` 来自弓箭营地，属既有）；`tests/building/building_resource_chain_test.gd` 的唯一失败项 `mining efficiency ... copper_ore_collector>=early_copper_mine` 与本次无关，亦为既有。未改 C++、目录 ABI、存档字段或调度。

遗留：河滩淘金场与露天银矿仍是双槽，目前靠 `raw_hide` 兜底（成本较高）；若按“起始建筑不挂绑扎槽”的规则统一，需一并改单槽并补结构槽数量。

## 地图渲染六项优化（2026-11-18）

在 Apple M2 MacBook Air 上用 Godot 4.6.3 Metal 运行正式玩家场景。地图 60×40，种子 20260718，窗口 1600×960，高画质、全分辨率迷雾，关闭垂直同步。固定游戏日期和镜头，保留渲染所需的动画与天气数据更新。对照双方使用相同的海陆覆盖与浓雾遮挡逻辑。

| 固定镜头 | 优化前每帧 | 优化后每帧 | 配对帧时间降幅 |
| --- | ---: | ---: | ---: |
| 海面 | 16.92 ms | 16.09 ms | 4.9% |
| 陆地 | 21.87 ms | 19.37 ms | 11.4% |
| 全屏浓雾 | 7.17 ms | 4.52 ms | 37.0% |
| 半屏有雾 | 21.37 ms | 18.07 ms | 15.5% |

每个镜头 7 组新旧交替，每侧每组 36 帧，全部 7 组均改善。单项比较中，海面波纹省 0.58 ms，陆地材质省 2.09 ms，全屏浓雾省 2.67 ms。半屏镜头中陆地和雾各省约 1.51 ms。建筑在常规地图中的差异落入波动范围，在 3013 个建筑实例的城市近景省 0.16 ms。18 组建筑截图逐像素一致。整图可见差异集中在地貌交界细纹和树影。

Metal 和原生 OpenGL 均通过浓雾不透明性、天气、植被光照及资源实际绘制检查。以上帧时间来自 Mac 的绘制帧间隔。移动设备帧时间、功耗与温度待真机测量。

## 电脑和手机共用的绘制优化与画质自定义（2026-11-17）

两端共用无可见贡献的雨雪遮片剔除和远景细碎水面波光淡出。主菜单和暂停菜单
均可在预设基础上单独更改地图和迷雾清晰度、水面细节、植被和点缀密度、天气、
地面云影及帧率上限。电脑自动使用高档、全尺寸地表和迷雾。手机自动保留全尺寸
地表，使用 50% 宽高的迷雾、低档细节、关闭地面云影，上限 60 帧/秒。手机低档
默认地表宽高 75%，上限 30 帧/秒。地图清晰度只缩放陆地/水面图层。

Godot 4.6.3 / Apple M2 下，雨雪改前改后在 Metal Mobile 与 OpenGL Compatibility
各 110 组逐像素一致。设置服务 19 项通过，包括旧设置文件、自定义恢复、独立选项
和帧率上限。迷雾/天气、抗锯齿、Web 水面与植被分块的定向回归通过。地表缩放
在真实 Metal 绘制中检查了三个缩放比例、标记对齐、平移、调整窗口和直绘恢复。
40×28 正式游戏开局验证 100% → 85% 自定义 → 100%，并确认界面、选区、天气档和
帧率上限。设置界面检查覆盖 1280×720、1512×648 和 1280×576 的触屏布局模拟。

本机结果见 `/tmp/keynes-graphics-check.OOjiqcN7` 下的日志和截图。测试副本以
当前提交为基础并叠加画质改动，和并行会话中的后台计算改动分开验证。macOS 启动
仍有已知 FMOD 库缺失日志。Android/iOS 真机帧率和发热待测。

### 地图算法、浓雾裁剪与独立画质设置合并验证（2026-11-18）

Apple M2、Godot 4.6.3 Metal，正式玩家场景，固定种子 20260718、窗口 1600×960。
同一次开局依次切换地表/迷雾清晰度 100/100、85/75、75/50、90/100、100/100，
同时切换水面和天气细节。每档在相同画面下开启、关闭遮挡，对比海面、陆地、
半屏雾、整屏浓雾和揭开后的地表，共 25 对截图。每对平均通道差均小于 0.004/255，
每张最多 26 个像素的单通道差超过 2/255。各档在半屏雾内均减少海陆与地被绘制，
整屏雾均停止海陆绘制，揭开后恢复。

地表 75%、迷雾 50% 时另做覆盖对照。移动镜头到五个位置、揭开单格的第一帧、
跨地图东西接缝，地表覆盖逐像素一致。水波、迷雾和天气的共享数据在切档后
仍供对应图层使用。此轮验证画面和切档，分别测得的算法帧时间见上方「地图渲染六项优化」记录。
本次 Mac 开局验证使用本分支源码重新构建的 arm64 调试运行库。上游随附的旧库缺少地图生成接口
`run_bake_erosion_spl_pass`，直接使用旧库会在启动时报告接口校验失败。

### Mac 图形帧率补测（2026-11-17）

Apple M2、Godot 4.6.3、Metal Mobile，使用同一份 macOS Release 原生库。正式
60×40 四国开局，种子 20260718，1600×960 窗口，固定镜头和日照，暂停模拟，
关闭垂直同步和帧率上限。记录实际绘制之间的时间。地图清晰度组关闭迷雾，
只采纳植被补齐后绘制次数稳定的一轮，每档 90 帧。

| 地图清晰度 | 帧/秒 | 单帧耗时 p95 |
| --- | ---: | ---: |
| 100% | 24.7 | 43.4 ms |
| 90% | 29.1 | 36.5 ms |
| 85% | 30.1 | 35.6 ms |
| 75% | 34.3 | 31.3 ms |

迷雾开启、地图清晰度固定 100% 的三轮交替对照中，完整效果中位数 20.7 帧/秒
（20.5–20.8）。单独把雾层宽高调到 50% 后是 25.5 帧/秒（24.2–26.2）。在此基础
上降低水面、植被、天气并关闭云影后是 32.1 帧/秒（30.6–33.2）。这组综合结果
只能用于评价该组合。改前版同画质的整游戏试跑受植被完成程度和同时运行的编译、
回归影响，未用来估算这次共用优化的整游戏净收益。本次 Metal 的逐视口 GPU 计时
返回零，耗时取自实际绘制间隔。

原始数据见 `/tmp/keynes-graphics-timing.lRKSEoEL/steady-candidate.log` 和
`evidence.json`。手机真机当前不可用，发热和功耗未测。

另用 1600×900、1,276 地块的离屏天气场景交替测了三对新旧雨雪 Shader。局部降雪
每批绘制 48 次后读取图像，按帧折算的批次耗时中位数从 1.122 ms 降到 0.793 ms，
三对分别缩短 29.9%、29.3%、31.6%。晴天与大范围降雪的结果有波动，收益未定。
三个场景输出逐字节一致。此计时包括提交与读回等待。原始数据见
`/tmp/keynes-weather-frame-bench.no2gZJ8W/timing-offscreen.log`。

## 玩家可见时间统一为年月日（2026-11-19）

玩家界面此前到处显示模拟内部口径「第 1 日」「第 42 天」「第 1 年 · 1 月 1 日」。本轮把日期文案
收敛到 `WorldClock.date_text_for_day()` 与 `date_text()`，全游戏统一为 `1年2月14日`。

- 顶栏、事件弹窗、史册、GM 面板、年鉴封面与年报标题改为 `N年M月D日` / `N年`。
- 经济卷宗与 HUD 结算日、地块检查器的最近结算与在途订单起止日、建造完工日、家族与人物创立日、
  科技信号首次记录日、殖民队出发/采购/抵达日、停战与和议冷却日、战事日志、国家摘要、
  存档槽位标题、GDP 横幅起算日都按日索引换算成日期。
- 时长语义保持不变（已战、剩余、工期、近 N 日）；外交面板的战争计数由「第 N 日」改为「已战 N 日」。
- 顺带修掉一处既有文案缺陷：宣战按钮在已递交状态下只有「已递交」，现在写明「已递交，次日生效」。

验证（2026-11-19，多为 headless 脚本测试，另有一次带渲染的叙事界面截图）：

- `godot --headless --path Project/project-keynes --editor --quit` 无 Parse Error / SCRIPT ERROR。
- 通过：`tests/ui/player_top_bar_fit_test.gd`、`tests/ui/hud_status_card_test.gd`、
  `tests/economy/economy_dossier_view_model_test.gd`、`tests/economy/economy_fiscal_history_rolling_test.gd`、
  `tests/ui/annual_report_test.gd`、`tests/family/family_workspace_ui_test.gd`、
  `tests/game/narrative_event_runtime_test.gd`（108 checks）、`tests/ui/inspector_live_patch_test.gd`、
  `tests/ui/diplomacy_workspace_test.gd`、`tests/ui/gm_panel_view_model_test.gd`、
  `tests/ui/gm_panel_runtime_test.gd`、`tests/ui/info_panel_resource_lines_test.gd`。
- 顶栏排印回归的窄窗断点随文案变短重定：800×600 现在按原字号放得下（`DATE_FONT_SIZE`），
  760×600 才降字号，两条断言分别守住「放得下不裁字」与「放不下先降字号」。
- 仍失败且与本次无关：`tests/ui/annual_report_ui_test.gd`（撕裂遮罩距离场）与
  `tests/ui/ui_scene_structure_test.gd`（`touch_number_pad.gd` 运行期构造容器），
  失败项点名的都是本次未改动的文件；`tools/ci/check_size_ratchet.py` 的 8 个超限文件与
  `check_skill_mirrors.py` 的 4 个 skill 漂移在改动前就已存在（`cell_inspector/construction.gd`
  在 HEAD 即为 1355 行，本次只替换 1 行）。其余 guard 在本机因 GBK 默认编码报
  UnicodeDecodeError，未作为结论。
- 带渲染截图：`tests/qa/narrative_ui_screenshot_qa.gd` 跑通并目检事件弹窗与史册的日期题头
  （`1年3月28日`），无裁字。
- 未做：整游戏内地图与顶栏的多分辨率 A/B 截图；`Project/perf-validation` 镜像（该目录与主工程
  已大幅漂移，按既有约定不同步）。

## 运行时故障基建 R1–R6（2026-11-19）

计划：[docs/plans/runtime-fault-infrastructure-plan.md](../plans/runtime-fault-infrastructure-plan.md)；
逐项执行清单与实测数字：[docs/plans/runtime-fault-infrastructure-checklist.md](../plans/runtime-fault-infrastructure-checklist.md)。
`.pkinc` 格式契约：[docs/runtime/incident-bundle-schema.md](../runtime/incident-bundle-schema.md)。

目标是「玩家报错 → 定位到根因」从平均 7 轮文件往返压到 1 轮：现场自带构建 ID、断言 ID 与
过程量；故障现场可离线重放；新增 fatal 必须先登记台账否则 CI 红。**本轮不改任何断言逻辑与
经济账本写入顺序**，只加诊断、复现与治理能力。

### 关键量（本机实测，Windows + Godot 4.6.2 + MSVC，不是估计）

| 指标 | 改动前 | 改动后 |
| --- | --- | --- |
| 现场可交付体积 | 40.6 MB `economy.pkec` × 131 份 / 1.07 GB | **1.6 KB** `.pkinc`（同一现场形状） |
| 现场是否可知「哪次构建」 | 只能反推二进制里有没有某个字符串 | `build_id=<sha>+<utc>` 在 report/fatal_context/`.pkinc`/GM 面板 |
| 现场是否可知「哪条断言」 | 裸字符串，无 ID、无台账 | `assert_id=INV-ECON-0042` + witness 对象 |
| 离线复现 | 无入口 | `reproduced=true`、`diff=[]`；篡改 witness → `reproduced=false` 且 `diff` 点名字段 |
| 400 天 soak（60×40） | ≈ 11 s/天（debug）⇒ 约 1.2 h | **34.6 s** |
| 提交前核验 | 手工拼命令 | `.\tools\ci\verify.ps1 -Quick` → GREEN（16.6 s） |

### R4.1 结论：快照「能写不能读」是**返回字典缺键**，不是 PKEC header 缺段

这份结论否掉了计划里 H1/H2/H3 三个候选，改按「字段没被上报」处理：

- `NativeEconomyRuntime::begin_save()` 的返回字典只有 `ok/chunk_bytes/schema_version/catalog_hash/committed_day`，
  **从不返回** `generation` 与 `state_hash`；而 `runtime_forensics.gd` 读的是
  `begun.get("state_hash", 0)` / `begun.get("generation", 0)`，于是恒为 0。
- 同一份现场里 `country.pkcn` 是 `native_generation:1` / 非零哈希，正因为 `country_runtime_persistence.cpp`
  的 `begin_save` 有 `out["state_hash"] = state_hash(); out["generation"] = _generation;`。
- `restore_eligible` 在 C++ 里**整个仓库不存在**，是 `runtime_forensics.gd` 里硬编码的 `false`。
- 快照本身是可恢复形态：`epoch_active:false`、`snapshot_boundary:"committed_boundary"`、
  `economy.pkec ok:true schema:65`、42.5 MB 完整写出。PKEC 头里也确实有 `_committed_generation`
  （写在 `SAVE_SECTION_CADENCE_STATE` footer）。
- 唯一真实的缺口是 **Economy 自己的 `state_hash` 从来不存盘**（头里只有 catalog/environment/event/
  prosperity/family 各 hash 与 Country 的配对 hash），所以该值只能在 `begin_save` 时实时算；
  新增 `state_hash_source:"live_economy_state_hash"` 明说它不来自文件。恢复并不需要它
  （恢复校验的是 Country 身份 + catalog hash + 形状/计数）。

修完后 `begin_forensics_save()` 实测：`generation=2  state_hash=1283621631749218751
restore_eligible=true  epoch_active=false`。

### R1 断言台账与构建标识

- `docs/runtime/invariants.json` 登记 **2731** 条 reason（`gdext/src` 351 个 `.cpp`，3323 处出现点）。
  计划 §4.6 预估「150–300 条」低估了一个量级：那是 fatal 的量级，实际 error 字符串是 2731 条。
  其中 `kind=fatal` 4 条已完成 witness/playbook（INV-ECON-0040/0041/0042、INV-SAVE-0001），
  其余 2727 条先以 `kind=unknown` 入库，按模块分批补（ECON 882 / COUNTRY 469 / CORE 376 / EFFECT 299 /
  CLIMATE 230 / MODIFIER 129 / SAVE 121 / MILITARY 113 / TRIGGER 107）。
- `tools/ci/check_fault_taxonomy.py`：扫描 + `--strict/--json/--suggest/--bootstrap-missing/--write-doc/
  --check-cpp-ids`；`--strict` 1.2 s 退出 0；未登记 reason 会打印 `文件:行` 并退出 1（负路径已验）。
  `--write-doc` 幂等（两次 sha256 相同 + 解析模型重序列化与磁盘字节逐字节相等）。
- 构建标识：SCons 生成 `gdext/src/pk_build_id_generated.h`（`<git short sha>+<UTC>`，无 git 退化
  `nogit+<utc>`）。**没有**按计划字面给每个 TU 加 `-DPK_BUILD_ID`：那会让每个 object 的命令行
  每次构建都变脏，空转的 scons 也要全量重编重链。实测两个在用 DLL 里都是
  `e6b869a3a+20261119T140626Z`。另加不依赖任何 runtime 的 `DCWorldExt::get_build_id()`，
  冷会话（经济尚未 bootstrap）也能问出构建号。
- 三个 flat 键 `investment_row` / `construction_row` / `investment_legs` 原样保留，`assert_id` 与
  `witness` 是新增键 —— 旧日志与旧 fixture 不受影响。

### R2 事故包 `.pkinc`

- 生产者 `scripts/game/incident_bundle.gd`（打包/裁剪/落盘）+ `scripts/game/incident_cell_slice.gd`
  （场景切片采集）。拆两个文件是因为单文件顶到 size ratchet 的 800 行上限，而两者的改动理由不同
  （采集要认识 facade，打包只认字典与字节）。
- `runtime_forensics.gd` 在 economy fatal 观察点之后追加写包，路径与快照同源（`tmp/incidents/`，
  移动端 `user://incidents/`），保留最近 10 份。
- 实测：真跑 `capture_and_dump("economy_fatal")` 落盘 **1605 字节 / 7 成员**；
  `python tools/ci/inspect_incident.py` 校验 6/6 成员 sha256 通过。改 1 字节 → 指出
  `cell.json sha256 不符` 并 exit 2；删成员 → `缺成员 world.json` exit 2；类型违约 → `violated` exit 1。
- 契约里**如实记 missing** 而非造数的项（`MANIFEST.notes`）：`commands.structural` / `commands.ledger`
  （经济命令队列无公开查询）、`pending_construction` 的 `required_good/required_qty/stock`、
  `hashes.economy_state_hash`（`economy_facade` 没包装该原生绑定，从 `scripts/game` 直调会触发
  `check_script_native_access` 跨模块拦截）、`hashes.ledger_hash`、`world.formal_start`。

### R3 离线重放 `--replay-incident`

- `EconomyInvariantProbe::replay_incident(Dictionary)` + `DCWorldExt::economy_replay_incident`
  （绑定在 `world_ext_bind_economy.cpp`，`native_binding_manifest.json` 664 methods）。
- 入口 `tests/runtime/incident_replay.gd`：解包 → 逐成员 sha256 → 调绑定 → 单行
  `[incident-replay/result]`；退出码 0 复现 / 1 未复现 / 2 包或环境问题。
- 实测（真实 `.pkinc`，INV-ECON-0042）：`reproduced=true`、`diff=[]`、`witness_after` 与
  `witness_before` 逐字段一致。反证：只把 `witness.json` 的 `owner_funds` 由 900 改成 900000
  并重算 MANIFEST 使其包内自洽 → `reproduced=false`、
  `diff=[{"field":"owner_funds","expected":900000,"actual":900}]`、exit 1。
- **判据的一处窄化必须说明**：`building_construction_preflight_funds_drift` 下不比较
  `first_good_id/first_required/first_stock` —— funds 分支结构性地只写 `-1/0/0`，那三个是 stock 分支
  的证据字段，比较它们等于比较该分支从未计算的值。排除项写进 `uncompared` 键可审计，
  `incident_replay.gd` 会把它一并透出；其余字段仍逐字段严格相等。
- `--emit-fixture` 产出的两份 C++ 片段都过 MSVC `cl /Zs /EHsc /std:c++17 /utf-8`。
- `INV-ECON-0040`（投资资金漂移）的重放是**尽力而为**：`.pkinc` 不记录 runtime slot id 与 family
  成员关系，只能按 `cohorts[]` 顺序 + witness 值反解；若该腿已被前置 trim gate 抑制，会如实返回
  `assert_fired=false` + `detail=assertion_no_longer_fires: …`，不会假绿。
  `save_family_expedition_person_invalid` 直接返回 `assert_point_not_replayable`（需要 PKEC 恢复
  路径与全量 person/family 表，`.pkinc` 按契约不带）。

### R4 快照可加载

- `generation`/`state_hash`/`restore_eligible` 如实上报；`runtime_forensics.gd` 不再硬编码
  `restore_eligible=false`；**全量快照改为按需**（默认只写 `.pkinc`，`PK_FORENSICS_FULL=1`
  或 GM 手动才写 PKEC）—— 这条直接关掉了「每次 fatal 一份 40 MB」的默认行为。
  两条分支都实测过：默认 → `economic_snapshots={"skipped":true,"reason":"full_snapshot_disabled",
  "enable":"PK_FORENSICS_FULL=1"}`；开关打开 → 真的进 `_dump_economic_snapshots`。
- `--load-forensics`（`PK_FORENSICS_LOAD=1` + `PK_FORENSICS_DIR`）已能真正加载并推进一天。
  实测（`PK_FORENSICS_SELFCHECK=1` 用生产写包接口现写 69.7 KB `country.pkcn` +
  29.7 MB `economy.pkec`，再走本入口加载）：`restored_country=true`、`restored_economy=true`、
  `economy_restore_path=pkec_stream`（pkec 分块流共 43 个 record）、`start_day=1 → end_day=2`、
  `advanced_days=1`、`fatal=false`，账本 `population_error=0 / money_error=0 / goods_error=0`、
  `audit_incomplete=false`；两次加载 `state_hash_stable=true`（country
  `-5621575443963560309`、economy `29127171950644891` 两次完全一致）。只读约束：
  `writes_saves=false`、`autosave_disabled=true`、全程不调 save、退出不写玩家槽位。
- 打通它踩到的两个真因，下一个人别再踩：
  1. `begin_country_restore` 的前置是 `economy->country_restore_allowed() = !_bootstrapped`，
     而 `configure_economy()` 只置 `_configured` 不置 `_bootstrapped`。所以**不要用
     `begin_new_game` 建世界**（gameplay start 会 bootstrap 经济），改成
     「`DCWorldExt` + `configure_country` + `configure_economy`」的 configure-only 世界即可。
     仓库里 `tests/economy/economy_cadence_runtime_test.gd` 等十几个测试本来就这么恢复 PKCN。
  2. PKEC 流是**按 record 组帧**的（16 字节头 `magic/schema/section/records/payload_bytes`），
     按固定 4 MiB 切块 feed 会拦腰截断 record 头 → `save_chunk_header_invalid`；
     必须按 `16 + payload_bytes` 切分。
- **旧批次快照（2026-11-18 day 2506）仍然拒收，原因是 catalog 漂移而非加载器缺陷**：
  国家流在 `end_country_restore` 报 `country_restore_rejected:catalog_hash_mismatch`。该快照头
  `schema=16` 与当前 `country::SCHEMA_VERSION=16` 相同，规模完全一致（goods 172 / professions 50 /
  buildings 470 / technologies 433 / research_signals 227），但 `saved_catalog` 与当前
  `catalog_hash()`（`-506376025623507606`）不同 —— 净数量不变说明是改名/重排而非增删。
  这是 fail-closed 的设计，**不要**为读旧快照加 catalog 兼容白名单（会把「旧快照静默套到
  catalog 已变的构建上」的风险带回来）。旧批次现场的正确用法是走 R3 的 `.pkinc` 重放
  （不需要 catalog 逐字节一致）。

### R5 无头复现提速

- `tools/runtime/Use-GdextLibrary.ps1` 做 `.gdextension` 的 debug/release 映射切换，往返
  hash `D8A99BBF…B045 → 8D22B653…4C4D → D8A99BBF…B045`（identical）、`git diff` 0 行；
  `verify.ps1` 有防呆项守住「别把 release 映射提交进去」。
- `Invoke-SaveReplay.ps1` 新增 `-UntilDay` / `-StopOnFault`(exit 2) / `-Bundle` / `-Release` / `-Json`，
  顺带把一直声明但没实现的 `-TimeoutSeconds` 修好（PS 5.1 的 `Start-Process -PassThru` 拿不到
  ExitCode，改用 `.NET Process` 抓双流）。
- 新增 `tools/runtime/Invoke-Soak.ps1`（包装 `headless_perf_record.gd`，统一 `tmp/soak_<stamp>/` + `summary.json`）。
- **修掉 `headless_perf_record.gd` 的 `rows == measured_samples` off-by-one**。根因不是端点差 1，
  而是「样本写入点不受预算约束、主循环 break 检查在写之后」，且 `measured_samples` 来自
  「主循环观测次数」而一次观测可覆盖多个 commit。改法：`_sample_budget_reached()` 在 4 个产行点
  截断、`measured_samples` 改为实际写入行数、非 fatal 时 `expected_rows` 恒为 `days`
  （比原来更严，authority=off 也不再走恒真比较）。前后：`rows=11 expected=10 exit 6` →
  `rows=10 expected=10 PASS`；400 天 soak `rows=400/expected=400`。
- 实测 400 天 soak（60×40）**34.6 s**（19.1 s 世界生成 + 9.3 s 仿真窗口），`fatal=false`、
  `ledger_failures=0`。吞吐 45.2 days/s 未打到 50 的 checkpoint，按约定只记 warning。
  目标「400 天 ≤ 10 分钟」达成（快 17 倍）。
- 注：仍有一处吞吐 checkpoint 未达（45.2 < 50 days/s），以及 `climate_authority=off` 模式在本构建
  里本就跑不出 commit（改前改后都失败，现在会明确报行数不符而不是靠恒真比较假绿）。

### R6 CI 一键核验与产物治理

- `tools/ci/verify.ps1` 唯一入口：`static` / `build` / `suites` / `soak` 四阶段，
  `-Quick` 只跑 static，`-WithSoak` 才跑 soak，`-DryRun` 只规划，`-Strict` 把 known-red 也算失败。
  退出码 0 全绿 / 1 失败 / 2 环境问题；写 `tmp/verify_<stamp>.json` + 人读摘要。
  实测 `-Quick` → **GREEN exit=0（16.6 s）**。
  **未完整跑通的阶段**：`suites` 一次全量尝试在跑到第 38/42 个测试（`family_effect_restore_forward_test`，
  22:22）之后停滞，未能产出一份完整的 suites 汇总；`build` 阶段未通过 verify 跑（当时的增量构建由
  C++ 改动方并行持有），但 debug 与 release 两个 target 都已单独构建到 0 错误。
  这两条要在下一次全量核验里补齐，别的阶段都已留证。
- 顺带发现一处**既有**的静默红：`tests/dots_completion/dots_completion_gate.gd` 的 `(d)` 两条
  静态契约断言在源文件拆分之后失效了 —— 门禁读 `native_simulation_host.cpp` 找
  `D7_TRANSACTION_MAGIC`/`"D7T1"`，但这两个标记已在 `native_simulation_host_journal.cpp`；
  读 `world_runtime_host.gd` 找 `config["authoritative_domain_mask"] = ...`，但该赋值已搬到
  `world_runtime_generation_adapter.gd`（且写法是 `host.runtime_authority_domain_mask`）。
  与本计划无关（本计划没动这三处），但既然发现了就记在这里，下一次动那两个文件的人顺手修。
- 沿用仓库既有惯例（`Invoke-RuntimeTests.ps1` 的 `$knownRed`）设 `known-red` 机制，只装
  **HEAD 既有、与本计划无关**的漂移：`check_cpp_deps.py`（6 条依赖边，点到的文件与 baseline 均
  未在本轮改动）与 `check_size_ratchet.py`（18 条，渲染/UI/geography 等）。人读摘要里单列原因。
- 本轮新增代码引入的 4 处 size ratchet 超限，按仓库惯例在**同一次改动里刷新 reviewed baseline**
  （`world_runtime_gm_adapter_part1.gd` 961→972、`economy_runtime.h` 2352→2365、
  `economy_runtime_diagnostics.cpp` 2975→3073、`economy_runtime_persistence.cpp` 2035→2042）。
- `check_large_blobs.py`：暂存区单文件 > 5 MB 失败（`git cat-file -s :<path>` 取索引体积），
  白名单按目录放行既有入库大文件，并明确「本项目不使用 Git LFS」。实测 6 MB 假文件 exit 1。
- `prune_tmp.ps1`：保留「最新 N 份 ∩ 最近 D 天」。实测 `-DryRun` 列出 `132 dir(s) → delete 112,
  975.36 MB`。
- **修掉两个 Windows 上必崩的既有工具**：`check_module_contracts.py` 与 `check_cpp_deps.py`
  读源码时没指定编码，中文 Windows 的 GBK 默认编码解 UTF-8 源码直接 `UnicodeDecodeError`。
  补 `encoding="utf-8"` 后都能跑到 0 violations / 只剩既有依赖漂移。这条正是计划 §9.2
  「23 个脚本的 Windows 适配清单」要发现的东西：实际是 33 个 `.py`，其中 **15 个需要本机适配**。
  清单写进 `docs/build-from-source.md` 的「Windows 单机核验」一节。

### 未达成与原因（下一轮直接从这里接）

1. **台账分类**：2727 条 `kind=unknown` 待分批补 `kind/stage/witness/playbook`（计划给两周窗口）。
2. **`INV-ECON-0040` 精确重放**：`.pkinc` 不记录 runtime slot id 与 family 成员关系，只能按
   `cohorts[]` 顺序 + witness 值反解；要精确重放得给 `cell.json` 扩 slot/family 列，属 schema v2 议题。
3. **`.pkinc` 的四个 missing 字段**：`commands.structural/ledger`、`economy_state_hash`、
   `ledger_hash` 需要各模块 facade 加薄包装（`scripts/game` 直调别模块原生绑定会被
   `check_script_native_access` 拦），属模块归属问题，不在本轮。
4. **旧批次全量快照不可加载**：catalog 漂移导致 `catalog_hash_mismatch`，见上。这是 fail-closed
   的正确行为；旧现场请走 `.pkinc` 重放。
5. **release 相对 debug 的提速没兑现计划预期**：400 天 soak 的耗时主要在世界生成（19 s）与
   harness 开销，release 只把仿真窗口从 9.3 s 压到 8.3 s（`authoritative_days_per_second` 45.2 → 50.3）。
   计划 §8.2-A 想要的「5–20×」要到「靠存档跳过世界生成」的回放路径上才显出来。
6. **`check_cpp_deps.py` 与 `check_size_ratchet.py` 仍是 known-red**：都是 HEAD 既有的漂移
   （依赖边 6 条 / 18 个超限文件，全部落在本计划没碰的文件上）。`-Strict` 下判失败。

### 一轮核验暴露的既有红：`runtime_country_parity_test`（2026-11-19 诊断，未修）

把全量 suites 跑完（首次真正跑完，41 个测试 640 s）之后，唯一红的是
`tests/runtime/runtime_country_parity_test.gd`：`33 checks, 5 failures`，稳定复现（6 次运行逐字一致，
只有计时计数抖动 → 不是负载竞态）。**与本轮故障基建改动无关**，证据：运行 DLL 的
`build_id=e6b869a3a+20261119T140626Z` 对得上工作区；`gdext/src` 里只改了 8 个 economy 侧文件，
`runtime_climate_*` / `native_simulation_day_shadow.cpp` / `runtime_country_pod.cpp` / `country_*` /
`native_simulation_host_worker.cpp` 全部未改（最后一次触碰是 `3ac23d64c`，11-17）；
经济→国家的唯一通道 TP 库存已被 `country_goods` 相等排除。**证据等级是推断（强），没做二进制 A/B**
（目录里现成的旧 DLL 早于 `world_ext` 的握手方法表，用它 A/B 会因握手失败而混淆结论）。

5 个失败只有 **2 条根因**（用 `PK_COUNTRY_SOAK_DAYS=2` 让 `budget=8` 走不到 tick 14 即可分离：
F1/F4 变绿、F2/F3/F5 照旧红）：

**RC-1 业务状态分叉** → F2/F3/F5。`first_mismatch_day=2`，字段 `research_deferred_points`（int64 lane）。
比较器在它之前已比过 `country_cash`/`country_goods`/队列/队长/权重/自动采购/已得+待激活科技/研究信号，
全相等；两侧公式文字也相同，所以只剩三种可能：**POD 科技激活路径没有像参考那样把这笔 deferred 清零**
（`country_runtime_research.cpp:915` 有清零，`runtime_country_pod.cpp` 全文没有处置 0）、
lane 形状不同（空 vector vs `{0,0}` 被 `operator!=` 判不等）、或 Modifier 派生的
`research_efficiency/cost_factor`（不在比较表里）不同。

**RC-2 worker 日死锁** → F1/F4。tick=14 的 graph token 恒 `status==3`、`pinned=country,effect`，
两条互锁：① worker 日卡在 11 且 `preflight_ok=0`，而 spurious-preflight 逃生分支要求
`_requested_authority_mask != 0`，纯 SHADOW host 不请求 ACTIVE 域 → 永远走不进去；
② `effect_pending` 永久 latch —— SHADOW 日执行里 Effect 是唯一不受 `climate_ok` 门控的域阶段，
整天 commit 前就推进 POD 日，而 SHADOW 路径没有 ACTIVE 路径那条 `day<=committed` soft-skip
（`native_simulation_stage_effect.cpp:44-47` 的注释写死了「再规划会死在 effect_pod_day_not_sequential
并永久 pin 0xFFF」）。`stall=climate_capacity@-1` 是派生位不是原因（该位从不 `note_day_stall`，
所以 `day_stall_day` 恒 -1，没法用它定位是哪天）。
另外 `test:331` 的 400 pulse 与设计里 `RUNTIME_GRAPH_STALL_RELEASE_PULSES=1200` 不一致，
**harness 永远看不到设计里的自锁放行** —— 这属测试假设过期，不是断言过严。

**顺带两条气候侧观察**（不单独成红，但同属既有问题）：day 3 起天气场整片偏移
（`vapor oob=502/600`、`instability 377/600`，相对差约 7%），`plant_available_water` 只是字段表里
最靠前的受害者；`terrain[0] ref=20 worker=0` 是 **worker 没写回海冰翻转**（20 = `SEA_ICE`），
不是默认值 —— 同日冰分数逐 bit 相等、只有当天新翻的冰带错（`oob=60/600`），指向
`si_apply_terrain_flips` 这个门（C++ 默认 false，GDScript 置 true）在 round 里没被打开。

**挡住结案的诊断缺口**：`native_simulation_host_country_boundary.cpp` 的 `record_country_parity_locked`
只记字段名、不记两侧值，所以上面 RC-1 的三种可能没法一眼排除。建议对齐
`runtime_climate_parity_first_difference` 的做法，记 `reference_bits/worker_bits`（向量记 size + 首个差异项）。
另 `test:388` 的「compared worker hash 非零」因未比较的 publish 也写 hash 而恒真，无区分力。

完整证据与 6 份日志在 `tmp/parity_diag/DIAGNOSIS.md`（`tmp/` 会被轮转清掉，结论已固化在本节）。

## 地图悬停展板与地名 LOD（2026-11-20）

地图界面补齐四件事，都是显示层，不碰模拟与存档字段：地块地名纸签、左侧市价/民情展板、
聚落地名常驻与 LOD、以及悬停期间的统一指针语义。

**1. 地名层改成保留式 + 三档视觉。** `scripts/rendering/settlement_label_layer.gd` 原来每次
相机移动都整层重排、且固定 176×24 的碰撞矩形；现在按「第 N 名 → 第 N 槽」分配槽位，
同格同槽不重播淡入，只有进出视野/换档才淡入淡出。视觉三档：首都 = 纸签 + 火漆印
（`decoration.wax_seal`）+ 朱红字，繁荣等级 ≥5 = 纸签 + 墨字，其余 = 描边米色字。
碰撞矩形改成按实际字宽计算，远档能多留几个大城。

**2. LOD 从等级阈值改成「等级阈值 + 屏幕预算 + 首都豁免」。** 阈值沿用原有四档
（<0.45 → 5、<0.75 → 4、<1.2 → 3、其余 2，测试锁定未改），另加远/中/近/贴脸
14/26/44/72 枚的屏幕预算，首都用 `CAPITAL_BONUS` 直接越过筛选。首都是政治事实、
日内不变，所以在 `refresh_country_visuals` 里从
`country_facade.snapshot(handle)["capital_cell"]` 推一次，不进每帧路径。
顺带修掉一个真 bug：环向地图的 ±period 拷贝会让同一聚落同时画两份同名纸签；
现在只取离相机最近的一份拷贝（最近的都出屏，其余只会更远）。

**3. 悬停纸签。** `set_hover_cell(cell)` 由悬停卡驱动，纸签在地块上方 16px 处升起 7px 淡入
（`_hover_rise_px` 单独存一份再叠加，动画期间新目标位置不会被每帧覆盖），悬停格自己的
常驻标签同时让位，避免同一句地名出现两次。

**4. 左侧展板。** 新增 `scripts/ui/cell_board_view_model.gd`（数据）与
`scripts/ui/components/cell_board.gd` + `scenes/ui/cell_board.tscn`（呈现）。
市价表一次线性扫描选出需求最大/本地供给最大/价格最高/价格最低/缺口最大五类物资，
每个角色只在「还没被选走」的物资里挑，所以不会重复；未解锁物资与本地尚无价格的物资
不参与。民情表按当地影响力取前五，口径与理念系统一致
（`population + owner_employed × 2 + funds / 1000000`，与 `IdeologyProfile` 默认值同源，
拿到配置后可用 `set_influence_weights()` 覆盖）。组织度按职业读
`cell_mobilization_snapshot`，缺失时该格留空轨道而不是伪造 0%。
两者都只读原生已发布快照，按 `cell:day` 缓存，且只在指针停稳 300ms 后才查
（原生 read-view 只有 128 条订阅位，逐格 hover 直接查会把它打满）。

**指针语义只有一处。** `CellHoverCard` 新增 `hover_cell_changed(cell_index)`（-1 = 无），
只在真的换格时发；地名层与展板都订阅它，不再各自解析指针或复判可见性/迷雾/滚轮。

**验证**（本轮实际运行）：

- `godot --headless --editor --quit` → 0 个 `Parse Error` / `Failed to load script` / `SCRIPT ERROR`。
- `tests/country/settlement_label_layer_test.gd` 5 checks / 0 failures（原有 5 条断言一字未改）。
- `tests/ui/cell_board_test.gd` 39 checks / 0 failures（新增：五类物资选择与去重、未解锁过滤、
  影响力排序、组织度缺失、read-view pending 契约、三段压缩、LOD 档位、首都豁免、悬停纸签、
  卡片避开展板）。
- `tests/ui/cell_hover_card_test.gd`、`tests/ui/cell_hover_view_model_test.gd` 通过。
- `tests/ui/cell_board_screenshot_qa.gd`（带渲染）在 1600×900 与 1280×720 各出两张图：
  纸签层级、火漆印位置、展板列宽与纸边留白已按截图返工三轮（首轮价格列被纸毛边切掉、
  正文字号 9px 糊成墨点、火漆印挂在纸签外侧）。

**未覆盖**：本轮没有跑起来真实世界会话，所以「真实经济负载下 read-view 订阅是否被
逐格 hover 打满」「自动生成的聚落名在纸签上的折行表现」只有推理没有实测；截图探针用的是
构造数据。`tests/ui/ui_scene_structure_test.gd` 有 10 条失败来自 `touch_number_pad.gd`
（已提交文件未加入该测试的 `SCRIPT_EXCLUSIONS`），与本次改动无关，未顺带修改。

## 2026-11-20 水域通行改为「一档一个时代」

**现状**：四档水级各自绑一个科技，军队与民事（贸易/开拓/殖民）共用同一张等级表。

| 水级 | 地形 | 科技 | 时代 |
| --- | --- | --- | --- |
| 湖泊 | `LAKE` | `tech.river_transport` 河运 | 农耕（原王国） |
| 浅海 | `COAST` | `tech.military.coastal_transport` 近海运兵 | 王国（原帝国） |
| 远海 | `OCEAN` | `tech.celestial_navigation` 天文导航 | 帝国（原探索） |
| 深海 | `DEEP_OCEAN` | `tech.oceanic_ship_design` 远洋船舶设计 | 探索（不变） |

`tech.oceanic_navigation` 不再单独发放航道，只保留远洋船舶、远洋造船厂与「海上作业」+48%。
天文导航的研究路线证据由「地图学」（探索）换成「自然哲学」（帝国），`knowledge_basis`
替代组同步改；帆船渔场继续由「河运 + 渔舟 + 沿岸捕鱼 + 手工锯木」的应用交汇解锁，
建筑与鱼货的科技标签仍挂 `tech.river_transport`（建筑只允许一个科技标签，且
`technology_unlock_closure_audit_test` 要求鱼货的替代科技落在水产养殖的硬前置闭包内）。

**代码**：`economy_runtime_catalog.cpp` 的 `_water_tech_shallow` / `_water_tech_far`
改指向近海运兵与天文导航；epoch capture 复用同一组成员，无需另改。DLL basename 升为
`dots_ext_water_tiers_v1`（debug + release），`dots_ext.gdextension` 已改指向。

**验证（本轮实跑）**：

- `technology_network_v5_contract_test`：433 节点 / 0 失败。
- `technology_topology_audit_test`：PASS（433 节点 / 15 分支边）。
- `technology_application_intersection_schema_test`：PASS。
- `technology_water_corridor_card_test`：19 checks / 0 failures。
- `technology_application_ui_test`、`era_advancement_service_test`：通过（135 checks / 0 失败）。
- `tests/world/water_transport_runtime_test.gd`：0 failures（浅海=近海运兵、远海=天文导航）。
- `tests/world/water_trade_real_map_test.gd`：0 failures（真实地图水运订单守恒）。
- `military_native_binding_test`：功能性用例全部 ok；100k/2048/4096 bench p95 = 5.71 ms，
  仍高于 2 ms 目标，属既有性能缺口。

**既有未通过（与本次改动无关，未顺手修改）**：
`technology_unlock_closure_audit_test` 5 条（药草种植园资源）；`technology_industry_chain_balance_test`
35 条（纸/铁路产线升级收益与同代重复建筑）。

**军队水级门禁**：同一天补齐，军队不再按「连续水格 ≤ 3」判定，详见下一节。存档：科技表与
军事目录 hash 变化，旧 PKCN/PKMI 以 `catalog_hash_mismatch` 拒绝，按新开局处理。

## 2026-11-20 军队水域通行改为按水级判定（删除连续水格 ≤ 3）

**规则**：水格等级来自 landform（0 深海 / 1 远海 / 2 浅海 / 3 湖），与贸易航道共用
`gdext/src/water_tier.h`；国家可进入「等级 ≤ 已解锁最高档」的水格，高档覆盖低档。
科技对应：河运（农耕）= 湖、近海运兵（王国）= 浅海、天文导航（帝国）= 远海、
远洋船舶设计（探索）= 深海。远洋运兵（探索）不再解除任何距离限制，只剩海运运力 +25%。
距离不再参与判定：6 格宽的浅海与 1 格宽的浅海一样可渡（selftest 用 6 格横渡反证）。

**代码**：
- 新增 `gdext/src/water_tier.h`（四档 + landform 映射），`economy_runtime_water.cpp` 的
  `classify_water_class` 改为调用同一函数，两个域不再各写一份映射。
- `MilitaryCatalog` 的 `coastal_transport_bit / ocean_transport_bit` 换成
  `water_lake_bit / water_shallow_bit / water_far_bit / water_deep_bit`；`military_catalog.json`
  的 `unlock_tech_ids` 变为「河运 / 近海运兵 / 天文导航 / 远洋船舶设计」四槽，
  `military_catalog_compiler.gd` 的 `_compile_naval_unlocks` 改名 `_compile_water_unlocks` 并校验四槽齐全。
- `military_core_path.cpp`：删除 `kSeaRunMax / kSeaRunStates` 与 `(cell, water_run)` 状态维度，
  `find_path` / `find_exploration_path` / `preview_path` 全部回到每格一个状态；`passable_for`
  改走 `water_tier_from_landform` + 解锁档位比较。海格 1.5× 步成本、1.5 天/格、强制 EMBARKED、
  0.2%/天损耗都不变。
- DLL basename 仍是 `dots_ext_water_tiers_v1`，debug + release 已重编并重新指向。

**验证（本轮实跑）**：
- `tests/military/military_native_binding_test.gd`：naval 用例全部 ok —— 无科技时浅海与单格湖都被拒；
  河运过湖不过浅海；近海运兵过 6 格浅海（反证距离不再限制）不过远海；天文导航过远海不过深海；
  远洋船舶设计过深海且嵌套回湖/浅海/远海；预览天数仍为 3×1.5+1=6；EMBARKED / 上岸恢复姿态 /
  0.2%/天损耗全部保持。100k bench p95 = 4.98 ms，仍高于 2 ms 目标（既有性能缺口，未变差）。
- `tests/world/water_transport_runtime_test.gd`：0 failures（经济侧航道未回归）。
- `godot --check-only` 逐个检查本轮改过的 GDScript：0 parse error。

**未覆盖**：跑验证时工作树里另一条线（weather / physical_circulation / map_baker）正在改，
`game_save_coordinator.gd` 等依赖脚本编译失败，导致需要整图启动的 GDScript 测试（军事目录
`compile()` 全链路、军事烟雾测试）本轮无法运行；上述 GDScript 结论仅来自 `--check-only`。
待那条线落地后需补跑：军事目录编译校验 + `military_runtime_smoke_test`（含既有 8 条 fixture 失败基线）。

## 天气降水频率治理（2026-11-20，W1–W9）

**问题**：玩家反馈「降水极其频繁」。实存档解码（CLM2 lane）显示陆地 55% 的格子同时在下雨，
但下雨格只比平均湿 1.8 倍（地球量级约 10）—— 是「到处都是毛毛雨」，不是雨太多。

**根因（按贡献排序，均已实测）**：

1. `convergence` 是半波整流均值，均匀风场（零辐散）读 **0.3333**，却被当 0–1 物理辐合乘 1.00/1.95；
2. RAIN 判定是单阈值 `precip > 0.040`，**无条件**通过 —— 下一点就报雨；
3. STORM/MONSOON 判据比 RAIN 松，出现「RAIN 2.6% / MONSOON 13.8%」的排序倒挂；
4. native daily 从未填 `wx->temp_anomaly` ⇒ 分类器距平恒 0 ⇒ 旱灾/热浪结构性不可达；
5. `field_precip_spatial_smooth` 从未由 GDScript 下发，生产吃 C++ 默认 0.30。

**改动**（C++ 权威 + GDScript 镜像同步）：convergence 改有符号净流入（四份镜像、开关已退役）、
6 个消费者阈值按新分位重标（p50 0.376→0.016 / p90 0.537→0.458 / p95 0.612→0.636）、
RAIN 改四项合取门（`weather_precip_classify_gate_land/water = 0.095/0.076`，`mp_cloud_gate` 0.22/0.12→0.18/0.10）、
STORM/MONSOON 补过 `meaningful_precip`、补 `wx->temp_anomaly` 与独立的 `weather_classify_anomaly_cap=0.12`、
空间平滑纳入 profile。详见 `docs/architecture/feature-guides.md` 的「天气场分类与降水频率」。

**效果（60×40 / seed 20260727 / net 口径 / 365 日均衡）**：

| 指标 | 玩家存档基线 | 现在（365 日均衡） |
|---|---|---|
| 陆地降水格 | 55.0% | **17.94%**（季节振幅 15.3–23.4%） |
| 全图降水格 | 35.6% | 11.88% |
| 陆地集中度 | 1.817 | **5.576** |
| 高压区(ψ<−0.05)降水率 | 34.5% | 15.08% |
| `moisture == 1.0` | 33.9% | 7.2% |
| `land_moist_med` vs 生成期锚点 0.410 | 0.981（2.39×） | 0.452（**1.10×**） |
| DROUGHT | 0 | 1.4% |

净水收支随窗口收敛：day 0–60 漂移 11.07%/天 → day 180–365 **0.134%/天**（约等于闭合）。

**验证**：`weather_convergence_metric_test` 3/3、`weather_field_solver_test` 26/26、
`runtime_climate_parity_test` 175/175、`runtime_climate_stage_order_contract_test` 582/582、
`native_daily_weather_split_graph_test` 25/25、`native_weather_daily_readiness_test` 12/12、
`golden_day_hash_test` 203/203；120×80 × 12 日 19 s。退役 legacy 后 probe 37 个数值字段
与退役前**逐位一致**。

**遗留**：

- HEATWAVE 仍为 0（其窗口 `temp_anom∈[0.04,0.05)` 且 `precip∈[0.006,0.012)` 被 DROUGHT 遮蔽），
  需在「降 temp_anom 门到 0.03」与「调整与 DROUGHT 的排序/区分条件」之间二选一，改动必须带 30 日实测。
- `climate_parity_probe.gd` 仍坏（legacy 生成路径），parity 目前由 `runtime_climate_parity_test` 覆盖。
- `PK_CLIMATE_SYNOPTIC_OFF` 是同类长期 A/B 开关，本批未动，已记入「运行时开关存量清单」待后续处理。
- 供给侧未改（`weather_land_evapotranspiration_gain` 保持 1.6）。A@1.30 的 365 日均衡是陆地 14.61%，
  但会把 `land_moist_med` 压到 0.387（低于生成期锚点 0.410），故未采用。

## 玩家 UI 重复解释精简（2026-11-21）

- 调整 15 个展示脚本：干旱/洪泛只留标题；移除地图图层同义描述、岗位空缺猜测、组织度点击引导、
  未知科技解释、投资机制套话、和平填充提醒、理念评分公式和年报重复原始账目；压缩满意度、威望及图例说明。
- 空资源整节隐藏、投资注脚随内容隐藏、科技条件去掉重复引导。告警纸片按内容收缩并用实际尺寸约束屏幕边缘。
- 全项目 headless editor 编译：0 Parse Error / Failed to load script / SCRIPT ERROR。
- `annual_report_test.gd`、`technology_workspace_smoke_test.gd`、`inspector_geography_semantics_test.gd` 通过。
- 临时渲染探针 `Project/project-keynes/tmp/ui_copy_screenshot_probe.gd` 在 1280×720、2560×1080、930×558 截图并检查标题与宽度：干旱/洪泛均为 48×31，0 失败；
  人工复核 930×558 截图。截图为固定数据组件验证，未覆盖真实世界快进。
- `cell_situation_layer_test.gd` 仍有 1 条旧日序文字断言失败（要求“第 5 天”，当前实现用日历日期）；
  `annual_report_ui_test.gd` 有 2 条撕纸蒙版资产断言失败。修改前脚本副本对照复跑结果相同。
- `player_map_overlay_smoke_test.gd` 有 1 条 merged dirty 刷新次数断言失败，未归因于本轮文案改动，保留日志。
- 证据位于本机临时目录 `keynes-copy-*.json`、`keynes-copy-compile.log`、`keynes-copy-screenshot.log`、
  `keynes-copy-{1280x720,2560x1080,930x558}.png`。FMOD 渲染探针退出仍有 debugger/capture 日志。

## 2026-11-21 生物分布图标接入

- 根因：覆盖层另设图标映射，将玉米、水稻、马铃薯和多种经济作物归为 `economy.crop`；该键实际显示麦穗。多种动物复用牲畜图，橡胶树、芦苇、蚕复用植被图。
- 覆盖层直接交付 `bio.*` 物种键，展示映射集中在 IconCatalog；修正小麦、水稻、玉米、马铃薯、棉花、亚麻、马匹的旧键解析。作物复用原有纸贴；马、羊、山羊、牛、猪、骆驼、牦牛、蚕使用新增透明图集。正式图集生成时通过 `referenced_image_paths` 明确传入游戏已有 `goods_02.png` 作为画风参考，首版无参考生成图未接入工程。图集语义、裁切与参考来源已登记 manifest。
- 验证：最终全项目 headless editor 导入无 Parse Error / Failed to load script / SCRIPT ERROR / ERROR；gda 运行 `tests/ui/icon_catalog_audit_test.gd` 返回 exit_status=0、PASS，覆盖 20 种生物及独立图标身份和像素。带渲染探针核对按钮实际纹理、20 种生物覆盖及去重，0 failures；已人工检查 1280×720、2560×1080、720×480 截图。证据位于本地 `Project/project-keynes/tmp/bio_icon_qa/`（忽略目录）。带渲染启动时 FMOD 调试器输出 No active debugger / Capture not registered，未影响图标校验及截图；未修改音频模块。
- UI 反模式扫描已运行；本次涉及 UI 文件的命中为既有颜色绘制及地图覆盖层按钮 FOCUS_NONE（规范允许），新增映射与资产未引入玩家文案问题。

## 顶栏国库脚注与残留计算说明补清（2026-11-21）

- 修改 8 个 UI 脚本：删除国库悬停卡折算脚注与零活动套话、经济总览收支悬停解释、理念收益计算说明；
  物价、生活水平、家族威望及年度满意度去掉加权术语，保留成本基准、警戒线与生活档量程。
- 国库卡已有按内容隐藏 note 的逻辑，无需修改组件：删除脚注后纸面随内容缩短。
- 全项目 headless editor 编译无脚本错误；经济卷宗视图模型、年报数据回归通过。
- `tmp/hud_copy_followup_probe.gd` 对照修改前模型：1/7/30 日历史下除 note 外所有字段逐项一致；
  1280×720、2560×1080、930×558 渲染检查脚注隐藏、卡片高度下降、卡片未越界，共 15 项通过。
  人工复核国库卡裁图，未运行真实世界快进。证据：系统临时目录 `keynes-hud-copy-probe.log`、
  `keynes-hud-copy-card.png`、`keynes-hud-copy-*.png`、`keynes-copy-followup-*.json`。
- `hud_status_card_test.gd` 唯一失败位于第 62 行：仍断言滚动国库 note 包含“最近 1 日”，与本次删除脚注的需求相反；
  其余检查通过。未放宽或改写原测试断言。渲染退出仍有 FMOD debugger/capture 日志。

## 战争迷雾连续遮罩（2026-11-21）

- 根因：`fog_of_war.gdshader` 对三格知识度使用锐化权重，造成格内透明度平台；低频扰动不改变这种平台。固定同心视野的 `before_mask.png` 复现环状蜂窝；关闭噪声的格心连线测试旧版仅 11/12 段变化，新版 12/12。
- 实现：显示遮罩在格间连续插值，只在原始格心小范围保留锐化；涉及极地 padding 的三角形保持原混合。原两次噪声的频率从 0.0042 调到 0.010，仍按原长度上限约束。天气与迷雾共用 `pk_overlay_fog_weights`；不改玩法视野、存档、候选格范围、纹理采样数量或绘制通道。
- 真实 Vulkan / Godot 4.6.2 / RTX 3070 Ti：`fog_cell_field_test.gd` 151 项、`weather_overlay_field_test.gd` 164 项、`fog_continuous_mask_test.gd` 7 项通过；混合可见/未知格心 42 个无违例，地形早退遮挡与极地 padding 无违例。headless `terrain_draw_coverage_test.gd` 25 项与 `detail_fog_culling_test.gd` 14 项通过；gda 新测试脚本检查 `valid=true`，模块地图护栏通过。
- 固定合成视野、760×720、q2、时间 17，修改前/后以 ABBA 顺序各采 180 帧 GPU 时间。首轮中位 0.765/0.791 ms（p95 0.979/0.947）；最终轮中位 0.803/0.554 ms（p95 1.035/0.991）。存在 GPU/环境波动，不据此宣称加速或零成本；未观察到稳定增耗。截图人工复核蜂窝平台减弱。未进行真实生产世界全地图帧时或手机实机验证。
- 验证限制：共享 `render_data_tables_test.gd` 的原有 `_lattices` 在 cycle 0/4 各失败 1 项，画质/分辨率切换与天气表检查通过。只运行未改动的 `_lattices`（依赖 `fog_gradient_lattice.gdshader`、`fog_lattice.gdshaderinc`、`cloud_noise.gdshaderinc` 与 `render_data_table.gd`，均未修改）仍复现同样 2 项失败；未放宽断言，未将整份测试记为通过。长度护栏报告当前工作区已有 46 项超限，本次未增加超限文件行数。图形测试退出伴随已有 FMOD debugger/capture 日志。
- 本地证据：`.codex/tmp/fog-edge/` 下 `before.gdshader`、前后云层与 mask PNG、`probe.log`、`invariants.log`、`weather.log`、`coverage.log`、`detail-coverage.log`、`data-tables.log` 与 `lattice-only.log`。未提交或推送。
## 迷雾格心斑点与轮廓起伏修正（2026-11-21）

- 用户指出上一轮合成图边缘存在规则小点，并要求保留云缘不规则起伏。根因是格心附近把连续权重局部切回锐化，给原本连续的知识度场叠加了格心小凸包；上一轮人工验收漏掉了这个视觉问题。
- 改为坐标扰动在原始格心平滑归零，地图内部全程使用连续权重；极地 padding 仍用原有混合。复用原来的两次噪声给过渡带增加云团尺度的凹凸，深浓雾 k<=0.05 与全可见端不变。迷雾和天气门控共用三角形、权重与轮廓函数，无新增纹理/噪声采样或绘制通道。
- 新增二维线性知识度场回归：用精确 RGBA8 字节构造输入，误差上限 0.0025 只覆盖回读量化和相机亚像素对齐。冻结的有斑点版本最大误差 0.003526，修复后 0.002042；原始浮点写入版本也在修改前复现 0.007738。没有用放宽断言绕过问题。
- 同心合成视野 48 个方向的半径跨度为 38 世界单位，断言必须大于一个 hex_size（22）；防止仅去掉小点后把边缘抹成圆。人工检查新的云层与遮罩截图，规则格心斑点消失且轮廓保留较大凹凸。
- Godot 4.6.2 / Vulkan / RTX 3070 Ti：迷雾原有不变量 151 项、天气门控 165 项、新遮罩与旧版对照 10 项通过。42 个混合可见/未知格心保持原状态，浓雾早退、全可见与极地 padding 无违例；模块地图和改动文件 diff 检查通过。
- 固定 760×720、q2、时间 17，旧版和修复版均使用其实际频率 0.010；ABBA 各 180 帧，最终 GPU 中位 0.513/0.596 ms，p95 0.593/0.769 ms。前一轮同条件中位 0.623/0.591 ms，仍有环境/GPU 波动，不据此宣称零成本或加速；未测手机与生产世界全图帧时间。
- 证据：`.codex/tmp/fog-edge/dotted*` 冻结上一版，`dot-repro.log` 保留先失败的复现；`dot-fix-invariants.log`、`dot-fix-weather.log`、`dot-fix.log` 与 `dot-fix/{before,after}{,_mask}.png` 保存最终验证。共享梯度测试原有两项独立失败仍按前节记录，未改动相关梯度实现或宣称通过；未提交或推送。
## 2026-11-21 同代建筑差异化与精简

- 依据：全量 470 个 BuildingProfile 中，同代完整产出集合相同的 38 组共 90 座，另有 3 对部分产出重合及 2 组军事同角色建筑。审查配方、真实条件、人员与特殊消费者；名称、规模、工具品质和只产通用科技点不单独构成新功能。
- 已实现：建筑 470→449，删除 21 种，其中知识建筑 21→9（删除 12 种同代科技点副本）。保留原料/能源、地理、产品组合或雇佣阶层的实际选择。逐项删除及保留理由见 `Project/project-keynes/tools/technology_tree/building_distinction_review.json`；其中 absorbed_by 不是存档兼容别名。
- 家庭纺织坊改为硬投入韧皮纤维，改良家用织机改为硬投入亚麻纤维，均保留自营、不耗燃料的经营方式；不再占地直接产布。对照蒸汽纺织厂的煤、染料和雇员路线保留实际选择，并校准新增配方的单位投入产出递进。水力火药厂增加真实河流条件。公共卫生与核医学建筑明确命名为制药厂，不宣称未实现的公共服务。
- 保留潮汐、洪水历法、牧群、灌溉等科技已有的贸易、减灾及研究效果；删除空目标的地籍/地理分析机构专属产出项。地理信息系统改为工程研究效率 +5%，仍沿用 Country 的既有研究效率消费者；不新增模拟域或 C++ 状态。
- 接入完整性：重接产业链前驱、商品科技生产许可、受影响科技绑定/支持与应用交汇；发展成就改接家庭亚麻圃，Trigger 改接书记学校。黏土合并保留原土料坑的零建材入口，沤麻池明确依赖野生亚麻与雨养田制，避免删除旧农场后出现供料解锁断链。统一早期知识机构的研究机构链，并移除未使用的旧地区建筑选择函数。
- 已重烘 economy、effect、effect_extensions、display、technology 快照，更新稳定 ID/内容清单；983 项加载源哈希全部匹配。活跃 scripts/data 中已删 ID 的完整词引用为 0。目录身份已变化，旧目录存档沿用严格 hash mismatch 拒绝，不静默映射旧建筑。
- 验证通过：Godot 4.6.2 headless editor 导入，未见脚本/资源加载错误；14 项核心回归（建筑差异化、产业链元数据、科技目录、作物链、bootstrap 合同、建筑显示、开局规划、正式开局、物资账本、每日确定性、建筑运行、科研、采购、协作加载）。`check_intent_baselines.py --runs 2` 的 7 类完整 intent 证据各重复两次一致。`git diff --check` 和 module-map 检查通过。新增差异化回归已加入常规 CI 测试列表。
- 全量审计未宣称通过：修改前已记录的目录内容失败仍存在；科技/产业时序审计 35→31 项，无新增项；药草 5 条种植地依赖闭包失败与隔离的修改前目录逐项一致。额外隔离复跑确认铜矿效率 1 项和金银矿 6 项失败原本存在。未放宽相关断言，也未用重试或延长超时掩盖失败。重复判定修正了误用 dependency-group offsets 作为 building offsets 的索引问题，改查实际地理条件、产品比例及军事角色/建材路线。
- 静态总护栏仍有非本轮文件的 size ratchet 46 项、skill mirror 6 项失败；没有上调尺寸基线或修改无关 skill。
- 证据：本机 `.codex/tmp/building-distinction-delivery-20261121/`（含 summary、content_audit、baseline_comparison、editor-import），`.codex/tmp/building-distinction-final-intents-20261121/`，以及 `.codex/tmp/building-distinction-original-complete/` 的隔离原目录对照。未进行图形实玩或长周期经济平衡验收；未修改原生公式、ABI 或存档段格式。

## 2026-11-21 第 2 批：10 条 trade.good 消费点接通（705 → 715）

- 范围：把 10 条 `country.trade.good.*` 的容量/速度消费点在真实运行路径上接通，消费点接通数 **705 → 715**。6 条容量（`wool` / `horses` / `spices` / `iron_ore` / `cloth` / `glassware`）落在 `gdext/src/economy_runtime_trade.cpp:770`（读数组）、`:772-783`（乘法）、`:781`（`offered`）；4 条速度（`wool` / `horses` / `spices` / `salt`）落在 `gdext/src/economy_runtime_trade_settlement.cpp:1441-1449`。承载科技节点为 `tech.market_institutions` / `tech.steppe_caravan_corridor` / `tech.oasis_caravan_junction` / `tech.caravan_water_rights`。两文件合计 +49 行（`trade.cpp` +21 / `settlement.cpp` +28），无第三处改动。
- 证据一（激活器非真空）：modifier store 读值证明 `wool.capacity_factor` 被送到 **98304**，不是「声明了但没生效」。
- 证据二（精确倍数）：活车道诊断显示该因子在 `economy_runtime_trade.cpp:764-785` 处按精确倍数放大成交量，×1.5 与 ×1.0 各自可失败；该 lane 受**目的地侧**约束。诊断跑使用 env-gated trace 与因子 override，**只作诊断、不作验收件，跑完已拆除**。
- 四臂降为中性证明：L1 / L3 与 L0 逐字节一致（`salt` 的 −5% 会经库存与价格传导，故 L1 不能当 A4 的隔离证明），仅 L2 出现差异且方向为成交量上升。四臂统一单大陆 + `days=120` + `pipeline_depth=0`；默认群岛世界 120 天零交易，不用于任何臂。
- `state_hash` 跨跑不一致已定性：`country_ai_hash_memory`（`country_ai_core.cpp:1266-1290`，污染源 `last_*_day` 与两个 EMA）与 `economy_runtime_state_hash.cpp`（墙钟切片、cell 结算日/代次、待处理命令；该文件属外来 WIP，钉内容 blob `936ef9a39e18b576cec1be71935dd205cd2eebac` / 91,581 B）。结论：**决策结果可复现，记录节奏依赖墙钟；含这些字段的哈希不可跨跑复现**。
- A1 双源已闭环：独立命令复现 `compile_counts={"economy":1,"modifier":1}`，同轮 `cache_hits={"economy":4,"modifier":1}`（两次目录加载，一次真编译一次命中，不矛盾）。`modifier_term_invalid` 不是 result 行字段、只能按 token 计数，五臂实测全 0。
- 明确不覆盖：自然经济里「羊毛贸易量上升」**未证**（该商品 120 天 0 条 trace、不参与贸易）；诊断车道只证明了乘子生效，不等于自然经济成交量上升。
- 3 条 pending 留下批：`barracks_capacity_factor` ×2（`military_core_store.cpp:812-819`）、`convoy_escort_factor` ×1（`military_core_logistics.cpp:954-961`）。
- 独立发现（记录、不修）：默认群岛 120 天零交易；国家 125 天停在 1 格；国内贸易结构上不可能；A4 的 7 个商品不参与贸易。
- 已知滞后：10 条 term 的 `runtime_consumer` 仍是 A4 之前的行号，未改（改会动产品哈希 `2A6D20FE`，而本批验收正引该哈希）。
- 被排除的跑（不进任何计数）：缺 `csv stop` 的首份 L3（由 L3b 顶替）、缺 result 行的 L0b、缺 `--` 致参数未生效退回 `days=50` 的一次开局。
- 口径与已知风险：`gdext/src` 现 **19** 个 dirty（A3 四 + A4 二 + 外来 13，含 `economy_runtime_state_hash.cpp`）；DLL 归因只按源码差异，不按二进制可重建（PE 时间戳）。最终臂 DLL `E820EF79` / 16,508,928 B；产品 JSON `2A6D20FE` / 2,845,758 B / 467 节点 · 718 效果 · 787 硬前置 · 683 解锁。

## 2026-11-21 第 3 批：B 组 3 条死 stat 补读点（715 → 718/718）

- 范围：给 3 条「有写入、无读取」的死 stat 补真实读点，消费点接通数 **715 → 718/718**。`country.military.barracks_capacity_factor`（`tech.military.war_bands` / `tech.military.standing_army`）乘进 `gdext/src/military_core_store.cpp:815` 的 posts 汇总，读取在 `:825`（`MSTAT_BARRACKS_CAPACITY`）；`country.military.convoy_escort_factor`（`tech.military.radio_command`）读取在 `gdext/src/military_core_logistics.cpp:964`（`MSTAT_CONVOY_ESCORT`），`:966` 出 `escort`。
- 中性对照：默认值 1.0 时 48 行 / 4800 posts **逐字节不变**；非默认值按精确倍数变化（`factor 72089`：164000 → 180398 posts，q16 下界 180401 / 十进制 180400 作为反例排除）；封顶在缩放后仍生效（`524288`；把乘法挪到封顶之后得 `527995`）。护航以同一批 shipment + 同一批 rng roll 反读拦截边界：`risk(1.0)=16384`、`risk(1.5)=13107`。
- 七条断言全绿，并做了三次变异证「能红」：读点换常量（兵营）→ `factor 72089` 红；乘法挪到封顶之后 → `cap still enforced` 红而 72089 仍绿；读点换常量（护航）→ `escort 1.5` 红。Assay 另建仓库外变异副本（`5A149F5F`）独立复现同一红绿组合。
- **交付范围自述**：本批原定只改两个文件，实际交付三个——`military_core_selftest.cpp`（+172）是 Chief 裁定随产品交付的可失败防回归凭据，「断言写进去」与「断言能失败」是两件事，故留在树里。三文件 `+191 / −3`，blob 为 `f513f715df12…` / `b9a3b1bbd5b1…` / `167f43a40019…`。
- **边界**：`718/718` = 「读点已接 + 编译通过 + 断言可失败」，**不是实机可观测**。两条读点在世界里都没有流量（`posts_for_cell` 60 天 0 次调用、`_shipments` 120 天为空）。不得据此宣称「军事容量/护航在游戏中生效」。
- 声明修订：`country.trade.good.*` 那 10 条原声明指向国家维度那段（`economy_runtime_trade.cpp:749-762`、`economy_runtime_trade_settlement.cpp:1412-1420`），照声明当场验会扑空；改为逐商品段 `760-783`（6 条）与 `1426-1447`（4 条）。属「声明指错门」，读点本身一直通。
- DLL：debug `C9676342` / 16,527,872 B / 17:57:23；release `42E33AB4` / 14,217,728 B / 17:58:39。`bench big p95` 为**既有 FAIL**（本批 5.0875，基线 `E820EF79` 4.525 同样红），按断言原文逐条声明剔除，不按前缀豁免。
- 判据教训（可复用）：stdout 报告在 **37,339 字符处被截断、断在汉字中间**，不能当 ok 清单；同名断言 808 行只有 476 种，必须用多重集差；`cap fixture is above the cap before truncation` 只是防真空前置守卫，不是封顶生效的证据。
- 最终产物 `technology_network.json` = **`F561CF2A` / 2,845,758 B / 18:09:30 / LF**（相对上一版 `1EB93EBD` 恰为 `10 10`，只改那 10 个声明串）。`implementation_plan.md` §7 六项落地检查表已在这一版上复跑：**6/6 通过**（JSON 解析与 41 键、term 十字段、U+2212=0、unmapped 0、主干 66/66、unit 语义 0 违例）。

## 2026-11-23 物资合并第 1 组：删结构钢与型钢轧机（货 172→171，建筑 450→449）

- 依据：172 件货 / 450 座建筑的全量取证。`structural_steel` 只有 1 座产出建筑、**0 个精确输入消费者**、0 处家户/军事/晋升篮子引用；它的 216 个建造槽全部是 `structural_metal` **类别槽**（216 座建筑各 1 个），而 `steel` 的 `substitution_category_ids` 本来就含 `structural_metal`，所以删货不动任何建造 BOM。
- 纯损耗：`steel_rolling_mill` 投入 24,800 钢 + 8,600 煤 + 900 工具，产出 19,200 结构钢/日，产出无人消费——是一座把钢材换成更贵同质材料的净损耗转换。
- 已实现：删 `data/goods/structural_steel.tres`、`data/economy/buildings/steel_rolling_mill.tres`；`technology_network.json` 的 `tech.coke_smelting` 去掉 2 条 `expected_bindings`、2 条 `content_effects`、1 条 `support_buildings`，`effect_summary` 同步改文。链条复核：`steelmaking` 链删后为 `steam_steel_works`(step 1, entry) → `steel_plant`(step 2, mainline)，无断层、无悬空 `predecessor_building_ids`。
- 验证：`modern_economy_catalog_test` 的「货条目数 = goods 目录 profile 数」通过（171 = 171），目录编译通过；`technology_content_binding_audit_test` PASS 且全文 0 处提到 steel；`building_progression_catalog_test` PASS；`icon_catalog_audit_test` PASS（图标是图集贴纸，`good_structural_steel` 贴纸保留、未重排 `goods_05` 图集）。`verify.ps1 -Quick` = 7 通过 / 1 红 / 2 既有红。
- 已知红（均非本次）：`check_fault_taxonomy.py` 报 `gdext/src/runtime_climate_authority.cpp:699` 的 `climate_section_version_mismatch_expected_` 未登记；`check_cpp_deps.py`、`check_size_ratchet.py` 是工具自述的既有基线漂移。`modern_economy_catalog_test` 余下 15 条红：12 条 `*/protein` 变体（同一工作区另一路正在改消费方案）、`chariot_wright` 工具槽、4 条 `method_*_r8` 伪升级、`wrought_iron`/`raw_hide` 单候选。
- 未做（必须紧跟，不能算完成）：`data/loading_catalog_v1/*.res` **未重烘**。快照指纹校验只在编辑器内执行，导出包无条件使用快照——不重烘则导出包里仍是含结构钢的旧目录。重烘须等另一路 `food_fat` / `grain` / 12 套消费方案落定后由单人执行：`Godot_v4.6.2-stable_win64_console.exe --headless --path <项目> --script res://tools/prebake_loading_catalogs.gd`。
- 未做：`tools/technology_tree/technology_tree_report.{md,html}` 未重生成——导出器在**改前就红**（`stable_technology_id_manifest_mismatch`：清单 433 个科技、数据 467 个，多 37 缺 3），与本次无关，不能拿它当验证手段。
- 存档：目录身份已变，旧 PKEC/PKCN/PKRS 按 fail-closed `catalog_hash_mismatch` 拒绝，不做索引静默映射（沿用既有策略）。

## 2026-11-23 油脂并轨：唯一油脂走 `edible_oil`，废掉「畜产品当油」

- 背景：另一路曾把 `livestock_products` 挂成 `food_fat` 的第二个变体（12 套消费方案，偏好 32768 = 食用油的一半）。用户判定「畜产品当油文不对题」，选择「一件通用食用油 + 让相关建筑直接产油」，不新增货。
- 已实现：① `edible_oil.technology_tags` 增 `tech.herd_management`（可用性是 OR 门，`economy_runtime_availability.cpp:95-104` `cell_has_requirements` 命中任一标签即算可用），使农耕期起的畜牧建筑能产／家户能吃；② `tech.herd_management` 增 `expected_bindings` 与 `content_effects` 各一条 `good.edible_oil`，`effect_summary` 同步；③ 6 座畜牧／屠宰建筑各增一路 `edible_oil` 副产。
- 产量口径（r = 2.4%，按畜产品吞吐等比摊，四舍五入到整数）：牧野营地 2,016→**48**、庄园牧场 52,571→**1,262**、大牧场 725,841→**17,420**、智慧畜牧 6,183,090→**148,394**、屠宰场 5,610（投入）→**135**、机械化屠宰场 328,015（投入）→**7,872**；合计 **175,131/日**。原两座玉米油厂供给 306,313/日；家户需求均值 35.083/人/日、工业（制皂 ×2 + 综合食品）17,846/日。10k 人时总供给约为需求的 1.31 倍，20k 人时 0.67 倍；两座油厂在 8,222 人以下本就不会盖起来，故低人口的动物脂是「保底」而非过剩。
- 方案侧：`food_fat_livestock` 变体从 12 套方案各删 10 个数组列（共 120 列，含 24 个偏移列），脚本化删除并逐文件校验三条不变量（`need_variant_offsets` 尾值 = 变体数、`variant_component_offsets` 尾值 = 分量列长、两组偏移单调）。删除后 12 套方案与 HEAD 逐字节一致——另一路那笔未提交的「双变体」改动正好被本次撤销。
- 验证：`modern_economy_catalog_test` 红点与改前**逐条相同**（16 条，无新增无消除）；`technology_content_binding_audit_test` PASS；`gameplay_start_runtime_test` 0 失败。
- 已知未做：`data/loading_catalog_v1/*.res` 仍未重烘（同上一条原因）；另一路两个未提交的诊断脚本 `tests/economy/food_fat_fallback_check_test.gd`、`food_fat_market_probe_test.gd` 其假设（畜产品当油）已被本次作废，其中后者断言「双变体方案存在」会红——这两个文件未跟踪，不进提交，处置权归其作者。

[返回专项记录总目录](feature-status.md#历史记录)
