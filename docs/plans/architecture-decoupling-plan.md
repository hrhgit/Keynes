# 架构解耦计划

核查日期：2026-11-26。源码起点为 `origin/master@cfd9fb70`。依赖数字使用 P3 重定级后的基线。本页排解耦工作的范围、顺序和验收；它接在 [执行队列](execution-queue.md) 第 13 项（单一时间线迁移）之后，不替代它。目标架构见 [design.md](../architecture/design.md)。

## 判断标准

耦合分四类，处理方式不同：

| 类别 | 含义 | 处理 |
|---|---|---|
| 结果耦合 | 机器负载、帧率或线程快慢能改变逐日结果 | 必须为零 |
| 所有权耦合 | 同一份状态有两个持有者，或有多个写入者 | 消除 |
| 结构耦合 | 模块互相引用对方的类型和函数 | 走接口头或已提交视图即可，按需迁移 |
| 玩法耦合 | 功能之间的相互影响，例如军队采购改变市场库存 | 不动 |

不追求把设计矩阵排成对角。逐日结算是地基，命令、等待、交付和存档都依赖它。

## 现状

| 项目 | 数字 | 来源 |
|---|---|---|
| 原生源码 | 1117 个文件，约 36.3 万行 | `gdext/src` 顶层 |
| Economy | 354 个文件，约 12.2 万行，占 34% | 文件名以 `economy` 开头 |
| 绑定层 | 203 个文件，约 7.2 万行，772 处方法绑定 | `world_ext*` |
| 宿主 | 71 个文件，约 2.3 万行 | `native_simulation_host*` |
| 域间引用 | 23 个域对；债务 931 处，契约 614 处 | `cpp_deps_baseline.json` |
| 待逐函数核查的域对 | 19 个 | `cross_domain_inventory.json` |
| 脚本越界访问原生接口 | 32 个文件 52 项 | `script_native_access_baseline.json` |
| 表外推进者 | 8 个，6 个在执行线程 | `runtime_advancers.json` |

### 已经做完的部分

- 军事、自然资源恢复、物种、视野都在后台执行器里运行。登记在主线程的两项是 `visual_delivery` 和 `climate_writeback`，均消费已发布内容。
- 日尾闸门 `mark_runtime_day_tail_done` 已从源码删除。
- 执行器拥有经济时，经济查询从已提交的读视图返回（`world_ext_economy.cpp` 的 `committed_read`）。

八项推进者的调度位置和读写见[十二域以外的推进](../architecture/current-state.md#十二域以外的推进)。镜像、经济输入及脚本调用范围见[前台尚存的模拟工作](../architecture/current-state.md#前台尚存的模拟工作)。

### 域间债务的分布

| 域对 | 债务引用 | 占比 |
|---|---|---|
| Ideology → Country、Ideology → Effect | 384 | 41% |
| Economy ↔ Country | 157 | 17% |
| Economy → Effect | 115 | 12% |
| Climate → Economy、Climate → Modifier | 90 | 10% |
| 其余 16 个域对 | 185 | 20% |

- Family 随经济的 `FAMILY_COMMIT` 运行，状态和存档由 Economy 持有。家族子模块与经济其余部分的引用计入域内。
- Ideology 和 Effect 都没有接口头。Ideology 的 384 处引用分布在 29 个文件，其中 `ideology_runtime_operations.h` 占 80 处。
- Climate 的 90 处里有 80 处在 `runtime_climate_parity.cpp`，属于对拍代码。

### Economy 内部

`NativeEconomyRuntime` 是一个类，状态成员约 980 个，实现分在约 350 个文件。按文件名把实现分成 51 个业务组后（已排除诊断、重置、存档、配置、目录、查询这类需要读写全部状态的组）：

| 指标 | 数量 |
|---|---|
| 被业务组直接写入的成员 | 613 |
| 只有一个组写入 | 517（84%） |
| 两个及以上的组写入 | 96 |
| 三个及以上的组写入 | 19 |
| 被两个及以上的组读取 | 401 |

这是文本统计：只数成员名在赋值和容器修改处的直接出现，经引用或辅助函数的写入没有计入，实际的多写入者会更多。写入的归属大体清楚，读取很宽。

### 仍然存在的所有权耦合

- **主线程镜像。** `apply_runtime_modifier_snapshot`、`apply_runtime_effect_snapshot`、`apply_runtime_ideology_snapshot`、`apply_runtime_trigger_snapshot` 四个入口仍绑定。正式会话安装 Modifier 镜像，Effect、Trigger 只有测试调用，Ideology 无调用方。
- **前台直读。** `try_lock_economy_read_boundary` 有 7 处使用，分在 6 个文件。后台日循环取同一把锁时会等主线程。
- **日中途停等。** `RUNTIME_DAY_STALL_*` 定义六个位。经济输入请求属于兼容路径。默认整图授权下，后台在开启经济周期前取齐当日输入。
- **执行方式并存。** `RuntimeSimulationMode::SHADOW` 有 17 处使用，分在 13 个文件；文件名带 `parity` 的对拍代码 8 个文件 2376 行。

### 放行

日循环分别读取存档请求、待答事项、暂停标志和时钟请求四个条件（`native_simulation_host_worker_section_run_authoritative_days.inc`）。前台领取日记录时顺带更新 `_display_consumed_day`，这个值参与放行上限的计算（`native_simulation_host_day_tail.cpp`、`native_simulation_host_environment.cpp`）。现有 50× 对照表明它只影响推进快慢，不影响逐日结果。

## 不做

- 不拆玩法之间的相互影响。
- 不做一轮清空 19 个待核查域对的工作；哪两个模块要并行修改，再核查那一对。
- 不做绑定层按模块拆类。执行队列第 8 项已暂缓，立项条件没有变化。
- 不恢复提交的黄金基线。验证沿用「同一二进制重复运行一致」和「改前改后临时候选逐字段比较」。

## 阶段

顺序是 P0 → P1 → P2 → P4 → P5。P3 只动护栏登记和文档，可以排在 P0 之后任意位置。同一时间只有一个写任务。[正确性地基](correctness-foundations.md)的步骤 1（存档恢复事务）排在 P1 之前，步骤 3（统一日输入）与 P2 合并。

### P0 对齐事实

范围小，先做，否则后面各阶段的范围会按过时文档来定。

1. 按 `runtime_advancers.json` 重写 `current-state.md` 的推进者表，删掉日尾闸门的描述。
2. 补上或改掉「前台尚存的模拟工作」锚点，内容写下面第 3 至 5 条的核实结果。
3. 核实 Effect、Ideology、Trigger 三个镜像入口在正式路径上是否还有调用方。
4. 核实经济输入采集的停等在默认整图授权下能否触发。
5. 核实 `scripts/simulation` 约 2.5 万行里哪些文件仍在正式路径上，哪些只被测试引用。

验收：`check_runtime_advancers.py`、`check_module_map.py` 通过；第 3 至 5 条各有结论，结论附代码路径或一次运行的日志。

### P1 单一时间线收尾

对应执行队列第 13 项的步骤 2、4、5。每一小步的验收是：正式路径上只剩一个状态所有者，读方读同日发布值，逐日结果不变。删镜像的那一步应净删。

1. **删日中途的跨线程请求。** 按 P0 第 4 条的结论处理经济输入采集。每去掉一种请求，删掉对应的 `RUNTIME_DAY_STALL_*`。
2. **删主线程镜像。** 顺序是 Modifier、Effect、Trigger、Ideology，最后是 Country 的同步对象。每个域先定只读帧接口，把读方改过去，再删镜像和对应的 `apply_runtime_*_snapshot`。
3. **前台直读清零。** 7 处 `try_lock_economy_read_boundary` 改读已提交视图；脚本越界 52 项降到 0。
4. **对拍代码。** design.md 写明覆盖充分前保留 SHADOW 和对拍。是否现在删由用户决定，见「待决定」。

验收：

- 每一小步跑 `check_golden_determinism.py`，空闲和并行加压各若干次。
- 改到存档或命令路径的小步加跑 `check_replay_matrix.py`。
- 第 3 步结束后，正式路径上后台日循环不再因前台读取而等锁，`observe_main_wait` 不再触发。

### P2 放行收口

把「可放行到哪一天」收到一处计算，日循环只比较一个日期。

1. 存档请求、暂停、待答事项改成同一种「停在日界」请求，经同一个入口登记。
2. 前台随时钟请求显式上报已看到的日期；`take_day_publications` 不再修改 `_display_consumed_day`。
3. 日循环的四个条件换成一次比较。

验收：每帧领取与每 100 毫秒领取两种设置下，50× 前 180 日的业务摘要和操作回执一致；执行器边界测试和保存测试通过。

这一阶段收益有限，排在 P1 之后是因为 P1 会改同一批文件。

### P3 Family 的归属

2026-11-26 按既有计算和数据归属把 Family 登记为 Economy 子模块。运行时、文件名和存档格式均沿用原实现。更新了文件与类型归类、依赖基线、跨域清单；5 个并入目标均保留待逐函数核查状态。

原始证据为 `cfd9fb70:tools/ci/cpp_deps_baseline.json`，SHA-256 为 `e9e18118701ee0a42e2857e8f13747ec4d4fe117328fa055c198a76f8292e55c`。一次性命令 `python tools/ci/check_cpp_deps.py --write-baseline --reclassify-family` 只接受这份旧基线。它逐键换算文件、域对和符号，分别与源码扫描出的债务表、契约表核对，任意增减、换文件或换类别都拒绝。平时仍使用原收紧命令。

30 个域对归并为 23 个。原有 23 个非 Family 域对各自贡献的债务数、契约数逐项一致，其中 5 个另计迁入引用。全部 739 个键归并为 504 个，头文件引用 479 → 301，总引用 2149 → 1545。原 514 条搬移记录中，242 条两端已属经济内部，原证据保存在上述旧基线；22 条改为新的域对，250 条域对不变。保留的 272 条沿用原文件和数量证据。

| 原域对 | 改前债务 / 契约 | 改后债务 / 契约 | 原引用的去向 |
|---|---:|---:|---|
| `climate->economy` | 50 / 0 | 50 / 0 | 原数 |
| `climate->modifier` | 40 / 0 | 40 / 0 | 原数 |
| `country->economy` | 77 / 1 | 77 / 1 | 原数 |
| `country->effect` | 11 / 0 | 11 / 0 | 原数 |
| `country->modifier` | 5 / 19 | 5 / 19 | 原数 |
| `economy->country` | 78 / 375 | 80 / 378 | 含 `family->country` |
| `economy->effect` | 79 / 19 | 115 / 23 | 含 `family->effect` |
| `economy->family` | 352 / 1 | — | 经济内部 |
| `economy->military` | 3 / 0 | 3 / 0 | 原数 |
| `economy->modifier` | 3 / 50 | 3 / 52 | 含 `family->modifier` |
| `economy->trigger` | 7 / 0 | 7 / 0 | 原数 |
| `effect->country` | 10 / 21 | 10 / 21 | 原数 |
| `effect->economy` | 5 / 27 | 24 / 27 | 含 `effect->family` |
| `effect->family` | 19 / 0 | — | 并入 `effect->economy` |
| `effect->modifier` | 32 / 43 | 32 / 43 | 原数 |
| `family->country` | 2 / 3 | — | 并入 `economy->country` |
| `family->economy` | 251 / 0 | — | 经济内部 |
| `family->effect` | 36 / 4 | — | 并入 `economy->effect` |
| `family->modifier` | 0 / 2 | — | 并入 `economy->modifier` |
| `ideology->country` | 195 / 4 | 195 / 4 | 原数 |
| `ideology->economy` | 5 / 15 | 30 / 15 | 含 `ideology->family` |
| `ideology->effect` | 189 / 1 | 189 / 1 | 原数 |
| `ideology->family` | 25 / 0 | — | 并入 `ideology->economy` |
| `ideology->modifier` | 3 / 19 | 3 / 19 | 原数 |
| `modifier->country` | 3 / 2 | 3 / 2 | 原数 |
| `modifier->economy` | 3 / 2 | 3 / 2 | 原数 |
| `modifier->effect` | 3 / 0 | 3 / 0 | 原数 |
| `trigger->economy` | 14 / 7 | 14 / 7 | 原数 |
| `trigger->effect` | 28 / 0 | 28 / 0 | 原数 |
| `trigger->ideology` | 6 / 0 | 6 / 0 | 原数 |
| **总计** | **1534 / 615** | **931 / 614** | 603 处债务、1 处契约转为域内 |

### P4 Economy 内部分区

这是工作量最大的一项。目标是让改建筑的人不必读市场和财政的状态。

1. 写一个一次性脚本列出每个成员的写入组，放在仓库外，不提交为护栏。先人工核对三个及以上的组写入的 19 个成员，校正文本统计的漏计。
2. 给 96 个多写入者成员逐个定所有者。其余写入方改成调用所有者的函数。
3. 按所有者把成员收进子状态结构。现有的 4 个成员分组头（建筑与市场、命令与发布、配置与环境、人口与家族）是起点。
4. 其他分区只拿子状态的只读引用。

每一步都是不改行为的搬移，用改前改后临时候选逐字段比较验证。

验收：

- 多写入者成员从 96 降到 20 以下，剩余的每个写明原因。
- `check_golden_determinism.py` 通过。
- 成员布局变化可能影响热循环，每个批次用 `headless_perf_record.gd` 在同一场景和设置下做改前改后对比，结果写进 PR 说明。

可以集中做一轮，也可以改到哪个分区做哪个分区，见「待决定」。

### P5 Ideology 和 Effect 的接口头

Ideology → Country 和 Ideology → Effect 是 Family 之外最大的两块债务。按 Economy、Country 的做法补 `ideology_api.h` 和 `effect_api.h`，契约文件放 `tools/ci/module_api/`。先迁 `ideology_runtime_operations.h` 的 80 处，它是头文件，引用会传给所有包含者。

验收：`check_module_api.py` 通过；两个域对的债务引用下降，契约引用相应上升，总量不增。

### 之后按需

- Climate 的 90 处债务随对拍代码的去留处理，不单独立项。
- 其余域对在有并行修改需求时逐对核查。
- 绑定层拆类等执行队列第 8 项的立项条件满足后再排。

## 每个阶段都要做的

- 开始前拉取上游并核对分支差异。
- 改边界、入口或存档段的同一次改动里更新 `module-map.md` 和对应 skill。
- 推送前跑 `.github/workflows/runtime-checks.yml` 列出的静态护栏和 `python tools/ci/run_regression_checks.py --import --roundtrip`。
- 修失败测试时先写根因证据，不放宽断言、不加长超时。

## 待决定

1. **对拍代码和 SHADOW 现在是否删除。** 删掉能去掉 2376 行和 Climate 的大部分债务，代价是失去双算对照。
2. **P4 的节奏。** 集中做一轮，或改到哪个分区做哪个分区。

Family 的归属已定，见 P3。

## 没有核实的

- Economy 内部的数字是文本统计，没有做 C++ 名称解析。
- P0 的镜像、停等、逐脚本结论来自源码核查，见[运行现状](../architecture/current-state.md#前台尚存的模拟工作)。本树缺少已构建的扩展，未实跑游戏。
- P0、P3 的检查覆盖本次文档与依赖登记。未在本树重新验证游戏回放。
