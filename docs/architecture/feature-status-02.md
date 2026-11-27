# 整日交接、经济与移动端实测

## 50 倍速的每日交接（#55，2026-11-23）

改前以 `7ebdf9d20` 为基准。正式玩家场景的无画面探针走 `GameFlow.begin_new_game()`，由
正常时钟放行、后台结算和场景回收。输入准备另用带计时的临时原生构建测量，第 25–175 日
准备下一个气候输入的中位数为 0.141 ms，P95 为 0.159 ms。四国样本的连续区间里，后台
日结中位数为 9.63 ms，其中约 0.97 ms 用于发布一日的结果。逐帧记录未发现气候容量或
国家回执持续阻塞，后台主要在正常等时钟发放下一日。

前台每次发布天气画面时逐格编码风图。带独立输入副本的诊断记录显示，135 次天气更新中有
118 次的风向和风速与上次一致，编码仍花费中位 1.38 ms。天气表和云影原先各自编码。
跨日共用风图的试验使前台回收从 2.55 ms 降至 1.26 ms。同一批无画面对照中，帧间隔
P95 从 25.13 ms 升至 35.15 ms，区间内最长时钟等待的中位数从 27.77 ms 升至
36.20 ms。长帧出现时，前台回收多已接近零，后台每游戏日累计时钟等待约 10 ms。
在该缓存上继续省去重复上传，仍观测到 35.86 ms 的帧间隔 P95。

已撤回跨日风图缓存。#55 合入时只在图片尺寸和编码字节相同时复用已上传的风纹理，两个过渡
端点仍随每次天气发布推进。风图重新编码与天气表的布局转换沿用改前路径。

50× 使用四国、60×40、种子 `20260718`、高画质和固定的地图中心视角，复用同一个
macOS arm64 调试扩展。改前和当前方案交替运行三轮。每轮从第 25–75、85–135、146–175
结算日各取两侧都采到的首尾日期。首尾的观测日期须精确匹配，避免跨日取样把区间外的
长帧或等待算进来。下表为九个区间的中位数及范围。

| 无画面正式场景 | 改前 | 当前仅复用风纹理 |
| --- | ---: | ---: |
| 游戏日/秒 | 50.12（49.66–51.24） | 50.58（49.68–51.42） |
| 帧间隔 P95（ms） | 24.94（24.15–42.35） | 25.44（23.82–40.93） |
| 前台回收（ms，收到结果的帧） | 2.57（2.49–2.62） | 2.57（2.49–2.58） |
| 发布画面数据（ms，回收中的一步） | 1.97（1.93–2.00） | 1.97（1.93–2.00） |
| 观察到的时钟等待次数 | 33（17–37） | 32（15–38） |
| 最长时钟等待（ms，按帧观察） | 27.68（26.79–50.69） | 27.98（26.55–52.53） |
| 后台累计时钟等待（ms/游戏日） | 9.52（9.06–10.45） | 9.77（9.26–10.77） |

等待起止按帧采样，只统计观察到结束的等待。区间原始记录同时保留了后台实际累计等待时间，
以及每帧申请、放行、提交、回收、停推来源和故障码。当前方案的无画面 50× 指标范围
与改前重叠。Godot 在无可绘窗口时会对主循环安排休眠。这里的视口为 64×64。
[Godot 4.6.3 帧间休眠实现](https://github.com/godotengine/godot/blob/4.6.3-stable/core/os/os.cpp#L666)

真实窗口仍待验证。只等待两次绘制回调的最小项目遇到
`com.apple.hiservices-xpcservice` 连接错误，未收到绘制确认。从 macOS 应用启动入口打开时返回
`kLSNoExecutableErr`，桌面工具也拒绝访问 Godot。50× 和 1× 的实际绘制间隔 P95、
等待次数、最长等待和提速幅度均缺少窗口记录。

六次 50× 测试的第 1–180 日发布哈希和回执全部一致。自然剧情在结算第 20、80、141 日
等玩家，测试从正式玩家入口答复，分别在第 21、81、142 日生效。四国和补测的当前六国场景
都提交了第 161 日及后续日期，未复现显示日 162 停住。历史 `7ca1ca31a` 窗口在该处
缺待答状态和故障码，现有记录无法判定原因。1× 对照第 2–8 结算日为 1.001 → 1.000 天/秒，
无画面帧间隔 P95 为 35.54 → 34.16 ms。两侧都观测到 6 次正常日历等待，最长为
977.24 → 997.87 ms。第 1–8 日的发布哈希与回执一致。受控测试另外检查了暂停时仍能
答复、答复生效日和手动续算。

### 复现

使用 Godot 4.6.3 及同一个本地构建的调试扩展。将两个已导入的临时项目副本分别设为
`$baseline_copy` 和 `$current_copy`。两边使用同一份探针，将改前副本的
`weather_wind_source.gd` 换成 `7ebdf9d20` 里的版本。

```sh
python3 tools/perf/run_rendered_player_handoff.py "$baseline_copy" "$current_copy" \
  --output "$scratch/rendered"
```

命令在两种速度各交替运行三组，保留逐帧和逐日数据、运行命令及负载均值。所有样本都须
实际绘制、提交目标日并匹配同速度的逐日哈希与回执。每组要求实际显示设置一致，在双方均
观测到的结算日边界内汇报绘制间隔 P95、游戏循环间隔 P95、等待次数及最长等待。
两种速度验证通过后写出 `summary.json`。

单独复测一侧时使用以下命令。`$first` 和 `$last` 为同一对记录都观测到的结算日边界。

```sh
PK_SAVE_DIR="$sample.saves" PK_RUNTIME_WATERFALL_CSV="$sample.waterfall.csv" \
  godot --path "$project_copy" --log-file "$sample.engine.log" \
  --script res://tests/game/player_scene_handoff_probe.gd -- \
  --speed=50 --through=180 --answer-story --require-rendered --frames="$sample.jsonl"
python3 tools/perf/analyze_player_handoff.py --require-rendered \
  --window "$first" "$last" "$sample.jsonl"
```

1× 使用 `--speed=1 --through=8` 和 `--window 2 8`。六国用 `--foreign-count=5`。
无画面诊断在 Godot 命令加 `--headless`，探针和分析命令均省略 `--require-rendered`。
省略 `--answer-story` 时探针在第一个实际待答处退出并写出停推原因。开局请求被拒绝或
玩家场景准备失败会提前写入 `startup_failed` 和具体原因。探针固定 1600×960 窗口、高画质、
垂直同步和地图中心，并记录实际相机、显示设备和窗口设置。

复测原始记录保存在 `/private/tmp/keynes-55-review.Lbvhd1/`。`comparison` 是跨日缓存复测，
`texture-comparison` 是当前方案。每次运行的命令、退出状态和负载均值在 `trials.jsonl`，
逐帧状态和逐日结果分别在 `.jsonl` 和 `.jsonl.days`，后台分段耗时在 `.waterfall.csv`，
实际取样边界及汇总在 `summary-common.json`。此前的气候输入测量和风图取证保存在
`/private/tmp/keynes-55.PWON1L/` 的 `diagnostic-only.patch`、`diagnostic-prep.log` 和
`diagnostics-wind-exact.log`。
性能证据打包在 `/private/tmp/keynes-55-regression.LzwvOn/handoff-performance-evidence.tar.gz`，
本轮回归、压力和回放记录也保存在该目录。

在改前副本用 `--write-candidate` 保存两组确定性参考，再在改后运行以下检查。
`$golden_baseline` 和 `$external_baseline` 指向对应的参考文件。

```sh
python3 tools/ci/check_golden_determinism.py --runs 3 --log-dir "$checks/golden" \
  --compare-to "$golden_baseline"
python3 tools/ci/check_golden_determinism.py --runs 3 --external-only --log-dir "$checks/external" \
  --compare-to "$external_baseline"
python3 tools/ci/check_replay_matrix.py --annual --godot godot --log-dir "$checks/annual"
python3 tools/ci/check_runtime_load_consistency.py --workers 7 --log-dir "$checks/load"
python3 tools/ci/run_regression_checks.py --jobs 4 --roundtrip --log-dir "$checks/full"
python3 tools/ci/run_regression_checks.py --roundtrip --log-dir "$checks/regression" \
  tests/game/player_calendar_handoff_test.gd tests/world/weather_table_layout_test.gd \
  tests/game/narrative_popup_suppression_test.gd tests/game/narrative_event_runtime_test.gd
```

### 正确性验证

- `player_calendar_handoff_test.gd` 的 26 项覆盖一次放行多日、有序回收和单次回执、两次剧情
  待答、答复生效日、手动暂停及 1× 续算。七个压力进程并行时同样通过。
  `runtime_executor_boundary_test.gd` 的 319 项覆盖后台和同线程执行器之间的切换，包含停止、
  命令和存档边界。
- `weather_table_layout_test.gd` 的 96 项检查编码后字节相同的风纹理复用、风场变化后的
  过渡端点、同字节不同尺寸、无效输入恢复和换局。无画面运行跳过真实图形后端读回。
  `cell_lut_incremental_test.gd` 和 `cloud_weather_quality_test.gd` 通过。
- 旧探针只等待正式会话并检查宿主的 `FAULTED`。场景资源加载失败时 `GameFlow` 保留了
  原场景，宿主尚不存在。将场景请求指向脚本资源后，旧探针进入等待且没有写记录。当前探针
  在同一条件下写出 `player_scene_load_failed` 并以 1 退出。`player_scene_handoff_startup_test.gd`
  覆盖这条异步失败路径，检查原场景仍在、正式会话为空以及失败记录的原因码。
- `test_analyze_player_handoff.py` 的 9 项通过，覆盖首尾跳日拒绝、区间中途合并多日、绘制间隔
  边界、配对的实际画面设置和等待计数。用无画面 Godot 运行双速命令时，探针返回
  `rendered_backend_required`，对照命令以失败退出。开局配置、保存库和正式存档往返在临时用户目录通过。
- `check_golden_determinism.py --runs 3` 与 `--runs 3 --external-only` 全部匹配改前结果。
  `check_replay_matrix.py --annual` 比较了原跑、重放、第 365 日存档和新进程续跑至第 373 日。
- `check_runtime_load_consistency.py --workers 7` 在当前沙盒读取 `ps` 时受限。补测保留原来的
  压力进程、比较和断言，系统负载记录改用可读取的负载均值。两轮七进程压力各自与无额外
  压力的参考一致，覆盖正式 30 日状态、35 日命令日期和第 5 日存档后的续跑。
- 改前的 `narrative_popup_suppression_test.gd` 把暂停前的放行值 `2` 用在了答复后。
  改前取证显示答复已受理且第 3 天生效，时钟仍暂停，暂停接口已把放行值设为 `-1`。
  现在分别断言暂停前的 `2`、暂停后的 `-1` 和答复后的 `-1`。修正后剧情暂停 28 项、
  剧情运行 89 项和正式存档往返均通过。

### 工厂回归修复

- `cell_board_toolbar_transition_test.gd` 的 60 ms 计时器和 130 ms 退场可在同一个慢帧内结束，
  旧用例用 `godot --headless --fixed-fps 5 --path Project/project-keynes --script res://tests/ui/cell_board_toolbar_transition_test.gd`
  可复现中段断言失败。现在直接推进到一半，等待真实动画结束，并检查被打断的动画已取消。
- `runtime_loading_exit_test.gd` 在经济目录准备期间关闭世界，稳定复现
  `[economy] configure failed: loading_canceled`，调用栈从加载取消回到初始化入口。
  入口现在直接结束已取消的准备，实际配置失败仍会上报。新用例检查关闭发生在准备期间，
  世界资源已释放，同时由回归工具验证没有错误日志。
- 常规回归、回放矩阵、年度自动存档和完整存读档往返共 128 项通过。风图、日历交接和
  两个剧情用例另跑均通过。编辑器完成了导入扫描，当前沙盒仍报 ObjectDB 快照目录创建错误。
  回归使用已导入的临时项目副本。Qodo 本地 CLI 缺登录，当前改动需由工厂提交后评审。

## 移动低档大片地形慢帧复测（#54，2026-11-23）

在提交 `0fae578384cd1805945d10259f3f7bcf24e1409e` 上取得桌面移动渲染基线。
等画质优化、交替复测和真机验收继续由 [#54](https://github.com/hrhgit/Project.Keynes/issues/54) 跟踪。

### 采样条件和证据

解锁的 macOS 桌面，Apple M2、Godot 4.6.3、Metal Mobile 低档、60 Hz 显示器。
固定种子 20260718，60×40 格、四国、1 倍速，采样时暂停日期。两个场景均开启迷雾。
开局与大片已探索场景的采样日分别为 0 和 3。16 段的镜头中心和缩放一致。
窗口和植被均为 1600×960，迷雾为 800×480。100% 陆水为 1600×960，75% 为 1200×720，
少 43.75% 的陆水像素。引擎限帧读数为 0，垂直同步模式读数为 0，实际呈现仍接近 60 Hz。

[可移植采样数据](evidence/mobile-terrain-aqua-0fae5783.json) 保存采样版本、原生库校验值、
时间窗和进程号、观测计数、均值、中位数和 P95。来源为本机
`54-aqua-20261123-114851` 的 `captures.jsonl`、`environment-check.csv` 和八份 `*-timings.json`。
逐段核对了进程号、配置、时间窗、应用帧数、呈现请求数和等待事件数。原始系统跟踪保存在采集机。

- **应用间隔**是 Godot 绘制结束回调之间的时间。每段预热 60 帧，采 240 帧，共 3,840 帧。
  每段也有 240 个窗口绘制 CPU 样本，75% 另有 240 个陆水子视口 CPU 样本。100% 在窗口绘制陆水。
  这些计时由 Godot 的视口统计给出。实际绘制尺寸来自计时结束后的图像读回。
- **GPU 工作**按目标 Godot 进程的呈现请求找到对应的 Metal 帧，合并该帧相互重叠的活跃区间。
  统计包括采样窗口边界之后完成的已归属工作。每段 239–241 个不同的请求帧全部取得 GPU 计时，
  共 3,840 个。未映射请求及缺少活跃区间的请求帧均为 0。Godot 自带的 Metal GPU 计时为 0 个样本。
- **实际呈现间隔**来自目标进程带正间隔的已呈现回调。每段 238–240 个间隔，共 3,835 个。
  所有段的 P95 约 16.67 ms。呈现请求、应用间隔和已呈现回调各自按观测计数。
- **等待 drawable**按进程记录每条取得可绘制缓冲前的等待事件。每段 230–240 条，共 3,788 条。
  缺少事件的帧没有填入零，事件也未逐帧配对。等待可能与其他帧的 GPU 工作重叠，两个计时不能相加。

### 实测结果

每行各采一次，时间均为 ms。等待列的样本单位是事件，GPU 列的样本单位是提交帧。
应用 P95 的样本单位是绘制结束回调间隔。呈现数只含带有效间隔的已呈现回调。

| 场景 | 陆水比例 | 省略层 | 应用 FPS / P95 | 窗口 / 陆水视口 CPU 均值 | GPU 均值 / 帧数 | 等待均值 / 事件数 | 呈现间隔数 |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 开局 | 100% | 无 | 59.00 / 18.66 | 0.465 / — | 10.077 / 241 | 9.829 / 232 | 238 |
| 开局 | 100% | 陆地 | 60.01 / 19.94 | 0.498 / — | 9.055 / 240 | 9.384 / 239 | 240 |
| 开局 | 100% | 水面 | 60.00 / 17.88 | 0.495 / — | 9.491 / 240 | 9.781 / 240 | 240 |
| 开局 | 100% | 植被 | 58.28 / 17.92 | 0.413 / — | 9.947 / 239 | 10.446 / 237 | 238 |
| 开局 | 75% | 无 | 59.01 / 19.54 | 0.457 / 0.054 | 7.937 / 240 | 9.593 / 239 | 240 |
| 开局 | 75% | 陆地 | 58.86 / 19.29 | 0.429 / 0.047 | 9.813 / 241 | 9.454 / 230 | 240 |
| 开局 | 75% | 水面 | 58.29 / 23.63 | 0.431 / 0.047 | 8.082 / 240 | 9.400 / 237 | 240 |
| 开局 | 75% | 植被 | 60.09 / 18.31 | 0.412 / 0.051 | 9.872 / 239 | 9.433 / 240 | 240 |
| 大片已探索 | 100% | 无 | 60.01 / 18.17 | 0.481 / — | 9.617 / 240 | 10.167 / 240 | 240 |
| 大片已探索 | 100% | 陆地 | 59.27 / 17.91 | 0.509 / — | 9.765 / 240 | 10.065 / 231 | 240 |
| 大片已探索 | 100% | 水面 | 59.99 / 18.22 | 0.497 / — | 8.797 / 240 | 9.701 / 239 | 240 |
| 大片已探索 | 100% | 植被 | 56.06 / 18.84 | 0.392 / — | 9.328 / 239 | 9.158 / 230 | 239 |
| 大片已探索 | 75% | 无 | 60.03 / 18.02 | 0.470 / 0.048 | 9.384 / 240 | 9.805 / 240 | 240 |
| 大片已探索 | 75% | 陆地 | 60.00 / 17.49 | 0.458 / 0.044 | 10.711 / 240 | 10.071 / 240 | 240 |
| 大片已探索 | 75% | 水面 | 60.01 / 21.45 | 0.481 / 0.088 | 9.118 / 240 | 9.432 / 238 | 240 |
| 大片已探索 | 75% | 植被 | 59.96 / 19.59 | 0.356 / 0.051 | 8.073 / 241 | 9.636 / 236 | 240 |

同场景、同尺寸下用完整绘制均值减去省略组均值。下表每格为 CPU / GPU 差值，单位 ms。
GPU 是目标进程整帧的差值，CPU 取对应图层所在视口。负数表示该次省略组更慢。
省略植被包括散布植被、投影、资源植物批次和共享地被。各组仍运行图层更新和迷雾。

| 场景 | 陆水比例 | 陆地 | 水面 | 植被 |
| --- | ---: | ---: | ---: | ---: |
| 开局 | 100% | −0.033 / +1.022 | −0.030 / +0.586 | +0.053 / +0.130 |
| 开局 | 75% | +0.007 / −1.876 | +0.007 / −0.145 | +0.045 / −1.935 |
| 大片已探索 | 100% | −0.029 / −0.148 | −0.016 / +0.820 | +0.088 / +0.289 |
| 大片已探索 | 75% | +0.004 / −1.327 | −0.041 / +0.266 | +0.114 / +1.311 |

完整绘制从 100% 切到 75%，开局 GPU 均值少 2.140 ms，应用 P95 从 18.66 ms 到 19.54 ms。
大片已探索时 GPU 均值少 0.233 ms，应用 P95 从 18.17 ms 到 18.02 ms。实际呈现 P95 均约 16.67 ms。
大片已探索时省略植被和水面的 GPU 均值在两个比例均下降，75% 时省略植被的差值最大。
省略陆地的两组探索样本 GPU 均值更高。开局三个省略组的 GPU 差值均随比例改变方向。
各配置只运行一轮，依次采 100% 和 75%，
期间同机还有其他工厂检查。这组数据可用来选择复测对象，尚无法确定稳定的分层代价或慢帧主因。

覆盖为一台桌面 Mac、固定镜头、移动渲染器低档。手机和平移缩放尚未采样。
关雾单独用于诊断。旧六国关雾日志在 100% 和 75% 分别有 721 和 720 个应用间隔样本，
P95 为 19.70 和 19.74 ms。等画质前后对照与画面一致性验收仍由 #54 跟踪。

### 退出和已有回归

大片已探索的完整绘制进程 6630 完成两段采样及 36 项游戏内检查后退出时收到 SIGBUS。
`explored-full-shutdown.json` 的堆栈从 `Main::cleanup` 经脚本字典、字体与 `TextLine` 释放进入
`TextServerAdvanced::_free_rid`。该退出失败独立记录，两个时间窗均结束于故障之前。
[Godot 4.6.3 的清理顺序](https://github.com/godotengine/godot/blob/4.6.3-stable/main/main.cpp#L4739-L4790)。

退出探针复用了正式玩家场景。改前关闭世界并释放场景后，界面缓存仍持有两份已排版字体，两个释放断言均失败。
基准现于场景释放后、Godot 开始清理文字服务前释放字体缓存。改后开局和探索探针分别通过 28 和 39 项，
进程退出码均为 0。带窗口的清理复测仍需解锁的桌面。

```sh
godot --headless --path Project/project-keynes \
  --script res://tests/rendering/mobile_terrain_baseline_test.gd -- --check-exit --explored
```

原汇总只检查跟踪样本数大于零。把 75% 植被省略组的三项跟踪压到各一条，原工具仍接受，
并从完整组 8 ms 与省略组 1 ms 算出 7 ms 的 GPU 差值。新版汇总核对时窗来源和实际请求、
唯一帧、GPU 样本的数量。应用必须记录 240 帧，呈现请求允许时窗边界相差一帧，
每个请求必须映射到不同的帧且有 GPU 活动。实际呈现间隔独立核对覆盖，允许 238–241 个。
等待事件保留各自的分布和数量，不用于计算逐层差值。

```sh
python3 tools/perf/report_mobile_terrain_baseline.py --evidence docs/architecture/evidence/mobile-terrain-aqua-0fae5783.json > breakdown.json
python3 -m unittest discover -s tools/perf -p test_report_mobile_terrain_baseline.py
```

重新采样时，每场景运行完整绘制及分别省略陆地、水面和植被的四组命令。探索场景加 `--explored`，
省略组加其中一个 `--omit-land`、`--omit-water`、`--omit-vegetation`，关雾诊断单独用 `--fog-off`。

```sh
PK_MOBILE_SHADER_TIER=MOBILE_QUALITY_LOW godot --path Project/project-keynes --resolution 1600x960 \
  --rendering-method mobile --rendering-driver metal --disable-vsync \
  --script res://tests/rendering/mobile_terrain_baseline_test.gd -- --measure --explored
```

使用 Instruments 的 Game Performance 模板。按 Godot 进程号及每段的 `[start_unix_s, end_unix_s)`
筛出呈现请求、等待事件和已呈现回调。GPU 计时用 `ca-client-present-request` 的命令缓冲，
经 `metal-command-buffer-frame-assignment` 找到帧，再按帧合并 `metal-gpu-intervals` 的活跃区间。
等待来自 `ca-client-buffer-wait-interval`，实际呈现间隔来自 `ca-client-presented-handler`。
用 `--trace-summaries trace-summaries.json captures/*.log` 可直接配对
记录场景、比例、图层、时间窗、帧覆盖计数及三项计时的进程筛选后导出。字段见可移植采样数据。
[Apple 的 Metal 跟踪说明](https://developer.apple.com/videos/play/wwdc2020/10603/)。

原有无窗口场景检查覆盖开局 66 格可见、大片已探索 1248 格且 366 格已探索陆地仍被迷雾遮挡、
以及单列的关雾 2400 格可见。检查同时覆盖单次只省略一层、植被批次及地图接缝副本、画质和尺寸配置。
[场景测试](../../Project/project-keynes/tests/rendering/mobile_terrain_baseline_test.gd)。

- 工具栏回归先前用 60 ms 定时器判断退场中段，固定 200 ms 一帧时动画已经结束。现在推进到动画中点，
  并等待实际完成信号。正常时序和固定 200 ms 一帧均通过。
  [工具栏回归](../../Project/project-keynes/tests/ui/cell_board_toolbar_transition_test.gd)。
- 加载退出回归先前把经济目录准备期间的取消报为配置失败。国家开局准备现按当前请求的取消状态结束配置。
  改后 20 项通过，覆盖目录和世界的释放。
  [加载退出回归](../../Project/project-keynes/tests/runtime/runtime_loading_exit_test.gd)。

采样版本先前通过 128 项运行回归，含逐日回放和存读档。本次修订通过 18 项架构检查、201 项工厂测试、
11 项汇总测试和开局、探索、关雾三组无窗口检查。远端同步受域名解析阻塞，Qodo 身份检查返回未登录。

## 稀疏经济需求缓存（#53，2026-11-23）

改前以本地 `fork/master` 的 `6ce469e952a2466ad1e4bab42984158861125037` 为基准，
与本地上游 `master` 记录的源码树一致。配置、开日和缺项补建都按全图放大两列需求变体
与三列需求。当前目录有 687 个变体和 181 项需求，每格结果需要 15,336 字节。
两种正式四国地图在开局时都有 0 格已写，之后 55 个提交日每天都实际写入 4 格。
改后开局无需求缓存分配，结算时使用 4 行，格号索引随地图大小增长。

下表为各尺寸改前、改后交替三轮。内存取第 55 日提交后的经济报告，三次内存读数
相同。结算日/秒取中位数，括号中为最小值和最大值。

| 地图 | 保留行数，改前 → 改后 | 五类结果 MiB，改前 → 改后 | 经济总内存 MiB，改前 → 改后 | 结算日/秒，改前 → 改后 |
|---|---:|---:|---:|---:|
| 60×40 | 2400 → 4 | 35.1013 → 0.0585 | 75.4007 → 40.3488 | 33.12（33.03–33.23）→ 33.23（32.81–33.28） |
| 100×64 | 6400 → 4 | 93.6035 → 0.0585 | 207.0407 → 113.4713 | 15.57（15.50–15.57）→ 16.03（15.56–16.29） |

100×64 的索引容量从 51,200 字节降至 25,632 字节，经济总内存少 93.57 MiB（45.2%）。
该图开局经济内存从 167.09 MiB 降至 73.44 MiB，60×40 从 60.13 MiB 降至 25.01 MiB。
各版各尺寸均有 50 条实测记录，三账误差为 0，无经济故障。结算速度范围有重叠。
录制器的 50 日/秒检查在这些逐日等待样本中均为未达标，退出码为 9。

构建和测速使用仓库外独立副本，macOS arm64、Apple Clang 21.0.0、
Godot `4.6.3.stable.official.7d41c59c4`，测速加载 `template_debug` 扩展。
调试库的 SHA-256 改前为 `23e2b957938d945f8f3b49b913d51e96d429880f3690213e7512275f74183ab8`，
改后为 `0135b26ffac6a23b8bbdac0bfca825edd4459e5af1398e77313b49e4dc8fd31d`。
改前副本只加了六列容量和日期戳计数，同一录制探针用于两版。工具默认的流水模式
在首轮 60×40 仅录出 31 行，正式对照用自带的逐日等待模式，保留 5 天预热和 50 天实测。
临时 Godot 配置为测试进程提供独立用户数据和可读的本机证书文件。

```bash
scons -C gdext platform=macos target=template_debug arch=arm64 dev_build=no -j8
scons -C gdext platform=macos target=template_release arch=arm64 dev_build=no -j8
godot --headless --path Project/project-keynes --script res://tests/game/headless_perf_record.gd -- \
  seed=20260718 foreign_count=3 warmup_days=5 days=50 speed=50 pipeline_depth=0 \
  width=60 height=40 output_dir="$issue53_run_dir"
# 同样参数再跑 width=100 height=64，使用新的输出目录。
```

两张正式地图各 55 天的完整经济摘要和八个域的提交摘要逐日一致。
`economy_sparse_workset_parity_test.gd` 在 6400 格地图检查开局空间和两处远距聚落的
实际行。`economy_cadence_runtime_test.gd` 检查换日、建筑与家庭市场重合、多个任务的
首次写入与串行一致、同日读档、失败回滚及重新开局。原生用例经
`runtime_authority_m5_m6_gate_test.gd` 检查未登记格、就业后刷新、跨日重用和容量上限。

主场景与表外场景均通过三次对照，七个指令场景共 21 次对照通过。
第 27 日存档的 40 日检查和第 365 日自动存档检查各有四条一致轨迹。
额外用改后库读入改前库写出的存档，
第 28 至 40 日逐日一致。ECP2 ABI 4、schema 63 和内部 PKEC 65 沿用原格式。
改后的 debug 和 release 扩展分别通过 10 项指定库探针，release SHA-256 为
`21b7618ddab2e91af9d6f53a0a84096ab39813ae1b1cf8a27a30ec479d235605`。
默认回归、续跑矩阵、自动存档和整档往返共 128 项通过。额外的 6400 格缓存用例、
理念标签压力用例（43 项检查）及随同运行的整档往返也通过。

改前先为主场景、表外场景和七个指令场景分别用 `--runs 3 --write-candidate` 取数。
改后使用这些仓库外的文件。以下命令在对应副本执行，`$issue53_logs` 下每个检查用新目录。

```bash
python3 tools/ci/check_golden_determinism.py --godot "$issue53_godot" --runs 3 \
  --log-dir "$issue53_logs/golden-after" --compare-to "$issue53_root/golden-before.json"
python3 tools/ci/check_golden_determinism.py --godot "$issue53_godot" --runs 3 --external-only \
  --log-dir "$issue53_logs/external-after" --compare-to "$issue53_root/external-before.json"
python3 tools/ci/check_intent_baselines.py --godot "$issue53_godot" --runs 3 \
  --log-dir "$issue53_logs/intents-after" --compare-to "$issue53_root/intents-before.json"
python3 tools/ci/run_regression_checks.py --godot "$issue53_godot" --roundtrip \
  --log-dir "$issue53_logs/focused-final" tests/ideology/ideology_tag_snapshot_stress_test.gd \
  tests/economy/economy_sparse_workset_parity_test.gd
python3 tools/ci/run_regression_checks.py --godot "$issue53_godot" --roundtrip --jobs 3 \
  --log-dir "$issue53_logs/default-after"
python3 tools/ci/check_committed_replay.py --godot "$issue53_godot" --checkpoint --trace \
  --year-days 365 --save-day 27 --days 40 --log-dir "$issue53_logs/checkpoint-after"
python3 tools/ci/check_replay_matrix.py --godot "$issue53_godot" --annual \
  --log-dir "$issue53_logs/annual-after"
python3 tools/ci/check_macos_runtime_extension.py --godot "$issue53_godot" \
  --library "$issue53_lib" --log-dir "$issue53_native_logs"
```

原始 CSV、报告、构建记录与临时取数补丁保存在 `/private/tmp/keynes-issue53.Ja2pDy`。
本轮覆盖 macOS arm64。编辑器导入在沙箱中报 ObjectDB 快照目录错误，回归使用已导入
的资源。远端 GitHub 无法连通，Qodo CLI 回报 `not_logged_in`，工厂提交后的审查待完成。

## 上游同步后的行为回归与退役代码清理（2026-11-24）

- 以上游 `003a6e47c` 为基础。保留上游科技与时代门槛、水域通行、灾害、派遣和存档精简。
  恢复看板同日发布、库存刻度与窄窗避让，以及年报、调税、军务与理念的正式交接。
  GM 的剧情默认选择和年报提示由后台按生效日处理。生效值与待生效命令随存档保存。
- 清理正式项目已退役的开发场景、气候开关、前台剧情和动荡执行脚本及对应的旧分工测试。
  军费地表更新断言迁入原生自检。气候日历、理念读档和经济后台重启通过现行入口覆盖。
  独立性能验证项目继续使用自身入口。
- 用同一套内容生成 CLM2 v9、带内嵌 ECP1 和 ECP2 的旧布局样本，经正式入口成功加载并从第 4 天推进到第 5 天。
  另一份不同规则目录的旧样本在原上游和修复分支上都以规则目录不匹配拒绝。
  缺失存档、原槽重试与返回菜单通过。确认段截断时，正式读档返回该段的明确错误。
- 科技目录和科研运行专项通过。补齐七条路线的中文显示，并逐时代核对实际里程碑门槛与候选。
  产业审查比原上游少一项重复建筑，剩余 31 项相同。图结构与资源绑定审查复现现有目录差异。
- macOS arm64 原生编译和静态检查通过。最终完整回归 150 项通过，含 365 天年度验证、年报自动存档、
  逐日回放矩阵及正式存读档。标准和表外场景各重复三轮，逐日结果一致。
- macOS 独立跑军务速度探针时，小场景上游与此分支均低于 0.5 ms。大场景 p95 分别为
  6.11 ms 和 7.60 ms，均超过 2 ms。功能自检通过。计时路径沿用上游实现。
- Web 首访、已有组件、安装失败、仅刷新一次及补丁重复执行在 Godot 4.6.3 HTML 模板夹具中验证。
  该验证未运行实际 Web 导出包或部署。

## 地块悬停物资与阶层展板放大（2026-11-21）

- 同日第二次调整：按高分辨率截图反馈，宽度继续从 420 增至 520，正文和数字 14 → 18px，
  表头 12 → 16px、次级读数 13 → 16px，行内图标 20 → 24px；同步扩大数值列和比例条。
  五阶层与三阶层高度阈值更新为 650 / 510。全量编辑器编译无脚本错误，展板测试通过，
  四档带渲染截图检查通过，人工复核 1280×720 与 2560×1080 截图。
  下列记录为第一次调整时的尺寸与验证。

- 展板宽度 340 → 420，正文与数值 12 → 14px，次级读数 11 → 13px；同步放大图标、
  数值列宽和行高。展板贴 HUD 左边缘，可覆盖左侧图例工具栏，仍避开顶部和底部 HUD。
- 保留高度压缩，完整五阶层需 600 可用高度，三阶层需 460；低于该高度只显示物资。
- 验证：全项目 headless editor 编译无脚本错误，`cell_board_test.gd` 与
  `cell_hover_card_test.gd` 通过；渲染探针在 1600×900、1280×720、2560×1080、720×480
  通过宽度、底部边界和左侧定位检查，人工复核前两档截图，产物位于
  `Project/project-keynes/tmp/cell_board_qa/`。
- 验证限制：截图使用固定 QA 数据，没有运行正式世界的快进；退出日志仍有 FMOD debugger
  注册与资源清理提示。UI 反模式扫描已运行并结合本次新增行人工复核，没有新增玩家文案。
- 扩展检查 `ui_scene_structure_test.gd` 有 12 项失败：2 项来自本次未修改的
  `cell_hover_card.gd` 动态节点构造，10 项来自 `touch_number_pad.gd` 动态节点构造；
  本次展板与布局文件没有失败项，未改动上述其他工作区文件。

## 地块悬停物种图标（2026-11-21）

资源条下增加物种图标和短名称；数据复用地理档案的占据位与玩家科技识别过滤。
20 个 `bio.*` 键接入既有纸贴图标；部分动物共用动物位图，通过名称区分。
无物种时恢复基础卡片高度；有物种时随内容增高，并使用实际尺寸执行屏幕边缘与展板避让。
紧凑调整：取消三等分列，改为自然宽度流式排列，图标由 24px 缩至 20px，物种行由 28px
收至 20px；地形与人口行合计减少 8px 留白。三种物种的卡片从 212px 降至 196px。
四种分辨率的渲染探针与 50 次刷新复核通过，截图更新为卡片特写。
紧凑调整后的悬停组件测试通过；本轮全项目编译检查发现并行改动中的
`annual_report_view_model.gd:265` 缺少 `money_text()` / `count_text()`，年报依赖链未通过编译。
未修改该文件；本次悬停组件的渲染与测试不受该依赖链影响。

验证：全项目编辑器导入无脚本编译错误，`tests/ui/cell_hover_card_test.gd` 与
`tests/ui/cell_hover_view_model_test.gd` 通过。临时渲染探针 `tmp/species_hover_probe.gd`
覆盖 1280×720、1920×1080、2520×1080、720×1280 的实际截图与图标槽边界、50 次刷新节点复用、
空集合恢复尺寸、空科技集隐藏、完整科技集识别、占据清零和语义图标解析。截图在工程
`tmp/species_hover_*.png`。本次截图是组件探针，未覆盖正式场景鼠标悬停与实际时钟快进。
UI 反模式扫描输出在仓库 `tmp/species_ui_audit`，新增行人工复核未引入占位文案或模拟术语。
数据层测试退出仍报告对象/资源未释放；渲染探针有 FMOD 调试器消息与退出注销诊断，断言通过。


## 军事面板两处数据通路缺陷（2026-11-20）

玩家报「完全无法招兵」，并附国库页「军事：暂不可用 / 军事账目尚未就绪」的截图。用玩家存档
（`user://saves/autosave.pksv`，day 6570）解出 PKMI 段核对：6 个国家的 `target_value` 全为 0、
命令队列 `pending` 为空、`last_day` 等于存档日、lot 段为空表、唯一的 cell_state 是 cell 1842
（2 座 tier1 兵营 → 兵额 8、`quota=0`、`pending_enlist=0`），30 日维护实付 799。军事日一直在跑，
招不到兵的原因是**招募目标恒为 0**：`plan = min(effective_target − soldiers, open_sum)` 因此为 0，
配额冻在 0，一条 ENLIST/LEVY 都不发。

四处改动：

1. `military_workspace.gd` 的目标滑条原来只在 `drag_ended` 提交，键盘/点击轨道/无障碍调整没有提交
   入口，而 200ms 的刷新会用原生旧值把把手写回去。现在 `value_changed` 走 250ms 防抖提交、
   `drag_ended` 仍然松手即提交；提交值在快照追上之前由 `_target_pending_mode/_value` 覆盖，
   不再回弹；重复值不重复发，点当前模式不再发「value = 滑条当前值」。
2. 同文件的「人数 / 预算」两个模式签漏了 `IconButton.apply_with_text()` 的 `toggle=true`。该助手会
   无条件写 `button.toggle_mode`，于是两个签退化成普通按钮：`button_pressed` 恒 false、
   `set_pressed_no_signal(false)` 被 `!toggle_mode && !pressed` 早退挡掉（两个签会同时显示按下）。
   后果是「预算」模式进不去，`_commit_target()` 一律按人数模式提交，货币值被当成兵数。
3. 国库页的军费板块读 `model["military"]`，但经济章的 `CountryViewModel.build("economy")` 从不装配
   这一段，板块因此永远「暂不可用」。新增 `build_military_spending_model()`，只取国家槽快照 +
   实物维护两项读数，产出与 `military_spending_model` 同键的段，`build()` 与 `_build_full_legacy()`
   都接上。
4. `PlayerController.SUPPORTED_COMMANDS` 缺 `COMMAND_MILITARY_BUDGET`，军事预算信封的四个滑条
   提交会一律 `unsupported_command`。已补白名单，并在 `PlayerCommandValidation` 加份额范围校验。

验证：`tests/ui/military_target_commit_test.gd`、`tests/ui/fiscal_military_model_test.gd`（新增）
与 `tests/ui/fiscal_military_block_test.gd`、`tests/ui/military_config_command_test.gd` 全 0 失败；
`tests/game/player_country_ui_smoke_test.gd` 0 失败，新增三条断言（经济章模型带 `military` 段、
段内带信封通道、有 facade 时 `available=true`）。

未覆盖：目标命令仍是 D+1 落库；滑条量程（50000 人 / 50000 货币）是 UI 常量，原生只校验非负；
`budget_*` 三个份额仍不进 PKMI，读档后靠 `_repush_military_budget()` 重推。

同日接上地块名的数据源。`MilitaryViewModel.cell_name()` 读的 `cell_names` 以前只有测试夹具会填，
生产环境没有装配者，于是兵营行、训练行与割地表一律写「未命名地块」。现在
`CountryViewModel.build_military_model()` 把 Economy 的具名聚落表装进军事段
（`named_settlement_snapshot()` 首读、`settlement_delta(revision)` 增量更新，按 revision 缓存；
读视图排队或旧 DLL 时保留上一份），`MilitaryViewModel` 按**具名聚落 > 作者地区名 > `地块 N`**
降级，`settlement_name()` 单独暴露聚落名供割地表判断「这一格有没有自己的名字」（不能拿
`cell_name()` 判断，它已经会退回地区名）。夹具的顶层 `cell_names` 仍然认。
实机验证：`player_country_ui_smoke_test` 在真实世界里读到 6 条具名聚落，军事面板的名表已装配。
注意 `build_military_model` 有两处出口——不可用时的早退和通过快照检查后**重新赋值**的 section；
名字表两处都要带（第一版只写在开头的字面量里，可用状态下整份丢掉，测试第 6 段专门钉它）。
新增 `tests/ui/military_cell_names_test.gd`（24 条断言：`name_active` 过滤、增量、整表替换、
读失败保留、三级降级、割地表判定、夹具兼容、可用主路径）；`player_country_ui_smoke_test` 另加
一条「不再出现未命名占位」的实机断言。

同日按维护者意见收敛文案：命令受理反馈统一为「命令已下达」（`player_controller/military.gd`，
`game_ui_manager` 的编成回执同步）；国库页军事栏去掉说明行、组标签
（`独立信封 · 军饷 / 维护 / 装备给养`）与「招募本身不拨款…」「未启用时按现金结算…」
「每日信封 A：军饷 B…」三类整句，信封行只写 `未启用` / `每日 X`；通道脚注只留
`超支 X` / `待购 N 件` / `暂停` 这类带数字的状态字。共同额度池那一侧的组标签与说明未动。
对应的「无说明句」断言写进了 `tests/ui/fiscal_military_block_test.gd`（军事分区首行必须为空、
脚注不得以句号收尾）与 `tests/ui/military_target_commit_test.gd`（状态行等于「命令已下达」）。

## 存档体积构成与 Inspect-SaveSize（2026-11-20）

实测 day 628、100×64（6400 格）的 `manual_1.pksv` 为 9.96 MiB（10,445,950 B），未压缩载荷 151.3 MiB，
zstd 压缩比 0.066。按"该块单独 zstd -3 后占文件多少"拆解：365 天逐格温度历史 5.53 MiB（55.5%）、
ECP2 经济快照两份各 1.12 MiB（22.6%，PKSR bundle 内一份 + 容器 `ecp2` 段一份，实测逐字节相同）、
`preview` 全窗 PNG 0.86 MiB（8.6%）、ECP1 0.30 MiB（3.0%，恢复路径明确跳过）、`dynamic_world` 0.30 MiB、
`environment` 0.10 MiB，其余 14 段合计不足 0.2 MiB。

体积主因是 `RuntimeClimateAuthority::serialize` 无条件写 `_store.temperature_history`（`cells × 365 × f32`）。
该 lane 只被滚动写入与 `state_hash` 使用，`runtime_climate_parity.h` 把它归为 worker bookkeeping，
玩法读的是另一条 `temperature_365d_ema`；而它的压缩率只有 0.59，因此体积随格数线性抬升：
6400 格是 8.91 MiB 原始 / 5.53 MiB 落盘。体积与天数不成正比（day 10838 的 `manual_2` 只有 7.42 MiB，
day 24 的 `manual_3` 只有 1.03 MiB），决定项是格数 × 历史填充度。ECP1 每次保存都编码，
但 `NativeSimulationHost` 启动时的注释与分支已写明 ECP1 不是权威恢复路径。

新增 `tools/runtime/Inspect-SaveSize.ps1`：浅层只读 PKSV 头，报 provider manifest 与各段压缩/原始体积；
`-Deep` 解出 PKSR 并拆到内段（含 CLM2 历史 lane、ECP1/ECP2 与重名段检测），`-Verify` 复核每段 sha256，
`-Json` 输出机器可读报告。四档实测通过：`manual_1`（CLM2 ABI 9）与 `manual_2`（ABI 8）都能定位历史 lane，
旧标记 `IDP1` 不再中断内段遍历，`-Verify` 21 段全通过；`-Deep` 单档耗时约 1.4 s。

已按上表四项实施（旧档读取路径保留）：

- **CLM2 v10 去历史环**：`RuntimeClimateAuthority::serialize` 不再写 `temperature_history`；
  `RuntimeClimateStore::state_hash()` 用同一份冻结字段表但不混历史，旧算法以 `state_hash_abi8()` 冻结，
  restore 按 ABI 分支（v9 读完整 lane 并用 `state_hash_abi8` 复核，v10 补零环跳过该 lane）。
  `CLIMATE_SECTION_ABI_MIN_SUPPORTED` 仍是 9，迁移自检保留并新增“ABI 9 必须仍可读”的断言。
  历史环仍留在内存里（kernel 每天照常追加），本轮只停止持久化与哈希，未动逐日写入路径。
- **ECP2 单份**：`build_save_bundle` 仍捕获一次（poll 要把它交给容器 `ecp2` 段），但不再写进 PKSR、
  不再置 `RUNTIME_SAVE_SECTION_ECONOMY_ECP2`；解析侧在该位缺失时改用 `restore_bundle` 传入的外部
  section（先做 marker 与 `decode_ecp2` 校验），带内嵌副本的旧 bundle 仍走原分支。
- **ECP1 停写**：移除 `encode_ecp1` 调用，`RUNTIME_SAVE_SECTION_ECONOMY_POD` 不再置位；解析端旧分支保留。
- **缩略图**：新增 `scripts/game/save_preview_codec.gd`（480 px 宽、JPEG q0.82，按 magic 嗅探 PNG/JPEG/WebP），
  `player_state.gd` 与 `main_menu.gd` 改用它；headless 仍写 1×1 PNG 兜底。

实测（同一测试夹具、40×28 / 1120 格）：旧格式 0.57 MiB → 新格式 0.35 MiB（−39%）。`-Deep` 对比：
旧档 365 天历史 1.56 MiB、ECP1 4.34 MiB、容器与内嵌 ECP2 各 8.92 MiB；新档三项全部消失，
`ecp2` 只剩容器一份。6400 格按同比例预计 9.96 → 约 2.2 MiB。

验证：`runtime_climate_authority_test` 通过（含 ABI 9 可读、历史逐字节保留、当前哈希一致，以及 ABI 8 及更旧仍以
`expected_10_got_N` 明确拒绝）；`runtime_inline_save_restore_test` 116 项 0 失败；
`game_save_roundtrip_test`（`PK_GAME_SAVE_ROUNDTRIP_TEST=1` + 独立 `PK_SAVE_DIR`）0 失败，恢复后跑完整经济结算周期、
日志中 `population_error=0`、`money_error=0`；新增 `tests/game/save_preview_codec_test.gd` 10 项 0 失败；
新增 `tests/game/legacy_save_continuation_test.gd`（旧布局存档与当前布局存档各跑一次，均 0 失败，
见下）；
`check_save_contracts.py` 与 `check_save_section_contracts.py` 0 违规；debug/release 扩展均构建通过；
60 天无头 soak 60/60 天提交、0 ledger 失败。

未覆盖 / 已知问题：`Invoke-SaveReplay` 的"冷启动直接装载存档"路径在本树上失效——它跑起来的世界
从第 5 日重新开始、`eco_day=-1`，`_wait_for_runtime` 等不到 `PlayerGame` 成为 `current_scene`，
因此对**当前格式**存档同样报 `runtime_never_became_ready`（提交前后各复现一次）。该入口不能用来
验证旧档，需要单独修；修之前不要用它当读档回归。

旧档兼容改用新夹具 `tests/game/legacy_save_continuation_test.gd`：先正常开局，再在会话内换入
`PK_SAVE_DIR` 里暂存的存档（`PK_LEGACY_SAVE_CONTINUITY=1`，槽位 `PK_LEGACY_SAVE_SLOT`，默认 autosave），
走与玩家"继续游戏"相同的 provider 恢复路径。用 23:15 之前的 debug 扩展写出的旧布局存档
（`-Deep` 已确认：CLM2 ABI 9 + 1.56 MiB 历史环、ECP1 4.34 MiB、容器与内嵌 ECP2 各 8.92 MiB）
实测 0 失败：`PKCN restored` / `PKCN and PKEC restored`、恢复后未 FAULTED、经济随存档恢复、
逐日推进 731→732；同一夹具对当前格式存档同样 0 失败（恢复第 2 日、推进 5→6）。
坑：恢复 finalize 会在世界变 live 之后重新套用存档里的暂停态，夹具必须逐帧重申时钟状态，
否则会把"恢复后暂停"误判成"恢复后不再推进"。

2 年/10 年 soak 与逐日一致性对比本轮未跑；soak CSV 不含人口/货币/货品守恒列，
守恒证据来自 roundtrip 日志（`population_error=0`、`money_error=0`）而非 soak。

## 早期时代夜间火光（2026-11-20）

玩家反馈石器、农耕聚落入夜后几乎全黑，要求加强早期时代的夜间照明。根因是夜灯只有窗光一条通道：
`building_compound.gdshader` 的窗格从 `era >= 1.5`（王国时代）才开，早期聚落只剩环境光与月光；
石圈广场的篝火核心半径 0.18 世界单位、亮度上限 1.0，实测被同格地物 decal 以 0.4 alpha 盖住，
夜间只剩一个几乎看不见的暗点。

改法全部在 shader，不改实例 buffer、调度、存档和物理：

- Body 新增 `BUILDING_HEARTH_*` 一组常量。早期无窗民居每面墙给一个暖色门洞，门洞缩到亚像素以下
  时退化成整条基座暖带；墙面按 `wall_t/he` 高度加火光反弹，屋面加一层基础火光加檐口更强的暖带，
  不再出现纯黑体块。约 78% 的民居取 `hearth_lit`，其余只留半档，避免整村均匀发亮像雾；
  `BF_MOUND`、`BM_HAY`（草堆、坟丘）照旧不发光。
- 早期地面光晕从 `level 0.22 / falloff 2.6` 改为 `BUILDING_EARLY_HALO_LEVEL 0.5 / FALLOFF 2.4`
  （大衰减系数让它更紧，不是一团雾），并按 `hearth_lit` 抖动。
- 广场篝火（`building_ground_decal.gdshader`）改成亮核加铺装光池，核心半径 0.18→0.34、加
  `exp(-r*1.9)*0.65` 光池与 7 Hz 闪烁，白天保留 0.30 底值（火堆白天可见）。
- 远景字形（`building_macro.gdshader`）给早期时代补门洞暖点与地面暖核，避免远视角早期聚落变黑块。
- 火光随时代按 `BUILDING_EARLY_FADE_START 1.5 / END 5.0` 淡出，启蒙时代以后回到原来的窗光；
  窗光同时对王国、古典两代加 `×(1+0.35*early)` 的增益。

验证：`tests/world/terrain_gi_test.gd` PASS（body/decal/macro 的 legacy 与 tiled 变体都能编译）。
四套建筑视觉测试全过（layer 31 项、catalog、intel 21 项、native bridge 34 项）。用生产建筑层
（`BuildingVisualLayer` + 原生规划器）在同一镜头拍改前/改后：早期石圈篝火照亮、民居屋顶由
近黑变成暖褐并带一圈收紧的光晕，王国与古典屋顶同样由黑转暖，远景 zoom 9 从“几乎全黑”变成
可读的暖色聚落。白天对照帧只有广场火点与风车叶片（`TIME` 驱动）有差异，屋顶/墙面补光只在
`night > 0` 生效，现代（era 10）夜景不变。

未覆盖：没有在真实地形、迷雾和移动端上目检（探针地面是替身色块）；远景 macro 的暖点没有截图，
探针缺少 `map_index_atlas` 等世界纹理，macro 层画不出聚落，只有编译与代码审查。
截图在 `tmp/building_night_tune/`（`beforeT_*` / `v2_*`）。

## 物种出现保底（2026-11-20）

小地图或单大陆世界里，部分 `bio.*` 物种会在整局里一格都不出现：生态包络（气候/湿度/海拔/植被/地貌
标志/载体资源）与地图没有交集，或包络只有几格、被先播的同生态行会占满。辨识科技要求目击物种，
而 `tech.reed_harvesting`（只认 `SIGNAL(bio.reed)`）又是 `野生稻采集 / 湿地稻作 / 稻田水利 / 精准灌溉`
的硬前置，一旦缺种整条水稻线断掉。实测玩家可选最小尺寸 10×8（80 格、13 格陆地）：20 个物种里
8 个 `occupied=0`，其中 5 个包络为空、3 个被行会占满。

现在播种结束后走保底阶梯（`scripts/geography/map_generation/bio_occupancy_guarantee.gd`，融合 boot
pass 与逐段 bootstrap 两条路径都接）：对 `occupied=0` 的物种逐级放宽**只对该物种生效**的播种输入
（去植被掩码 → 去地貌标志 → 去载体资源 → 气候放宽到 persist 容差内 → 气候全放开）并重发
`run_bio_seed_pass`；放宽物种的 `fill_keep≤0.08`、`max_cost≤3`，只留小片残存种群。小图行会占满格位时
最后一步 `manual_relict` 按“离物种气候中心最近、未达每格 3 物种上限”的陆地格补一格（只破行会互斥，
不破格位上限）。残存格可能落在目录气候带外，`_bio_occupancy_base_knobs()` 建缓存时用
`realize_bounds()` 把这些物种的气候边界放宽到覆盖实际占领格，保底成功后作废 knobs 缓存并重置原生
configure，使生成当次与读档后的日推进使用同一份地图本地边界（纯函数于占领位集+气候数组，重算一致）。

验证：`tests/world/bio_coverage_guarantee_test.gd` 12 项全过。10×8：9 个物种被放宽
（`drop_vegetation` 4、`widen_climate` 2、`map_extremes` 3）、`unplaceable=[]`，每个物种至少一格，
残存格连续 3 日 persist 后仍在，同 seed 两次生成占领位集逐字节一致；14×10：放宽 4 种、无缺席。
默认 60×40 世界保底完全不触发——日志没有 `guarantee` 行，20 个物种的
envelope/hearth/occupied 逐项与改动前一致，说明健康地图的分布没有被改写。
`tests/world/bio_guarantee_ladder_test.gd` 13 项（只放宽失败物种、原 knobs 不被污染、阶梯用尽报
`unplaceable`）；`tests/world/bio_occupancy_pass_test.gd` 86 项不变全过。

未覆盖：长读档循环下的 365 日残存稳定性（只验证 3 日）；气候与目录完全不相容的极端地图
（例如全域无河湖湿地的干旱图上的芦苇）仍可能进入 `unplaceable` 日志，这属于地图本身不支持该物种。

## 开拓筹备的派遣储备额度与逐日部分成交（2026-11-20）

筹备期国库采购受「派遣储备」日额度约束（`colonization_daily`，周期开端冻结、按日补充、上限一个周期）。
旧实现把一条物资缺口当成一次整行交易：金额超过剩余额度就记 `colonization_procurement_budget_exhausted`
终态拒绝，而出发闸门要求每一行都买齐，于是一条缺口的价钱一旦超过本周期额度上限，队伍就带着
「进度 100% / 开工包已齐套」永久停在筹备中。周期中途建立的队伍还会因为冻结时没有需求而整周期额度为 0，
每次采购都判超额；面板把这个原因码原样显示给玩家，并保留昨天的拒单记录。

现在按「当天剩余额度 ÷ 源地零售价」把该行裁成部分成交，剩余缺口次日重规划继续补买；当天已经买到货时
后续行的等待不再写拒单；周期中途建队与第一次采购时用 `ensure_epoch_colonization_budget` 补发本周期通道
预算与当天额度；同一行真正成交即清除旧拒单。`kit_blocker` 在两类总量达标、但逐项仍有差额时报 `TOPUP`，
快照新增 `kit_topup_missing_units`；面板补上该原因码文案与 TOPUP 说明，未知原因码不再裸露为英文标识。

专项回归 `tests/country/colonization_procurement_budget_test.gd` 先复现：国库 4000、0.1%/日 份额下
40 天内 39 次整行拒单、托管 0 增长、队伍从未出发。修复后同一夹具第 3 天开始部分成交，第 17 天按额度攒够
后出发，期间拒单 0 次；周期中途建立（强制 3 日周期）的队伍本周期额度从 0 恢复为 800000（国库 4000 ×
2%/日，科技份额 0），并从源地买货。两组夹具的人口、货币、货品守恒差额均为 0。
`family_colonization_runtime_test`、`colonization_planner_context_test`、`procurement_share_contract_test`
三项回归通过；Windows 调试与发布扩展构建通过。`colonization_demand_runtime_test` 仍因
`EconomyCatalog._carrying_need_goods` 缺失解析失败，`colonization_workbench_ui_test` 的三项摘要高度断言
在改动前后的同一份扩展上都失败，两者均为既有问题、与本改动无关。

## 城市独立后日结算中断（2026-11-20）

原日志中第 7102 日的国家阶段已经提交，经济在冻结输入时拒绝少一行的研究信号位图，全图提交停在第 7101 日。
专项回归复现该故障，补齐位图后又复现理念拒绝昨日民意的故障。建国时同步扩展国家位图。
理念接受身份一致的昨日民意前缀，新国家收到首份实际民意后建立积分基线。

正式内联推进回归三轮各通过 54 项，覆盖独立当天经济、理念和全图提交、次日民意、独立后存读档和续跑经济哈希。
Windows 调试与发布扩展构建通过。国家、阶层动员、科技信号、理念和民意生命周期的专项测试通过。

原自动档副本按存档对应的建筑目录加载。无头回放屏蔽弹窗并解除恢复中的年报暂停，以 10 倍速完成 180 天后台结算，
全图和理念提交至第 7115 日。最终人口、货币、货品守恒差额均为 0。回放使用独立存档目录。
模块和存档段契约通过。C++ 依赖检查仍报告既有违规，两处修复前后的依赖引用计数一致。

## 组织度事件选项与结算（2026-11-20）

旧事件在叙事选择结束后才通过监听器修改动员，预览和史册因此只有空效果。让步和收买以零投入计算
成功率，正式后台经济又拒绝旧付款入口。修复后预览和结算使用同一组原生权重，按报价计算资金加成，
动员结果经经济确认后才记录。第四阶的招安、镇压和弃城文案按实际动作编号修正。

旧实现的目标回归复现了五项失败。更新后组织度服务 25 项、动员存档与拨款 107 项、叙事运行时 108 项、
叙事弹窗屏蔽 24 项、城市独立整档与续跑 54 项通过。测试命中介于无投入与足额投入成功率之间的随机值，
验证有资金时走成功分支。Windows 调试与发布扩展均构建，动员存档与拨款测试在两种扩展下通过。

原自动档副本在 10 倍速后台回放至第 7115 日，人口、货币、货品守恒差额均为 0。自动选择的三次让步
成功率分别为 18%、17%、27%，本次抽样均失败，三笔报价仍各在对应生效日足额支付。另在第 7097 日提交后、
第 7099 日支付前保存并在新进程恢复，旧实现丢失首笔拨款，修复版第 7099 日实付 312.011。

## 地图阶层不满与人口页一致性（2026-11-20）

地图告警批次与人口页可在不同经济提交代次刷新，浮标的命中区域也可能跨到邻格。地图与人口快照
现在共用阶层满意度计算。人口页打开时，同格阶层不满提示使用面板已经显示的快照，提示列出该格的
本地结算日。人口页关闭后，较新的结果保留到地图收到更新代次。浮标的悬停和普通点击共用命中区域。

Windows 调试版和发布版原生快照回归各通过 20 项。地图告警层 26 项、后台提交 14 项，以及人口页
增量刷新和玩家控制器契约测试通过。Godot 4.6.2 全项目无头脚本编译无脚本错误。实测渲染覆盖
1280×720 和 1600×900。数值回归使用测试场景，原截图来自的存档未纳入验证。

## 官营军事建筑建材替代（2026-11-20）

17 种官营军事建筑接入经济营造的建材候选组。国库仅存原木时，战士营地、木栅兵营和夯土城垣
分别按 30、60、70 单位报价并成功开工，扣料和经济守恒检查通过。建筑目录身份随配方变化，
旧目录的经济存档会被现有目录哈希校验拒绝。

国库营造和家族殖民回归均为 0 失败，后者覆盖仅用芦苇替代的开局物资包。
已重烘经济目录并核对 17 份军事建筑资源的源指纹。全目录替代性检查的单候选材料只剩其他建筑的锻铁和生皮，
全目录测试还报工具槽、蛋白方案和后期升级条目的既有失败。资源链测试仍报铜矿开采效率排序。

## 投资分日评审遗漏地块（2026-11-20）

682 号地块的第 1460 天存档复现了漏审。投资周期为 30 天，普通评审在第 1462、1492 天到期。
原构建默认路径回放至第 1510 天，两次都未生成该地块的评审结果。关闭 Track-B 后，两次均执行。
建筑提交第四阶段遇到上日未完成的评审时，用旧队列覆盖了当天到期列表。现在将新地块去重追加，
先执行旧批次，并用地块资金暂存的代次标记判断当前评审成员，支持按批次保留顺序。

原生回归在旧实现上报 `investment_carry_erased_newly_due_cell`。修复后通过，
并验证重复地块只评审一次、跨日评审全部执行、无序队列仍可查到已有建筑。
同一存档用修复后的调试扩展和原导出的游戏内容续跑到第 1600 天。682 在第 1463、1493、1523、
1553、1583 天完成评审，新增 5 座早期知识机构和 4 座狩猎营地。期末人口、货币、商品审计误差均为零。
建筑运行时 552 项、经济周期 252 项、StageOps 与 compact 一致性 40 项检查通过。

## 营造建材与开工率（2026-11-20）

营造目录逐项显示建材，报价纸笺展示国库供料、市购和缺口。建筑详情显示每栋基础建材，
分开呈现实际开工率、各岗位在岗人数和每栋每日产量。林木采集显示当前可采量及资源影响。

Godot 4.6.2 全项目脚本编译无脚本错误。营造目录、建筑状态、检查器实时刷新、国库营造、
军事地块台账测试通过。渲染探针覆盖 424、604、1236 像素栏宽，正式开局以 10× 运行
5 天后验证目录报价刷新。全局界面结构测试仍有 `touch_number_pad.gd` 的 10 项既有失败。

同日调整悬停卡的信息层级，费用与建材归入报价区，基础日产、资源、岗位和可选工具用图标分组。
开工率去除说明性段落，满量程直接显示在读数下方。三档栏宽的渲染探针验证狩猎营地卡片
保留产出和工具候选，并给营造按钮留出空间。正式开局的 10× 验证到第 8 天，三项产出逐行显示。

## 军事建筑悬停卡（2026-11-20）

地块军事页和营造目录军事分类使用同一张结构化建筑卡。材料缺口跟随到货品行，
驻军名额、守备和训练效果独立显示，维护区区分当前与建成后的费用。地块页的卡片能停在台账旁，
拆除键显示既有建筑及拆除后果。

渲染探针覆盖 424 和 604 像素栏宽下的报价、受阻与在建状态。正式开局推进到第 6 天，
验证 10× 下的战士营地悬停卡继续显示收益，并留出台账的点击区域。

## 真机性能实测：编译期档位是最大杠杆（2026-11-19，含当日更正）

小米 15（Adreno 830v2 / 2670×1200 @520dpi）上跑当前工作区 debug 包的 5 组配置，
用 `tools/android_perf_run.ps1`（`pk_debug.cfg [perf]` 驱动 PerfRecorder + 设备侧 top/meminfo/thermal 采样）采集：

| 配置 | fps 均值 | fps p5 | fast_ms p50 / p95 | 日/秒 |
| --- | --- | --- | --- | --- |
| 默认视角 1×（迷雾开，实测 `MOBILE_QUALITY_HIGH`） | 34.6 | 25.8 | 8.0 / 87.2 ms | 0.996 |
| 默认视角 1×（`tier_override=MOBILE_QUALITY_LOW`） | **57.2** | 44.6 | 3.3 / 35.2 ms | 0.994 |
| 整图视角 1×（`fog=off`、HIGH） | 15.5 | 13.5 | 4.9 / 73.4 ms | 0.989 |
| 默认视角 10×（HIGH） | 14.0 | 7.5 | 22.7 / 110.9 ms | 6.91 |

> ⚠ 更正：初版把前两行当成"LOW vs HIGH"，其实这台机器 `settings.cfg` 是 `render_quality="high"`，
> 两轮都是 HIGH（日志 `quality=MOBILE_QUALITY_HIGH`）。补测 `tier_override=LOW` 后才有真正的台阶：
> 28.9 ms → 17.4 ms（fps 34.6 → 57.2，+65%）。LOW 档同时把 `[fog] effective` 3 → 2，差值是"编译期分支 + 迷雾质量"合计。

结论：① **编译期档位是最大杠杆**（LOW 比 HIGH 少 40% 帧时间），其次是可见内容量（HIGH 下迷雾关掉 −55%）；
真正该追问的是"为什么移动端默认设置解析成 HIGH"；② 10× 只跑到 6.9 天/秒，
瓶颈是日代价 p50 22.7 ms（其中 `event_dispatch` 13.4 ms、`worker_time_execute` 16.6 ms）；
③ 每日代价尖峰型（p50 8 ms / max 339 ms，36% 的天 > 50 ms），最贵那天已埋点子系统合计 < 15 ms，
开销在未埋点路径；④ 1× 下 worker 每天 71 ms 只有 2.85 ms 在算、68.6 ms 在等帧边界，
快照陈旧 58 ms —— 日结延迟是同步问题不是算力问题；⑤ 移动端 `t_render_ms`/`t_ui_ms` 恒 0，
渲染侧只能靠帧率与场景 A/B 推断，需要补埋点。

证据与全部原始数据：`artifacts/PERF_REPORT_ANDROID_20261119.md` +
`artifacts/perf_android_2026111*_*/`（CSV/logcat/线程 CPU 序列/截图/summary.json）。
同轮还确认：叙事事件弹窗会 `pause(true)` 卡住无人值守 soak，因此 perf 录制启动时自动打开 GM 的
`ui.suppress_popups`；`android_perf_run.ps1` 另加 `-MaxBatteryTempC 43` 热保护（连跑曾把电池顶到 51.9 °C）。

### 渲染耗时细分（逐层扫描，2026-11-19 同日）

`render_perf_probe.gd` 逐帧写 `render_trace_*.csv`（seg / fps / frame_ms / setup_cpu_ms / draw_calls / primitives），
配合分段扫描（每层 `visible=false`+`set_process(false)`，层间交替插 baseline 抵消世界演进漂移）。
整图视角（`fog=off`，基准 61.7 ms / 16.2 fps）：HexRenderer 整体 **44.1 ms（71.5%）**，其余 17.6 ms 是 HUD + WorldRoot 其它覆盖层 + present/引擎；
天气层 **4.6 ms（7.4%）**且占全画面 **82% 的图元**（36.0k→6.4k）；地表基座/资源/建筑/边界各自 ≤1.7 ms（噪声内）。
默认迷雾视角（23.1 ms）：天气 2.4 ms、世界 6.1 ms、UI 0.4 ms，其余是同一块 ~17 ms 地板（≈57 fps，接近 60 Hz 一个 vsync 周期）。

- **缺陷信号**：把植被层 20 个节点设为不可见后帧时间反而从 61.7 → **119.6 ms（1.94×）**，两轮复现，图元数几乎不变（36.0k→35.6k）。
  说明隐藏到的只是内层 MultiMesh，layer 自身的实例更新仍在跑并被切成每帧重建 ⇒ **植被层 visible / set_process 没有真正解耦**。
  在修掉之前，任何"关植被看省多少"的 A/B 都会得出反向结论；要量植被成本只能在 world build 前不生成或加层内计时。
- 渲染侧口径：迷雾关时渲染线程 CPU ≈18.4 ms/帧（29.9%），GPU/present 等 ~43 ms ⇒ GPU 受限；迷雾开时 ≈10.6 ms（45.7%）。
  `setup_cpu_ms`（draw list 装配）仅 0.7–1.5 ms。后期世界（day 700+）渲染线程升到 76.3%、帧时间 44.6 ms，瓶颈转向 CPU 渲染侧。
- 仍未解决：植被/雾/地形之间约 38 ms 拆不开（节点级可见性已到极限，需要层内计时或逐层 GPU timestamp）；
  `RuntimeClockBinding` 会把 `_clock.pause(true)` 每帧同步回 running，扫描前"冻结世界"的做法不成立。

### 逐模块"独奏"与"关迷雾反而更慢"（2026-11-19 续）

关掉帧率上限与 vsync 后，每次只保留"迷雾层 + 一个模块"量边际成本（默认档、1×、day 6–83）：

| 可见内容 | 帧时间 | 模块成本 | draw calls | 图元 |
| --- | --- | --- | --- | --- |
| 全部（baseline） | 23.8 ms | — | 236 | 32.7k |
| 只留迷雾 | **17.3 ms** | 含引擎固定开销，占默认帧 **73%** | 10 | 473 |
| + 天气层 | 21.9 ms | **+4.55 ms（19%）** | 20 | **29.5k（90%）** |
| + UI | 18.3 ms | +0.98 ms | 160 | 1.5k |
| + 覆盖层 | 17.9 ms | +0.58 ms | 67 | 2.3k |
| + 资源 | 17.6 ms | +0.34 ms | 22 | 0.8k |
| + 地表/植被/建筑/边界 | 17.2–17.5 ms | ≤0.2 ms（隔离下未真正出画，只是上界） | 7–18 | 0.4–1.0k |

- **病态路径（最要紧）**：把迷雾层隐藏后，即使其它层也全关，帧时间从 23.8 → **53.7 ms（只剩 2 个 draw call / 2136 图元）**，
  比"只留迷雾"还贵 36 ms。三种做法都复现：`?fog=off`、隐藏 `FogOfWarLayer`、独奏 `none`。
  ⇒ 迷雾同时是"地形 early-out 的开关"，关掉后世界材质走进贵得多的路径（疑似每帧重建材质/LUT 或全屏兜底 pass）。
  **在查清这条路径之前，不要做任何"削减/关闭迷雾"的优化。**
- **60 fps 上限**：`graphics_quality_settings.resolve()` 对移动端非 `low` 档固定 `frame_rate_limit=60`
  （`Engine.max_fps=60`），`settings.cfg` 里玩家存的 `frame_rate_limit=30` 因 `graphics_custom=false` 被忽略。
  实测封顶 57–58 fps 是**上限**不是渲染成本；测真实天花板须 `[perf] max_fps=0` + `vsync=0`。

[返回专项记录总目录](feature-status.md#历史记录)
