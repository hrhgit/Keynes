---
name: project-keynes-effect-runtime
description: Develop and review Project.Keynes Native Effect Runtime catalog IR, C++ behaviors, effect instances, plans, cross-domain transactions, ACKs, PKEF persistence, scheduling, diagnostics, and domain adapters.
---

# Project Keynes Effect Runtime

Use this skill for any configurable Buff/Effect/Ideology/technology/family/person
effect work that crosses a runtime domain. Read `cpp-dots-runtime-development`,
`project-keynes-runtime-architecture`, `project-keynes-trigger-runtime`, and
`project-keynes-modifier-runtime` first when the change crosses those owners.

## Authority

`EffectRuntime` owns catalog compilation, dense IR, active instance lifecycle,
frozen input revisions, deterministic plans, transactions, idempotency, and
ACK cursors. Country, Economy, Modifier, Trigger, GameplayEventBus, DataCore,
and conserved ledgers keep their existing ownership. An Effect Runtime method
must never write one of those stores directly.

## Hot-path contract

- Compile Resource data into packed columns and dense IDs before simulation.
- Use POD/SoA, Q16 integer arithmetic, fixed stacks, bounded work, and cursors.
- Do not evaluate GDScript, Callable, Godot Object, String, or Dictionary in the
  native evaluation loop.
- Declare metric reads and command domains in the catalog. Reject bad offsets,
  opcodes, capacities, duplicate keys, and invalid targets at configure time.
- Preserve generation and fire-sequence idempotency. Overflow is a diagnostic
  failure, never a silent drop. Propagate target generation with every command;
  an instance generation change rejects its old pending transactions.

## Configuration and C++ behaviors

Use `EffectCatalog` plus `EffectDefinition`, `EffectCondition`,
`EffectInstruction`, and `EffectCommand` Resources for bounded arithmetic and
simple Modifier-like commands. Register open-ended algorithms with
`EffectRuntime::register_behavior()` at compile time. A behavior receives a
frozen `BehaviorInput` and emits POD commands through the preallocated bounded
`BehaviorOutput.emit()` buffer; it must not mutate domains or grow an
unbounded output container.

## Transaction boundary

The required flow is `evaluate -> plan -> adapter preflight -> runtime
PREFLIGHTED -> safe commit -> runtime COMMITTED -> ACK`. Cross-domain
transactions remain pending until every required domain bit is acknowledged.
整图授权时，`NativeSimulationHost::stage_effect_adapter` 在日尾安装已提交的
Effect 结果，保留 Economy 加入的殖民、运河事务和 Country、Economy 的回执关联。
前台的 Effect 报告读取该阶段随日发布的视图。同日续算只补发已经到期的首次事务，保留未来实例原定日期。每条新命令随这一天的事件发布一次，待收回执的命令沿用首次发送的事务号、序号、程序、来源及幅值倍率。重送只交给尚未确认的接收方。
Known Modifier commands should use the native batch bridge first:
`EffectRuntime::dispatch_native_modifier()` -> `ModifierRuntime` POD enqueue ->
`modifier_daily` -> `ack_native_modifier()`. `EffectFacade` is only the
fallback adapter/transport layer; it must preserve the contiguous cursor and
pass each command's idempotency key to the domain adapter.
Existing technology, family, and person producers are not migrated implicitly.

Current repository migration boundary:

- technology completion registers `technology.<id>` instances and the
  `technology.modifier` adapter emits the existing country Modifier command;
- legacy family branch Modifier reconciliation registers
  `family.modifier.<definition_key>` instances and publishes branch Q16
  magnitude through the `family.magnitude_q16` metric;
- authored `family.effect.*` programs carry compiled source/target/operation/
  lifecycle/stack/selector metadata, use typed targets, and arbitrate by
  `(target_domain, target_handle, target_generation, stack_key_hash)`;
- native person promotion and `PERSON_COMMIT` register the current
  `person.modifier.gameplay.generic.bonus` instance; `NotablePersonStore` and
  `PERSON_COMMIT` remain authoritative for people state, ledgers, and structure.

Technology activation is ACK-gated: while a country technology is pending,
`NativeCountryRuntime` waits for the corresponding Effect instance fire to
finish its Modifier transaction. It must not reset an existing instance's
cadence or use the direct Modifier fallback merely because the Effect is still
pending. The direct path is only a registration/configuration failure fallback.
Person instances use precompiled `person.modifier.<modifier_definition_key>`
programs for existing ECONOMY and GAMEPLAY Modifier definitions; an empty
authored key is invalid.

## Scheduling and persistence

Register `effect_runtime` after `trigger_runtime` and before `modifier_daily`.
Use `effect_should_run(day)` and a cooperative `done=false` cursor.

PKEF v14 保存实例、指标快照和版本、程序哈希、触发序号、生命周期与叠层、待收回执的事务、正在计算的候选及上次消费的输入版本。读档校验格式版本、目录哈希及数据完整性。后台 EFP1 v5 同时保存首次发射时的程序、来源与倍率。旧 v4 待收的修正确能还原时沿原事务重送，缺失必要参数时拒绝该档。

Store a native-bound
`PREFLIGHTED` transaction as `PLANNED`: native Modifier request IDs are not
valid after restart, while the command idempotency key is. A strictly newer metric
revision may re-evaluate once in the same day; unchanged input obeys cadence.
For large declarative batches, workers may read frozen slabs into per-candidate
plans, but a stable serial merge remains the only writer of transactions and
instance state. Behavior callbacks stay serial unless their owner supplies a
thread-safe contract. Report due/dirty/candidate counts, flat metric slab bytes,
dormant scan count, parallel plan/merge path/timings, and native Modifier
dispatch/ACK timings. Keep pending command idempotency and transaction/source
state in native hash indexes; never reintroduce a scan across every pending
transaction in the merge hot path. Use the runtime-wide command arena,
per-transaction `(command_begin, command_count)`, and reusable instance
slots/tombstones rather than an allocation per transaction or permanent
historical instance slots. Batch native Modifier commands by command count up to
`max_native_modifier_commands`, not by a fixed transaction count.

Rejected domain work does not complete a managed lifecycle transition. Preserve the last ACKed
applied/stack state, retry on the next day, reclaim EVENT_ONCE only after full ACK, and keep an
explicit retire pending until its REMOVE is ACKed.

Family metrics 0–9 are occupied. Append new keys at the end of `metric_keys`; never reorder.
`EVENT_COMMAND` may carry a construction-completion `type_id`. Producer `161` Family/Branch ENTITY
handles that fail generation checks are rejected, not repaired. Colonization `population_reward`
lives on SETTLE payload[3] (`i32_1`); payload[0] remains the shared CLAIM/SETTLE cell.

## Required validation

Add focused tests for catalog validation, Q16 arithmetic, condition gating,
stable target/generation, deterministic plan hash, duplicate idempotency,
multi-domain ACK, explicit transaction states, rejection retry, EVENT_ONCE/retire ACK gating,
overflow, cursor slicing,
atomic PKEF round-trip/truncation rejection, native-bound restore replay,
instance-slot reuse, and Trigger handoff. Run
`scripts/verify_effect_runtime.ps1`, `git diff --check`, the native build, and
the headless `tests/effect/effect_runtime_test.gd` and
`tests/effect/effect_domain_integration_test.gd` fixtures. Do not claim a performance
regression target without same-machine baseline and after measurements.
