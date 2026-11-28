namespace {
constexpr uint32_t EFFECT_SAVE_WITHOUT_DELIVERY_CONTEXT = 4u;

// V4 did not record the issuing program. Recover its observable behavior from
// the archived command definitions, even when the instance was already rebound.
int32_t legacy_delivery_program(const RuntimeEffectPodCatalog &catalog,
        const std::vector<RuntimeEffectPodCommand> &arena,
        const RuntimeEffectPodTransaction &tx, int32_t bound_program, std::string &error) {
    const auto first = arena.begin() + tx.command_begin;
    const auto last = first + tx.command_count;
    const bool needs_modifier = (tx.received_ack_mask &
        RuntimeEffectPodAuthority::adapter_ack_bit(RuntimeEffectPodAction::MODIFIER_COMMAND)) == 0;
    bool needs_scope = false;
    for (auto it = first; needs_modifier && it != last; ++it) {
        if (it->action != RuntimeEffectPodAction::MODIFIER_COMMAND) continue;
        const uint32_t id = it->command_definition_id;
        const int32_t adapter = id < catalog.command_native_adapters.size() ?
            catalog.command_native_adapters[id] : EFFECT_MODIFIER_GENERIC;
        if (adapter == EFFECT_MODIFIER_GENERIC || (adapter != EFFECT_MODIFIER_TECHNOLOGY &&
                it->opcode != 2 && it->value != 0)) {
            error = "effect_pod_legacy_modifier_context_missing";
            return -1;
        }
        if (adapter == EFFECT_MODIFIER_IDEOLOGY || adapter == EFFECT_MODIFIER_FAMILY_EFFECT)
            needs_scope = true;
    }
    int32_t original = -1;
    for (size_t i = 0; i < catalog.definitions.size(); ++i) {
        const auto &candidate = catalog.definitions[i];
        if (tx.transition_stack_count == 0 && !candidate.managed) continue;
        const auto zero = instance_zero_policy(candidate.target_domain);
        const bool owns_all = std::all_of(first, last, [&](const auto &command) {
            if ((!zero.handle_allowed && command.target_handle == 0) ||
                (!zero.generation_allowed && command.target_generation == 0)) return false;
            if (command.command_key_hash == 0) return candidate.behavior_id_hash != 0;
            const uint32_t id = command.command_definition_id;
            return id >= candidate.command_begin && id - candidate.command_begin < candidate.command_count;
        });
        if (!owns_all) continue;
        if (original >= 0 && (candidate.managed != catalog.definitions[original].managed ||
            (needs_scope && candidate.target_domain != catalog.definitions[original].target_domain))) {
            error = "effect_pod_legacy_transaction_program_ambiguous";
            return -1;
        }
        if (original < 0 || static_cast<int32_t>(i) == bound_program)
            original = static_cast<int32_t>(i);
    }
    if (original < 0) error = "effect_pod_legacy_transaction_program_missing";
    return original;
}
}

void RuntimeEffectPodAuthority::serialize(std::vector<uint8_t> &out) const {
    // Adapter request IDs are intentionally not persisted. Any transaction
    // that was in flight at the save barrier must be replayable after restart,
    // so native-bound PREFLIGHTED/COMMITTED states are encoded as PLANNED
    // while retaining their command arena, ACK mask, plan hash, and keys.
    State persisted = _current;
    for (auto &transaction : persisted.transactions) {
        if (transaction.status == RuntimeEffectPodTransactionStatus::PREFLIGHTED ||
            transaction.status == RuntimeEffectPodTransactionStatus::COMMITTED) {
            transaction.status = RuntimeEffectPodTransactionStatus::PLANNED;
        }
    }
    persisted.deterministic_state_hash = state_hash(persisted);
    out.clear();
    out.reserve(256 + persisted.instances.size() * 128u +
                persisted.command_arena.size() * 192u +
                persisted.transactions.size() * 120u);
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, RUNTIME_EFFECT_POD_ABI_VERSION);
    append_le<uint32_t>(out, RUNTIME_EFFECT_POD_CATALOG_VERSION);
    append_le<uint64_t>(out, _catalog.catalog_hash);
    append_le<uint64_t>(out, _catalog_revision);
    append_le<int64_t>(out, _current.next_transaction_id);
    append_le<uint64_t>(out, persisted.generation);
    append_le<uint64_t>(out, persisted.deterministic_state_hash);
    append_le<int64_t>(out, persisted.committed_day);
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.metric_values.size()));
    for (const int64_t value : persisted.metric_values) append_le<int64_t>(out, value);
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.metric_revisions.size()));
    for (const int64_t value : persisted.metric_revisions) append_le<int64_t>(out, value);
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.instances.size()));
    for (const auto &instance : persisted.instances) {
        append_le<int64_t>(out, instance.instance_id);
        append_le<uint32_t>(out, instance.generation);
        append_le<int32_t>(out, instance.program_id);
        append_le<int32_t>(out, instance.source_type);
        append_le<int64_t>(out, instance.source_id);
        append_le<uint64_t>(out, instance.source_handle);
        append_le<uint64_t>(out, instance.target_handle);
        append_le<uint32_t>(out, instance.target_generation);
        append_le<int32_t>(out, instance.level);
        append_le<uint32_t>(out, instance.metric_base);
        append_le<int64_t>(out, instance.input_revision);
        append_le<int64_t>(out, instance.last_evaluated_input_revision);
        append_le<int64_t>(out, instance.next_due_day);
        append_le<int32_t>(out, instance.cadence_days);
        append_le<uint8_t>(out, static_cast<uint8_t>(instance.lifecycle));
        append_le<uint8_t>(out, static_cast<uint8_t>(instance.stack_policy));
        append_le<int32_t>(out, instance.stack_count);
        append_le<int32_t>(out, instance.applied_stack_count);
        append_le<int32_t>(out, instance.max_stacks);
        append_le<int64_t>(out, instance.expires_day);
        append_le<uint64_t>(out, instance.stack_key_hash);
        append_le<uint64_t>(out, instance.fire_sequence);
        append_le<int64_t>(out, instance.pending_transaction_id);
        append_le<uint64_t>(out, instance.pending_idempotency_key);
        append_le<uint64_t>(out, instance.last_acked_fire_sequence);
        append_le<int32_t>(out, instance.magnitude_scale_q16);
        append_le<uint8_t>(out, instance.effect_applied);
        append_le<int64_t>(out, instance.applied_input_revision);
        append_le<uint8_t>(out, instance.latched);
        append_le<uint8_t>(out, instance.active);
        append_le<uint8_t>(out, instance.retire_requested);
        append_le<uint8_t>(out, instance.needs_resync);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.command_arena.size()));
    for (const auto &command : persisted.command_arena) {
        append_le<uint8_t>(out, static_cast<uint8_t>(command.action));
        append_le<int32_t>(out, command.domain);
        append_le<int32_t>(out, command.opcode);
        append_le<uint64_t>(out, command.source_instance_id);
        append_le<uint32_t>(out, command.source_generation);
        append_le<uint64_t>(out, command.source_handle);
        append_le<uint64_t>(out, command.target_handle);
        append_le<uint32_t>(out, command.target_generation);
        append_le<int64_t>(out, command.value);
        append_le<int32_t>(out, command.duration_days);
        append_le<int32_t>(out, command.stacks);
        append_le<uint32_t>(out, command.command_definition_id);
        append_le<uint64_t>(out, command.command_key_hash);
        append_le<uint64_t>(out, command.definition_key_hash);
        append_le<uint64_t>(out, command.idempotency_key);
        append_le<int64_t>(out, command.effective_day);
        for (const int64_t value : command.payload) append_le<int64_t>(out, value);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(persisted.transactions.size()));
    for (const auto &transaction : persisted.transactions) {
        append_le<int64_t>(out, transaction.transaction_id);
        append_le<int64_t>(out, transaction.source_instance_id);
        append_le<uint32_t>(out, transaction.source_generation);
        append_le<int64_t>(out, transaction.effective_day);
        append_le<uint64_t>(out, transaction.plan_hash);
        append_le<uint32_t>(out, transaction.command_begin);
        append_le<uint32_t>(out, transaction.command_count);
        append_le<uint32_t>(out, transaction.required_ack_mask);
        append_le<uint32_t>(out, transaction.received_ack_mask);
        append_le<uint8_t>(out, static_cast<uint8_t>(transaction.status));
        append_le<uint8_t>(out, transaction.retry_count);
        append_le<uint8_t>(out, transaction.duplicate_ack_count);
        append_le<uint16_t>(out, transaction.last_ack_code);
        append_le<uint64_t>(out, transaction.fire_sequence);
        append_le<int64_t>(out, transaction.input_revision);
        append_le<int32_t>(out, transaction.transition_stack_count);
        append_le<int32_t>(out, transaction.delivery_program_id);
        append_le<int32_t>(out, transaction.delivery_source_type);
        append_le<int64_t>(out, transaction.delivery_source_id);
        append_le<int32_t>(out, transaction.delivery_magnitude_scale_q16);
    }
    append_le<uint32_t>(out, SAVE_END);
    const uint64_t checksum = mix_bytes(FNV_OFFSET, out.data(), out.size());
    append_le<uint64_t>(out, checksum);
}

bool RuntimeEffectPodAuthority::restore(const uint8_t *data, size_t size,
                                        std::string &error) {
    error.clear();
    if (!_configured || data == nullptr || size < 64u || size > MAX_SAVE_BYTES) {
        error = !_configured ? "effect_pod_not_configured" : "effect_pod_save_invalid";
        return false;
    }
    if (std::memcmp(data, "EFP1", 4) != 0) {
        error = "effect_pod_save_marker_invalid";
        return false;
    }
    uint64_t encoded_checksum = 0;
    size_t checksum_cursor = size - sizeof(uint64_t);
    if (!read_le(data, size, checksum_cursor, encoded_checksum) ||
        mix_bytes(FNV_OFFSET, data, size - sizeof(uint64_t)) != encoded_checksum) {
        error = "effect_pod_save_checksum_failed";
        return false;
    }
    const size_t payload_end = size - sizeof(uint64_t);
    size_t cursor = 0;
    uint32_t magic = 0, abi = 0, catalog_version = 0;
    uint64_t catalog_hash_value = 0, catalog_revision = 0;
    int64_t next_transaction_id = 0, committed_day = -1;
    uint64_t generation = 0, saved_state_hash = 0;
    if (!read_le(data, payload_end, cursor, magic) ||
        !read_le(data, payload_end, cursor, abi) ||
        !read_le(data, payload_end, cursor, catalog_version) ||
        !read_le(data, payload_end, cursor, catalog_hash_value) ||
        !read_le(data, payload_end, cursor, catalog_revision) ||
        !read_le(data, payload_end, cursor, next_transaction_id) ||
        !read_le(data, payload_end, cursor, generation) ||
        !read_le(data, payload_end, cursor, saved_state_hash) ||
        !read_le(data, payload_end, cursor, committed_day) ||
        magic != SAVE_MAGIC ||
        (abi != RUNTIME_EFFECT_POD_ABI_VERSION && abi != EFFECT_SAVE_WITHOUT_DELIVERY_CONTEXT) ||
        catalog_version != RUNTIME_EFFECT_POD_CATALOG_VERSION ||
        catalog_hash_value != _catalog.catalog_hash) {
        error = "effect_pod_save_header_invalid";
        return false;
    }
    if (next_transaction_id <= 0 || next_transaction_id > EFFECT_BUILTIN_TRANSACTION_ID_BASE) {
        error = "effect_pod_transaction_cursor_invalid";
        return false;
    }
    State restored;
    restored.generation = generation;
    restored.committed_day = committed_day;
    uint32_t count = 0;
    if (!read_count(data, payload_end, cursor, count, RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA)) {
        error = "effect_pod_metric_count_invalid"; return false;
    }
    restored.metric_values.resize(count);
    for (int64_t &value : restored.metric_values)
        if (!read_le(data, payload_end, cursor, value)) { error = "effect_pod_metric_truncated"; return false; }
    if (!read_count(data, payload_end, cursor, count, RUNTIME_EFFECT_POD_MAX_COMMAND_ARENA)) {
        error = "effect_pod_metric_revision_count_invalid"; return false;
    }
    restored.metric_revisions.resize(count);
    for (int64_t &value : restored.metric_revisions)
        if (!read_le(data, payload_end, cursor, value)) { error = "effect_pod_metric_revision_truncated"; return false; }
    if (restored.metric_revisions.size() != restored.metric_values.size()) {
        error = "effect_pod_metric_slab_shape_invalid"; return false;
    }
    if (!read_count(data, payload_end, cursor, count, _instance_capacity)) {
        error = "effect_pod_instance_count_invalid"; return false;
    }
    const size_t metric_width = _catalog.metric_key_hashes.size();
    if (static_cast<uint64_t>(count) * metric_width != restored.metric_values.size()) {
        error = "effect_pod_metric_slab_shape_invalid"; return false;
    }
    restored.instances.resize(count);
    size_t expected_base = 0;
    for (auto &instance : restored.instances) {
        if (!read_le(data,payload_end,cursor,instance.instance_id) ||
            !read_le(data,payload_end,cursor,instance.generation) ||
            !read_le(data,payload_end,cursor,instance.program_id) ||
            !read_le(data,payload_end,cursor,instance.source_type) ||
            !read_le(data,payload_end,cursor,instance.source_id) ||
            !read_le(data,payload_end,cursor,instance.source_handle) ||
            !read_le(data,payload_end,cursor,instance.target_handle) ||
            !read_le(data,payload_end,cursor,instance.target_generation) ||
            !read_le(data,payload_end,cursor,instance.level) ||
            !read_le(data,payload_end,cursor,instance.metric_base) ||
            !read_le(data,payload_end,cursor,instance.input_revision) ||
            !read_le(data,payload_end,cursor,instance.last_evaluated_input_revision) ||
            !read_le(data,payload_end,cursor,instance.next_due_day) ||
            !read_le(data,payload_end,cursor,instance.cadence_days) ||
            !read_le(data,payload_end,cursor,instance.lifecycle) ||
            !read_le(data,payload_end,cursor,instance.stack_policy) ||
            !read_le(data,payload_end,cursor,instance.stack_count) ||
            !read_le(data,payload_end,cursor,instance.applied_stack_count) ||
            !read_le(data,payload_end,cursor,instance.max_stacks) ||
            !read_le(data,payload_end,cursor,instance.expires_day) ||
            !read_le(data,payload_end,cursor,instance.stack_key_hash) ||
            !read_le(data,payload_end,cursor,instance.fire_sequence) ||
            !read_le(data,payload_end,cursor,instance.pending_transaction_id) ||
            !read_le(data,payload_end,cursor,instance.pending_idempotency_key) ||
            !read_le(data,payload_end,cursor,instance.last_acked_fire_sequence) ||
            !read_le(data,payload_end,cursor,instance.magnitude_scale_q16) ||
            !read_le(data,payload_end,cursor,instance.effect_applied) ||
            !read_le(data,payload_end,cursor,instance.applied_input_revision) ||
            !read_le(data,payload_end,cursor,instance.latched) ||
            !read_le(data,payload_end,cursor,instance.active) ||
            !read_le(data,payload_end,cursor,instance.retire_requested) ||
            !read_le(data,payload_end,cursor,instance.needs_resync) ||
            instance.instance_id <= 0 || instance.generation == 0 ||
            instance.program_id < 0 ||
            instance.program_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            (instance.target_handle == 0 && !instance_zero_policy(
                _catalog.definitions[static_cast<size_t>(
                    instance.program_id)].target_domain).handle_allowed) ||
            (instance.target_generation == 0 && !instance_zero_policy(
                _catalog.definitions[static_cast<size_t>(
                    instance.program_id)].target_domain).generation_allowed) ||
            instance.metric_base > restored.metric_values.size() ||
            instance.magnitude_scale_q16 <
                _catalog.definitions[static_cast<size_t>(
                    instance.program_id)].min_magnitude_scale_q16 ||
            instance.magnitude_scale_q16 > 65536 * 4 ||
            instance.effect_applied > 1 ||
            (_catalog.definitions[static_cast<size_t>(
                  instance.program_id)].managed != 0 &&
              (((instance.effect_applied == 0) !=
                (instance.applied_stack_count == 0)) ||
               instance.applied_input_revision < 0 ||
               instance.applied_input_revision > instance.input_revision)) ||
            instance.latched > 1) {
            error = "effect_pod_instance_truncated_or_invalid"; return false;
        }
        if (instance.metric_base != expected_base) {
            error = "effect_pod_metric_slab_shape_invalid"; return false;
        }
        expected_base += metric_width;
    }
    if (!read_count(data, payload_end, cursor, count, _command_capacity)) {
        error = "effect_pod_command_count_invalid"; return false;
    }
    restored.command_arena.resize(count);
    for (auto &command : restored.command_arena) {
        if (!read_le(data,payload_end,cursor,command.action) ||
            !read_le(data,payload_end,cursor,command.domain) ||
            !read_le(data,payload_end,cursor,command.opcode) ||
            !read_le(data,payload_end,cursor,command.source_instance_id) ||
            !read_le(data,payload_end,cursor,command.source_generation) ||
            !read_le(data,payload_end,cursor,command.source_handle) ||
            !read_le(data,payload_end,cursor,command.target_handle) ||
            !read_le(data,payload_end,cursor,command.target_generation) ||
            !read_le(data,payload_end,cursor,command.value) ||
            !read_le(data,payload_end,cursor,command.duration_days) ||
            !read_le(data,payload_end,cursor,command.stacks) ||
            !read_le(data,payload_end,cursor,command.command_definition_id) ||
            !read_le(data,payload_end,cursor,command.command_key_hash) ||
            !read_le(data,payload_end,cursor,command.definition_key_hash) ||
            !read_le(data,payload_end,cursor,command.idempotency_key) ||
            !read_le(data,payload_end,cursor,command.effective_day) ||
            !read_le(data,payload_end,cursor,command.payload[0]) ||
            !read_le(data,payload_end,cursor,command.payload[1]) ||
            !read_le(data,payload_end,cursor,command.payload[2]) ||
            !read_le(data,payload_end,cursor,command.payload[3]) ||
            !is_action_valid(command.action) ||
            command.idempotency_key == 0 ||
            command.command_definition_id >= _catalog.commands.size()) {
            error = "effect_pod_command_truncated_or_invalid"; return false;
        }
    }
    if (!read_count(data, payload_end, cursor, count, _transaction_capacity)) {
        error = "effect_pod_transaction_count_invalid"; return false;
    }
    restored.transactions.resize(count);
    int64_t previous_transaction_id = 0;
    for (auto &transaction : restored.transactions) {
        if (!read_le(data,payload_end,cursor,transaction.transaction_id) ||
            !read_le(data,payload_end,cursor,transaction.source_instance_id) ||
            !read_le(data,payload_end,cursor,transaction.source_generation) ||
            !read_le(data,payload_end,cursor,transaction.effective_day) ||
            !read_le(data,payload_end,cursor,transaction.plan_hash) ||
            !read_le(data,payload_end,cursor,transaction.command_begin) ||
            !read_le(data,payload_end,cursor,transaction.command_count) ||
            !read_le(data,payload_end,cursor,transaction.required_ack_mask) ||
            !read_le(data,payload_end,cursor,transaction.received_ack_mask) ||
            !read_le(data,payload_end,cursor,transaction.status) ||
            !read_le(data,payload_end,cursor,transaction.retry_count) ||
            !read_le(data,payload_end,cursor,transaction.duplicate_ack_count) ||
            !read_le(data,payload_end,cursor,transaction.last_ack_code) ||
            !read_le(data,payload_end,cursor,transaction.fire_sequence) ||
            !read_le(data,payload_end,cursor,transaction.input_revision) ||
            !read_le(data,payload_end,cursor,transaction.transition_stack_count) ||
            transaction.transaction_id <= 0 ||
            transaction.command_begin > restored.command_arena.size() ||
            transaction.command_count > restored.command_arena.size() - transaction.command_begin ||
            transaction.required_ack_mask == 0 ||
            (transaction.received_ack_mask & ~transaction.required_ack_mask) != 0u) {
            error = "effect_pod_transaction_truncated_or_invalid"; return false;
        }
        if (transaction.transaction_id >= next_transaction_id) {
            error = "effect_pod_transaction_cursor_invalid";
            return false;
        }
        // The writer appends transactions in ID order and compaction preserves it.
        if (transaction.transaction_id <= previous_transaction_id) {
            error = "effect_pod_transaction_order_invalid";
            return false;
        }
        previous_transaction_id = transaction.transaction_id;
        if (abi != EFFECT_SAVE_WITHOUT_DELIVERY_CONTEXT) {
            if (!read_le(data, payload_end, cursor, transaction.delivery_program_id) ||
                !read_le(data, payload_end, cursor, transaction.delivery_source_type) ||
                !read_le(data, payload_end, cursor, transaction.delivery_source_id) ||
                !read_le(data, payload_end, cursor, transaction.delivery_magnitude_scale_q16) ||
                transaction.delivery_program_id < 0 ||
                static_cast<size_t>(transaction.delivery_program_id) >= _catalog.definitions.size() ||
                transaction.delivery_magnitude_scale_q16 <
                    _catalog.definitions[transaction.delivery_program_id].min_magnitude_scale_q16 ||
                transaction.delivery_magnitude_scale_q16 > EFFECT_MAX_MAGNITUDE_Q16) {
                error = "effect_pod_delivery_context_invalid"; return false;
            }
        }
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED &&
            transaction.received_ack_mask != transaction.required_ack_mask) {
            error = "effect_pod_transaction_ack_mask_invalid"; return false;
        }
    }
    uint32_t end_marker = 0;
    if (!read_le(data, payload_end, cursor, end_marker) || end_marker != SAVE_END ||
        cursor != payload_end) {
        error = "effect_pod_save_trailing_bytes"; return false;
    }
    restored.deterministic_state_hash = state_hash(restored);
    if (restored.deterministic_state_hash != saved_state_hash) {
        error = "effect_pod_save_state_hash_failed";
        return false;
    }
    // Several historical ACKED transitions may legitimately remain for one
    // instance until the next commit compacts them (for example APPLY then
    // RETIRE). Only the latest ACKED transition must agree with the final ACKed
    // lifecycle state.
    std::unordered_map<int64_t, const RuntimeEffectPodTransaction *> latest_acked;
    for (const auto &transaction : restored.transactions) {
        if (transaction.status != RuntimeEffectPodTransactionStatus::ACKED)
            continue;
        auto it = latest_acked.find(transaction.source_instance_id);
        if (it == latest_acked.end() ||
            transaction.transaction_id > it->second->transaction_id) {
            latest_acked[transaction.source_instance_id] = &transaction;
        }
    }
    std::vector<bool> owned_commands(restored.command_arena.size(), false);
    for (auto &transaction : restored.transactions) {
        const int32_t index = [&]() {
            for (size_t i = 0; i < restored.instances.size(); ++i)
                if (restored.instances[i].instance_id == transaction.source_instance_id &&
                    restored.instances[i].generation == transaction.source_generation)
                    return static_cast<int32_t>(i);
            return -1;
        }();
        if (index < 0) { error = "effect_pod_transaction_instance_missing"; return false; }
        const auto &instance = restored.instances[static_cast<size_t>(index)];
        const bool legacy = abi == EFFECT_SAVE_WITHOUT_DELIVERY_CONTEXT;
        int32_t program = legacy ? instance.program_id : transaction.delivery_program_id;
        if (legacy && (transaction.status == RuntimeEffectPodTransactionStatus::PLANNED ||
                       transaction.status == RuntimeEffectPodTransactionStatus::PREFLIGHTED ||
                       transaction.status == RuntimeEffectPodTransactionStatus::COMMITTED)) {
            program = legacy_delivery_program(_catalog, restored.command_arena, transaction, program, error);
            if (program < 0) return false;
        }
        const auto zero = instance_zero_policy(_catalog.definitions[program].target_domain);
        for (size_t ordinal = 0; ordinal < transaction.command_count; ++ordinal) {
            const size_t offset = transaction.command_begin + ordinal;
            const auto &command = restored.command_arena[offset];
            if (owned_commands[offset] ||
                command.source_instance_id != static_cast<uint64_t>(transaction.source_instance_id) ||
                command.source_generation != transaction.source_generation ||
                (!zero.handle_allowed && command.target_handle == 0) ||
                (!zero.generation_allowed && command.target_generation == 0)) {
                error = "effect_pod_transaction_command_invalid"; return false;
            }
            owned_commands[offset] = true;
        }
        if (legacy) {
            // No missing Modifier will consume uncertain fields. Preserve the
            // remaining V4 intent fields exactly as its cold reader emitted them.
            transaction.delivery_program_id = program;
            transaction.delivery_source_type = instance.source_type;
            transaction.delivery_source_id = instance.source_id;
            transaction.delivery_magnitude_scale_q16 = std::max(instance.magnitude_scale_q16,
                _catalog.definitions[program].min_magnitude_scale_q16);
        }
        const auto latest = latest_acked.find(instance.instance_id);
        if (transaction.status == RuntimeEffectPodTransactionStatus::ACKED &&
            latest != latest_acked.end() &&
            latest->second != &transaction) {
            continue;
        }
        const auto &definition = _catalog.definitions[transaction.delivery_program_id];
        if (definition.managed != 0 &&
            transaction.status == RuntimeEffectPodTransactionStatus::ACKED &&
            ((transaction.transition_stack_count == 0 &&
              instance.effect_applied != 0) ||
             (transaction.transition_stack_count > 0 &&
              instance.effect_applied == 0))) {
            error = "effect_pod_managed_transaction_state_invalid";
            return false;
        }
    }
    if (std::find(owned_commands.begin(), owned_commands.end(), false) != owned_commands.end()) {
        error = "effect_pod_transaction_command_invalid"; return false;
    }
    if (abi == EFFECT_SAVE_WITHOUT_DELIVERY_CONTEXT)
        restored.deterministic_state_hash = state_hash(restored);
    // Install only after the complete candidate has passed every check.
    _catalog_revision = catalog_revision;
    restored.next_transaction_id = next_transaction_id;
    _current = std::move(restored);
    _next = _current;
    build_snapshot(_current, _snapshot);
    _plan_ready = false; _view_cursor = {};
    _active_plan = nullptr;
    rebuild_report();
    return true;
}
