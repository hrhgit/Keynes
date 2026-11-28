#include "effect_runtime.h"
#include "effect_runtime_internal.h"

namespace pk {

using namespace godot;

namespace {
// 每次持久化自测均经过正式目录校验。程序 0 是一次性效果，程序 1 持续十天。
Dictionary persistence_test_catalog() {
    Dictionary catalog;
    catalog["effect_keys"] = PackedStringArray{"test.capture.original", "test.capture.replacement"};
    catalog["metric_keys"] = PackedStringArray{"test.capture.metric"};
    for (const char *field : {"source_kinds", "target_domains", "operations", "stack_policies",
            "priorities", "target_selector_kinds", "instruction_arg0", "instruction_arg1",
            "command_value_modes"})
        catalog[field] = PackedInt32Array{0, 0};
    for (const char *field : {"stack_keys", "target_selector_ids"})
        catalog[field] = PackedStringArray{"", ""};
    catalog["lifecycles"] = PackedInt32Array{0, 1};
    catalog["duration_days"] = PackedInt32Array{-1, 10};
    catalog["instruction_ops"] = PackedInt32Array{EffectRuntime::EMIT_COMMAND, EffectRuntime::EMIT_COMMAND};
    catalog["max_stacks"] = PackedInt32Array{1, 1};
    catalog["condition_offsets"] = PackedInt32Array{0, 0, 0};
    catalog["instruction_offsets"] = PackedInt32Array{0, 1, 2};
    catalog["command_offsets"] = PackedInt32Array{0, 1, 2};
    catalog["command_actions"] = PackedInt32Array{EffectRuntime::MODIFIER_COMMAND, EffectRuntime::MODIFIER_COMMAND};
    catalog["command_domains"] = PackedInt32Array{3, 3};
    catalog["command_opcodes"] = PackedInt32Array{1, 1};
    catalog["command_target_resolvers"] = PackedInt32Array{EffectRuntime::TARGET_INSTANCE, EffectRuntime::TARGET_INSTANCE};
    catalog["command_duration_days"] = PackedInt32Array{-1, -1};
    catalog["command_stacks"] = PackedInt32Array{1, 1};
    catalog["command_keys"] = PackedStringArray{"test.capture.emit", "test.capture.replace"};
    catalog["command_definition_keys"] = PackedStringArray{"test.capture.modifier", "test.capture.modifier"};
    for (const char *field : {"instruction_values", "command_static_targets", "command_values",
            "command_payload_i0", "command_payload_i1", "command_payload_i2", "command_payload_i3"})
        catalog[field] = PackedInt64Array{0, 0};
    return catalog;
}
} // namespace

bool EffectRuntime::pod_snapshot_persistence_self_test(std::string &error) const {
    auto fail = [&](const char *reason) { error = reason; return false; };
    EffectRuntime candidate;
    const Dictionary configured = candidate.configure(persistence_test_catalog());
    if (!bool(configured.get("ok", false))) {
        error = String(configured.get("reason", "effect_persistence_fixture_program_missing")).utf8().get_data();
        return false;
    }
    const int32_t program = 0;
    const int32_t replacement_program = 1;
    if (candidate._definitions.size() != 2 || !uses_managed_lifecycle(candidate._definitions[replacement_program]))
        return fail("test_only_effect_replacement_program_missing");
    const Definition &d = candidate._definitions[program];
    if (uses_managed_lifecycle(d) || !d.behavior_id.empty() || d.command_count < 1)
        return fail("effect_persistence_fixture_program_missing");
    const CommandDefinition &c = candidate._command_definitions[d.command_begin];
    RuntimeEffectPodSnapshot snapshot;
    snapshot.generation = 1;
    snapshot.committed_day = 12;
    snapshot.metric_values.resize(candidate._metric_count, 37);
    RuntimeEffectPodInstance instance;
    instance.instance_id = 42;
    instance.program_id = program;
    instance.source_handle = 7;
    instance.target_handle = 9;
    instance.target_generation = 1;
    instance.next_due_day = 20;
    instance.input_revision = 7;
    instance.last_evaluated_input_revision = 7;
    instance.fire_sequence = 3;
    instance.last_acked_fire_sequence = 3;
    instance.effect_applied = 1;
    instance.applied_input_revision = 7;
    instance.applied_stack_count = 1;
    snapshot.instances.push_back(instance);
    RuntimeEffectPodCommand command;
    command.action = static_cast<RuntimeEffectPodAction>(c.action);
    command.domain = c.domain;
    command.opcode = c.opcode;
    command.source_instance_id = 42;
    command.source_generation = 1;
    command.source_handle = 7;
    command.target_handle = 9;
    command.target_generation = 1;
    command.value = c.value;
    command.duration_days = c.duration_days;
    command.stacks = c.stacks;
    command.command_definition_id = d.command_begin;
    command.command_key_hash = RuntimeEffectPodAuthority::hash_text(c.command_key.c_str());
    command.definition_key_hash = c.definition_key.empty() ? 0
        : RuntimeEffectPodAuthority::hash_text(c.definition_key.c_str());
    command.effective_day = 12;
    command.idempotency_key = 123;
    command.payload = c.payload;
    snapshot.command_arena.push_back(command);
    RuntimeEffectPodTransaction tx;
    tx.transaction_id = 5;
    tx.source_instance_id = 42;
    tx.source_generation = 1;
    tx.effective_day = 12;
    tx.command_count = 1;
    tx.fire_sequence = 3;
    tx.input_revision = 7;
    tx.delivery_program_id = instance.program_id;
    tx.delivery_source_type = instance.source_type;
    tx.delivery_source_id = instance.source_id;
    tx.delivery_magnitude_scale_q16 = instance.magnitude_scale_q16;
    tx.required_ack_mask = RuntimeEffectPodAuthority::adapter_ack_bit(command.action);
    tx.received_ack_mask = tx.required_ack_mask;
    tx.status = RuntimeEffectPodTransactionStatus::ACKED;
    tx.plan_hash = RuntimeEffectPodAuthority::calculate_plan_hash(42, 1, 12, 3, snapshot.command_arena);
    snapshot.transactions.push_back(tx);
    if (!candidate.apply_pod_snapshot(snapshot, error)) return false;
    const PackedByteArray canonical = candidate.capture();
    if (!bool(candidate.restore(canonical).get("ok", false)) ||
        candidate.capture() != canonical)
        return fail("effect_pod_snapshot_roundtrip_failed");
    // A later ENSURE can replace the instance's program while the original
    // transaction still waits for its receipt. PKEF stores both identities.
    RuntimeEffectPodSnapshot changed_program = snapshot;
    ++changed_program.generation;
    const Definition &replacement = candidate._definitions[replacement_program];
    auto &updated_instance = changed_program.instances[0];
    updated_instance.program_id = replacement_program;
    updated_instance.lifecycle = static_cast<RuntimeEffectPodLifecycle>(replacement.lifecycle);
    updated_instance.stack_policy = static_cast<RuntimeEffectPodStackPolicy>(replacement.stack_policy);
    updated_instance.max_stacks = replacement.max_stacks;
    updated_instance.cadence_days = replacement.cadence_days;
    changed_program.instances[0].pending_transaction_id = tx.transaction_id;
    changed_program.transactions[0].status = RuntimeEffectPodTransactionStatus::COMMITTED;
    changed_program.transactions[0].received_ack_mask = 0;
    EffectRuntime projection = candidate;
    if (!projection.apply_pod_snapshot(changed_program, error)) return false;
    const auto replaced_save = projection.capture();
    if (!bool(projection.restore(replaced_save).get("ok", false)) ||
        projection.capture() != replaced_save ||
        projection._instances[0].program_id != changed_program.instances[0].program_id ||
        projection._transactions[0].program_id != program ||
        projection._transactions[0].status != COMMITTED)
        return fail("test_only_effect_pending_program_changed_on_roundtrip");
    for (int32_t invalid_program : {-1, static_cast<int32_t>(projection._definitions.size())}) {
        changed_program.transactions[0].delivery_program_id = invalid_program;
        if (projection.apply_pod_snapshot(changed_program, error) ||
            error != "effect_pod_snapshot_program_invalid" ||
            projection.capture() != replaced_save)
            return fail("test_only_effect_invalid_delivery_program_not_rejected_atomically");
    }
    const uint64_t activation = candidate._instances[0].activation_sequence;
    ++snapshot.generation;
    if (!candidate.apply_pod_snapshot(snapshot, error) ||
        candidate._instances[0].activation_sequence != activation)
        return fail("effect_pod_activation_changed_on_refresh");
    // Economy may begin a claim before the next catalog snapshot is applied.
    // Its transaction and the next catalog fire must both survive the merge.
    constexpr uint64_t country_handle = uint64_t{1} << 32;
    constexpr uint64_t expedition_handle = country_handle | 1u;
    candidate.begin_executor_transaction_namespace();
    int64_t claim_transaction = 0;
    if (!candidate.enqueue_family_colonization_pod(19, 13, 19,
            country_handle, 1, expedition_handle, 1, 20, 0, error,
            &claim_transaction))
        return false;
    ++snapshot.generation;
    snapshot.transactions[0].transaction_id = 6;
    if (!candidate.apply_pod_snapshot(snapshot, error)) return false;
    if (candidate.transaction_status_pod(claim_transaction) != PLANNED ||
            candidate.transaction_status_pod(6) != ACKED)
        return fail("effect_pod_family_claim_transaction_lost");
    const PackedByteArray current = candidate.capture();
    if (candidate.apply_pod_snapshot(snapshot, error) ||
        error != "effect_pod_snapshot_generation_regression" ||
        candidate.capture() != current)
        return fail("test_only_effect_stale_snapshot_not_rejected_atomically");
    // Schema 11 is refused before any live state changes.
    PackedByteArray legacy = current;
    const int32_t legacy_schema = 11;
    std::memcpy(legacy.ptrw() + sizeof(uint32_t), &legacy_schema,
        sizeof(int32_t));
    const Dictionary rejected_legacy = candidate.restore(legacy);
    if (bool(rejected_legacy.get("ok", true)))
        return fail("effect_legacy_pod_save_not_rejected");
    if (candidate.capture() != current)
        return fail("effect_legacy_pod_reject_not_atomic");

    // Regression: worker POD snapshots must never drop a main-thread family
    // colonization builtin transaction even when the worker allocates the next
    // sequential catalog transaction ID (previously both counters collided at
    // tx.id == 6 and `apply_pod_snapshot` silently skipped the builtin, leaving
    // the expedition stuck in EXPEDITION_SETTLING forever).
    int64_t colo_tx_id = 0;
    std::string colo_err;
    if (!candidate.enqueue_family_colonization_pod(
            77, 13, 77, (uint64_t{1} << 32) | 1u, 1u,
            (uint64_t{2} << 32) | 3u, 2u, 397, 999ULL, colo_err,
            &colo_tx_id, true, 0) ||
        colo_tx_id < BUILTIN_TRANSACTION_ID_BASE) {
        return fail("effect_pod_colonization_builtin_id_not_disjoint");
    }
    auto append_catalog_fire = [&](int64_t day) {
        RuntimeEffectPodTransaction next = snapshot.transactions.back();
        RuntimeEffectPodCommand emitted = snapshot.command_arena[next.command_begin];
        ++next.transaction_id;
        ++next.fire_sequence;
        next.effective_day = day;
        next.command_begin = static_cast<uint32_t>(snapshot.command_arena.size());
        emitted.effective_day = day;
        ++emitted.idempotency_key;
        next.plan_hash = RuntimeEffectPodAuthority::calculate_plan_hash(
            next.source_instance_id, next.source_generation, day, next.fire_sequence, {emitted});
        snapshot.command_arena.push_back(emitted);
        snapshot.transactions.push_back(next);
        snapshot.instances[0].fire_sequence = next.fire_sequence;
        snapshot.instances[0].last_acked_fire_sequence = next.fire_sequence;
        ++snapshot.generation;
        snapshot.committed_day = day;
    };
    append_catalog_fire(13);
    if (!candidate.apply_pod_snapshot(snapshot, error)) return false;
    if (!candidate.has_pending_family_colonization_transactions()) {
        return fail("effect_pod_snapshot_dropped_colonization_builtin");
    }
    // A catalog row reusing a reserved builtin ID is invalid.
    RuntimeEffectPodSnapshot invalid_snapshot = snapshot;
    ++invalid_snapshot.generation;
    invalid_snapshot.transactions.back().transaction_id = colo_tx_id;
    const PackedByteArray before_collision = candidate.capture();
    if (candidate.apply_pod_snapshot(invalid_snapshot, error) ||
        error != "effect_pod_snapshot_builtin_transaction_id_collision" ||
        candidate.capture() != before_collision ||
        candidate.pod_snapshot_generation() != snapshot.generation)
        return fail("test_only_effect_reserved_collision_not_rejected_atomically");
    EffectRuntime ideology = candidate;
    ideology._instances[0].source_type = IDEOLOGY_SOURCE_TYPE;
    invalid_snapshot.transactions.back() = snapshot.transactions.back();
    ++invalid_snapshot.transactions.back().effective_day;
    const PackedByteArray before_ideology = ideology.capture();
    if (ideology.apply_pod_snapshot(invalid_snapshot, error) ||
        error != "effect_pod_snapshot_ideology_transaction_id_collision" ||
        ideology.capture() != before_ideology ||
        ideology.pod_snapshot_generation() != snapshot.generation)
        return fail("test_only_effect_different_ideology_plan_not_rejected_atomically");

    // Load an old builtin in the catalog range, then queue a pending receipt
    // and publish a new catalog fire that needs that same ID.
    append_catalog_fire(14);
    const int64_t colliding_id = snapshot.transactions.back().transaction_id;
    auto set_legacy_id = [&](EffectRuntime &runtime, int64_t current_id) {
        const int32_t index = runtime.transaction_index_for_id(current_id);
        if (index < 0) return false;
        auto &builtin = runtime._transactions[static_cast<size_t>(index)];
        runtime._transaction_ids.erase(current_id);
        builtin.id = colliding_id;
        builtin.plan_hash = runtime.persisted_plan_hash(builtin, runtime._command_arena);
        runtime._transaction_ids[colliding_id] = index;
        return true;
    };
    // Canals track only the numeric ID and must keep it when a snapshot fails.
    EffectRuntime canal = candidate;
    int64_t canal_id = 0;
    if (!canal.enqueue_canal_commit_pod(21, 13, 21, expedition_handle, 1, 1, error, &canal_id) ||
        !set_legacy_id(canal, canal_id))
        return fail("test_only_effect_legacy_canal_fixture_invalid");
    const PackedByteArray before_canal = canal.capture();
    if (canal.apply_pod_snapshot(snapshot, error) ||
        error != "effect_pod_snapshot_builtin_transaction_id_collision" ||
        canal.capture() != before_canal)
        return fail("test_only_effect_canal_collision_not_rejected_atomically");
    if (!set_legacy_id(candidate, colo_tx_id)) return fail("effect_pod_colonization_lookup_failed");
    const PackedByteArray old_save = candidate.capture();
    if (!bool(candidate.restore(old_save).get("ok", false)) || candidate.capture() != old_save)
        return fail("test_only_effect_old_builtin_save_roundtrip_failed");
    for (bool awaiting_claim : {true, false}) {
        EffectRuntime projection = candidate;
        Transaction &awaiting = projection._transactions[projection.transaction_index_for_id(colliding_id)];
        const uint32_t claim_bit = adapter_ack_bit_for(*projection.command_at(awaiting, 0));
        const uint32_t settle_bit = adapter_ack_bit_for(*projection.command_at(awaiting, 1));
        if (!awaiting_claim) projection.acknowledge_native_domain(awaiting, claim_bit);
        const int64_t request_id = awaiting_claim ? 101 : 102;
        const uint32_t domain_bit = awaiting_claim ? claim_bit : settle_bit;
        auto &requests = awaiting_claim ? projection._native_country_request_ids
                                        : projection._native_economy_request_ids;
        auto &bindings = awaiting_claim ? projection._native_country_ack_bindings
                                        : projection._native_economy_ack_bindings;
        auto &bound_ids = awaiting_claim ? projection._native_country_bound_transaction_ids
                                         : projection._native_economy_bound_transaction_ids;
        requests.push_back(request_id);
        bindings.push_back({colliding_id, 0, 1, domain_bit});
        bound_ids.insert(colliding_id);
        awaiting.status = PREFLIGHTED;
        if (!projection.apply_pod_snapshot(snapshot, error)) return false;
        if (!projection.has_pending_family_colonization_transactions())
            return fail("effect_pod_snapshot_dropped_colliding_colonization");

        int64_t resolved_id = 0;
        const int32_t status = projection.family_colonization_transaction_status_pod(
            colliding_id, 77, 2u, 999ULL, &resolved_id);
        if (status != PREFLIGHTED || resolved_id < BUILTIN_TRANSACTION_ID_BASE ||
            projection.transaction_status_pod(colliding_id) != ACKED ||
            !projection.family_colonization_includes_claim(resolved_id) ||
            bindings.size() != 1 || bindings[0].transaction_id != resolved_id ||
            bindings[0].request_begin != 0 || bindings[0].request_count != 1 ||
            bindings[0].domain_bit != domain_bit ||
            requests.size() != 1 || requests[0] != request_id ||
            bound_ids.count(resolved_id) != 1 || bound_ids.count(colliding_id) != 0)
            return fail("effect_pod_snapshot_colonization_remap_invalid");
        Transaction &recipient = projection._transactions[
            projection.transaction_index_for_id(bindings[0].transaction_id)];
        projection.acknowledge_native_domain(recipient, bindings[0].domain_bit);
        if (recipient.status != (awaiting_claim ? COMMITTED : ACKED))
            return fail("test_only_effect_remapped_receipt_wrong_status");

        const PackedByteArray remapped_save = projection.capture();
        if (!bool(projection.restore(remapped_save).get("ok", false)) ||
            projection.capture() != remapped_save)
            return fail("test_only_effect_remapped_builtin_save_roundtrip_failed");
    }

    // Repeated catalog IDs name two distinct rows and cannot be remapped.
    invalid_snapshot = snapshot;
    invalid_snapshot.transactions.back().transaction_id = invalid_snapshot.transactions.front().transaction_id;
    const PackedByteArray before_duplicate = candidate.capture();
    const uint64_t before_generation = candidate.pod_snapshot_generation();
    if (candidate.apply_pod_snapshot(invalid_snapshot, error) ||
        error != "effect_pod_snapshot_transaction_invalid" ||
        candidate.capture() != before_duplicate ||
        candidate.pod_snapshot_generation() != before_generation)
        return fail("test_only_effect_duplicate_catalog_transaction_not_rejected_atomically");
    return true;
}

// ── M1 acceptance gate ─────────────────────────────────────────────────────
// The worker Effect POD used to derive state through its own hand-written
// switch ordered 0=level(raw) 1=fire(raw) 2=stack 3=input_revision, while this
// runtime answers 0=level*Q16 1=fire*Q16 2=input_revision(raw) 3=remaining*Q16
// 4=stack*Q16. Authored content writes thresholds in Q16 ("level >= 2" is
// 131072), so the mismatch made every state-gated card permanently false on
// the worker and true here - a silent split brain, not a crash. Nothing caught
// it because nothing compared the two.
//
// This test walks the full input matrix through both implementations and
// requires bit-identical answers, then pins the POD's capability ceilings to be
// no narrower than this runtime's. That second check is what the catalog-wide
// POD validator needed: one card above the ceiling rejects the entire catalog,
// which costs the whole twelve-domain authority graph, not just that card.
bool EffectRuntime::pod_state_parity_self_test(std::string &error) const {
    auto fail = [&](const std::string &reason) { error = reason; return false; };

    if (RuntimeEffectPodAuthority::MAX_STATE_ID < STATE_LATCHED)
        return fail("effect_pod_state_ceiling_below_main_thread");
    // OWN_TERRITORY is the widest selector kind the main thread resolves. The
    // POD forwards whatever the main thread resolved, so it must not be
    // narrower. Derived from SELECTOR_MAX_KIND instead of a hand-copied 11:
    // adding a kind used to require remembering this line, and forgetting it
    // rejects the *entire* POD catalog (one card above the ceiling poisons
    // all of them), which is how the 7/3 regression shipped.
    if (RuntimeEffectPodAuthority::MAX_SELECTOR_KIND < SELECTOR_MAX_KIND)
        return fail("effect_pod_selector_ceiling_below_main_thread");

    // state_value() reads _current_day through a const method, so evaluate the
    // main-thread answers on a copy that is pinned to the day under test.
    const int64_t day = 1000;
    EffectRuntime main_thread = *this;
    main_thread._current_day = day;

    const int32_t levels[] = {0, 1, 2, 7};
    const uint64_t fires[] = {0, 1, 5};
    const int32_t stacks[] = {0, 1, 3, 9};
    const int64_t expires[] = {-1, 0, 2, 30};
    for (const int32_t level : levels) {
        for (const uint64_t fire : fires) {
            for (const int32_t stack : stacks) {
                for (const int64_t expiry : expires) {
                    const int64_t revision = 7 + stack;
                    Instance instance;
                    instance.level = level;
                    instance.fire_sequence = fire;
                    instance.stack_count = stack;
                    instance.input_revision = revision;
                    instance.expires_day = expiry;
                    // Set the latch on both sides: if the worker's switch is
                    // missing the STATE_LATCHED case it answers 0 here while the
                    // main thread answers Q16_ONE, and the mismatch surfaces as
                    // a named failure instead of a card that behaves differently
                    // on the two authorities.
                    instance.latched = 1;
                    RuntimeEffectPodInstance pod_instance;
                    pod_instance.level = level;
                    pod_instance.fire_sequence = fire;
                    pod_instance.stack_count = stack;
                    pod_instance.input_revision = revision;
                    pod_instance.expires_day = expiry;
                    pod_instance.latched = 1;
                    for (int32_t id = 0;
                         id <= RuntimeEffectPodAuthority::MAX_STATE_ID; ++id) {
                        const int64_t main_value =
                            main_thread.state_value(instance, id);
                        const int64_t pod_value =
                            RuntimeEffectPodAuthority::state_value(
                                pod_instance, id, day);
                        if (main_value == pod_value) continue;
                        return fail("effect_pod_state_parity_mismatch id=" +
                            std::to_string(id) + " level=" +
                            std::to_string(level) + " fire=" +
                            std::to_string(fire) + " stack=" +
                            std::to_string(stack) + " expires=" +
                            std::to_string(expiry) + " main=" +
                            std::to_string(main_value) + " pod=" +
                            std::to_string(pod_value));
                    }
                }
            }
        }
    }

    // Ids 0/1/3/4 are Q16-scaled, id 2 is a raw token, id 5 is Q16 but strictly
    // 0 or Q16_ONE. Pinning that split explicitly means a future "unify the
    // scaling" cleanup fails loudly here instead of silently re-breaking every
    // authored threshold.
    Instance probe;
    probe.level = 3;
    probe.fire_sequence = 2;
    probe.stack_count = 5;
    probe.input_revision = 9;
    probe.expires_day = day + 4;
    probe.latched = 1;
    const int64_t expected[] = {3 * Q16_ONE, 2 * Q16_ONE, 9, 4 * Q16_ONE,
                                5 * Q16_ONE, Q16_ONE};
    for (int32_t id = 0; id <= STATE_LATCHED; ++id) {
        if (main_thread.state_value(probe, id) != expected[id])
            return fail("effect_state_id_scaling_changed id=" +
                std::to_string(id));
    }
    // And the cleared side: an unlatched instance must read 0, not "absent".
    probe.latched = 0;
    if (main_thread.state_value(probe, STATE_LATCHED) != 0)
        return fail("effect_state_latched_clear_is_not_zero");

    // Depth scaling of an emitted command must be identical on both threads.
    // main_thread's path calls the same helper, so a divergence can only come
    // from the constant "one depth unit multiplies the command by one" rule
    // changing on one side; assert the shape contract directly.
    if (RuntimeEffectPodAuthority::scaled_command_stacks(1, 4, 3) != 3 ||
        RuntimeEffectPodAuthority::scaled_command_stacks(2, 0, 8) != 2 ||
        RuntimeEffectPodAuthority::scaled_command_stacks(2, 3, 8) != 6 ||
        RuntimeEffectPodAuthority::scaled_command_stacks(5, 2, 0) != 1)
        return fail("effect_command_stack_scaling_changed");

    // Catalog hashes use the ABI 4 representation. Snapshot ABI 5 also
    // carries the frozen Modifier inputs of each planned transaction.
    if (RUNTIME_EFFECT_POD_CATALOG_ABI_VERSION != 4u ||
        RuntimeEffectPodCatalog{}.abi_version != 4u)
        return fail("test_only_effect_catalog_abi_changed");
    if (RUNTIME_EFFECT_POD_ABI_VERSION != 5u || RuntimeEffectPodSnapshot{}.abi_version != 5u)
        return fail("effect_pod_snapshot_default_abi_is_stale");
    return true;
}

uint64_t EffectRuntime::persisted_plan_hash(const Transaction &tx,
        const std::vector<Command> &arena) const {
    uint64_t hash = 1469598103934665603ULL;
    const bool builtin = tx.program_id < 0;
    if (builtin) {
        hash = fnv_value(hash, tx.id);
        hash = fnv_value(hash, tx.effective_day);
    } else {
        hash = fnv_value(hash, tx.source_instance_id);
        hash = fnv_value(hash, tx.source_generation);
        hash = fnv_value(hash, tx.program_id);
        hash = fnv_value(hash, tx.effective_day);
        if (tx.instance_transition != TRANSITION_NONE) {
            hash = fnv_value(hash, tx.instance_transition);
            hash = fnv_value(hash, tx.transition_input_revision);
            hash = fnv_value(hash, tx.transition_fire_sequence);
            hash = fnv_value(hash, tx.transition_stack_count);
        }
    }
    for (uint32_t i = 0; i < tx.command_count; ++i) {
        const Command &c = arena[static_cast<size_t>(tx.command_begin) + i];
        hash = fnv_value(hash, c.action);
        hash = fnv_value(hash, c.domain);
        hash = fnv_value(hash, c.opcode);
        hash = fnv_value(hash, c.target_handle);
        hash = fnv_value(hash, c.target_generation);
        if (!builtin) {
            hash = fnv_value(hash, c.value_q16);
            hash = fnv_value(hash, c.duration_days);
            hash = fnv_value(hash, c.stacks);
            hash = fnv_value(hash, c.command_key_id);
            hash = fnv_value(hash, c.command_definition_id);
        }
        if (tx.program_id != -2)
            for (const int64_t value : c.payload) hash = fnv_value(hash, value);
        hash = fnv_value(hash, c.idempotency_key);
        if (c.external_effect_id != 0) {
            hash = fnv_value(hash, c.external_effect_id);
            hash = fnv_value(hash, c.external_source_id);
        }
    }
    return hash;
}

PackedByteArray EffectRuntime::capture() const {
    if (!_configured) return PackedByteArray();
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC);
    append_le<int32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<int32_t>(bytes, PROTOCOL_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash);
    append_le<int64_t>(bytes, _current_day);
    append_le<int64_t>(bytes, _last_completed_day);
    append_le<int64_t>(bytes, _run_day);
    append_le<int32_t>(bytes, _run_cursor);
    append_le<int64_t>(bytes, _next_transaction_id);
    append_le<int64_t>(bytes, _acked_transaction_id);
    append_le<uint64_t>(bytes, _next_activation_sequence);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_instances.size()));
    for (const Instance &instance : _instances) {
        append_le<int64_t>(bytes, instance.id);
        append_le<uint32_t>(bytes, instance.generation);
        append_le<int32_t>(bytes, instance.program_id);
        append_le<int32_t>(bytes, instance.source_type);
        append_le<int64_t>(bytes, instance.source_id);
        append_le<uint64_t>(bytes, instance.source_handle);
        append_le<uint64_t>(bytes, instance.target_handle);
        append_le<uint32_t>(bytes, instance.target_generation);
        append_le<int32_t>(bytes, instance.level);
        append_le<int32_t>(bytes, instance.magnitude_scale_q16);
        append_le<int64_t>(bytes, instance.next_due_day);
        append_le<int64_t>(bytes, instance.input_revision);
        append_le<int64_t>(bytes, instance.last_evaluated_input_revision);
        append_le<uint64_t>(bytes, instance.fire_sequence);
        append_le<uint8_t>(bytes, instance.active);
        append_le<int32_t>(bytes, instance.source_kind);
        append_le<int32_t>(bytes, instance.target_domain);
        append_le<int32_t>(bytes, instance.operation);
        append_le<int32_t>(bytes, instance.lifecycle);
        append_le<int32_t>(bytes, instance.duration_days);
        append_le<int32_t>(bytes, instance.stack_policy);
        append_le<int32_t>(bytes, instance.max_stacks);
        append_le<int32_t>(bytes, instance.stack_count);
        append_le<int32_t>(bytes, instance.applied_stack_count);
        append_le<int32_t>(bytes, instance.priority);
        append_le<uint64_t>(bytes, instance.activation_sequence);
        append_le<int64_t>(bytes, instance.expires_day);
        append_le<uint64_t>(bytes, instance.stack_key_hash);
        append_le<uint8_t>(bytes, instance.effect_applied);
        append_le<uint8_t>(bytes, instance.retire_requested);
        append_le<int64_t>(bytes, instance.applied_input_revision);
        append_le<uint64_t>(bytes, instance.last_acked_fire_sequence);
        // Before the metric slab, not after: the slab is a variable-length tail
        // whose length is the very next field.
        append_le<uint8_t>(bytes, instance.latched);
        append_le<uint32_t>(bytes, static_cast<uint32_t>(_metric_count));
        for (int32_t metric_id = 0; metric_id < _metric_count; ++metric_id) {
            const int64_t *value = metric_ptr(instance, metric_id);
            append_le<int64_t>(bytes, value != nullptr ? *value : 0);
        }
        for (int32_t metric_id = 0; metric_id < _metric_count; ++metric_id) {
            const size_t offset = static_cast<size_t>(instance.metric_base) +
                static_cast<size_t>(metric_id);
            append_le<uint8_t>(bytes,
                offset < _metric_present.size() ? _metric_present[offset] : 0);
        }
    }
    append_le<int32_t>(bytes, _candidate_cursor);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_run_candidates.size()));
    for (const int32_t index : _run_candidates) append_le<int32_t>(bytes, index);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_transactions.size()));
    for (const Transaction &transaction : _transactions) {
        append_le<int64_t>(bytes, transaction.id);
        append_le<int64_t>(bytes, transaction.source_instance_id);
        append_le<uint32_t>(bytes, transaction.source_generation);
        append_le<int32_t>(bytes, transaction.program_id);
        append_le<int64_t>(bytes, transaction.effective_day);
        append_le<uint64_t>(bytes, transaction.plan_hash);
        append_le<uint32_t>(bytes, transaction.required_ack_mask);
        append_le<uint32_t>(bytes, transaction.received_ack_mask);
        // Native request ids are intentionally not persisted. A save taken
        // before the Modifier safe boundary must replay the transaction from
        // PLANNED so the restored runtime can submit it again idempotently.
        const int32_t persisted_status =
            transaction.status == PREFLIGHTED &&
            (_native_bound_transaction_ids.find(transaction.id) !=
                _native_bound_transaction_ids.end() ||
             _native_country_bound_transaction_ids.find(transaction.id) !=
                _native_country_bound_transaction_ids.end() ||
             _native_economy_bound_transaction_ids.find(transaction.id) !=
                _native_economy_bound_transaction_ids.end() ||
             _native_gameplay_bound_transaction_ids.find(transaction.id) !=
                _native_gameplay_bound_transaction_ids.end())
            ? PLANNED : transaction.status;
        append_le<int32_t>(bytes, persisted_status);
        append_le<int32_t>(bytes, transaction.instance_transition);
        append_le<int64_t>(bytes, transaction.transition_input_revision);
        append_le<uint64_t>(bytes, transaction.transition_fire_sequence);
        append_le<int32_t>(bytes, transaction.transition_stack_count);
        append_le<uint32_t>(bytes, transaction.command_count);
        for (uint32_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const Command *command = command_at(transaction, ordinal);
            if (command == nullptr) continue;
            append_le<int32_t>(bytes, command->action);
            append_le<int32_t>(bytes, command->domain);
            append_le<int32_t>(bytes, command->opcode);
            append_le<uint64_t>(bytes, command->target_handle);
            append_le<uint32_t>(bytes, command->target_generation);
            append_le<int64_t>(bytes, command->value_q16);
            append_le<int32_t>(bytes, command->duration_days);
            append_le<int32_t>(bytes, command->stacks);
            append_le<uint64_t>(bytes, command->idempotency_key);
            append_le<int32_t>(bytes, command->command_key_id);
            append_le<int32_t>(bytes, command->command_definition_id);
            append_le<int64_t>(bytes, command->external_effect_id);
            append_le<int64_t>(bytes, command->external_source_id);
            for (int64_t value : command->payload) append_le<int64_t>(bytes, value);
        }
    }
    append_le<uint32_t>(bytes, static_cast<uint32_t>(_external_bindings.size()));
    for (const ExternalSourceBinding &binding : _external_bindings) {
        append_le<int64_t>(bytes, binding.binding_id);
        append_le<uint32_t>(bytes, binding.generation);
        append_le<int32_t>(bytes, binding.source_type);
        append_le<int64_t>(bytes, binding.source_id);
        append_le<uint64_t>(bytes, binding.target_handle);
        append_le<uint32_t>(bytes, binding.target_generation);
        append_le<int32_t>(bytes, binding.level);
        append_le<uint8_t>(bytes, binding.location);
        append_le<uint8_t>(bytes, binding.active);
        append_le<uint64_t>(bytes, binding.template_signature);
        append_le<uint64_t>(bytes, binding.program_hash);
    }
    append_le<uint64_t>(bytes, _era_reward_player_country);
    append_le<int64_t>(bytes, _era_reward_next_plan_id);
    append_le<int64_t>(bytes, _era_reward_next_generation);
    append_le<int64_t>(bytes, _era_reward_offer.plan_id);
    append_le<int64_t>(bytes, _era_reward_offer.generation);
    append_le<int32_t>(bytes, _era_reward_offer.pool_index);
    append_le<int32_t>(bytes, _era_reward_offer.milestone_technology);
    append_le<uint64_t>(bytes, _era_reward_offer.country_handle);
    append_le<uint32_t>(bytes, _era_reward_offer.country_generation);
    append_le<int32_t>(bytes, _era_reward_offer.status);
    append_le<int32_t>(bytes, _era_reward_offer.selected_choice);
    append_le<int64_t>(bytes, _era_reward_offer.transaction_id);
    append_le<uint64_t>(bytes, _era_reward_offer.plan_hash);
    append_string(bytes, _era_reward_offer.error);
    for (const EraRewardAlternative &alternative : _era_reward_offer.alternatives) {
        append_le<int32_t>(bytes, alternative.option_index);
        append_le<int64_t>(bytes, alternative.weight);
        append_le<uint64_t>(bytes, alternative.target_handle);
        append_le<uint32_t>(bytes, alternative.target_generation);
        append_le<int32_t>(bytes, alternative.reason_count);
        append_string(bytes, alternative.reasons[0]);
        append_string(bytes, alternative.reasons[1]);
        append_string(bytes, alternative.target_summary);
    }
    append_le<uint32_t>(bytes, SAVE_END);
    PackedByteArray out;
    out.resize(bytes.size());
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}

} // namespace pk
