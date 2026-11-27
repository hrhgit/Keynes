namespace {
RuntimeEffectPodCatalog checkpoint_delivery_catalog(bool technology) {
    RuntimeEffectPodCatalog catalog;
    RuntimeEffectPodDefinition definition;
    definition.key_hash = 71;
    definition.instruction_count = 4;
    definition.command_count = 2;
    definition.target_domain = 2;
    catalog.definitions.push_back(definition);
    auto other = definition;
    other.key_hash = 72;
    other.target_domain = 3;
    catalog.definitions.push_back(other);
    for (int i = 0; i < 2; ++i) {
        RuntimeEffectPodCommandDefinition command;
        command.action = i == 0 ? RuntimeEffectPodAction::MODIFIER_COMMAND
                                : RuntimeEffectPodAction::PUBLISH_EVENT;
        command.domain = i == 0 ? 1 : 4;
        command.opcode = i == 0 ? 1 : 13;
        command.command_key_hash = i == 0 && technology ? 81 : 82 + i;
        catalog.commands.push_back(command);
        RuntimeEffectPodInstruction value;
        value.op = RuntimeEffectPodInstructionOp::CONST;
        value.value = 65536;
        catalog.instructions.push_back(value);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        emit.arg0 = i;
        catalog.instructions.push_back(emit);
    }
    catalog.command_native_adapters = {
        technology ? EFFECT_MODIFIER_TECHNOLOGY : EFFECT_MODIFIER_GENERIC, 0};
    return catalog;
}

bool checkpoint_delivery_setup(RuntimeEffectPodAuthority &source, bool technology,
        RuntimeEffectPodInstanceInput &input, std::string &error) {
    input.instance_id = 0x10001;
    input.generation = 1;
    input.program_id = 0;
    input.target_handle = 0;
    input.target_generation = 1;
    input.source_id = 701;
    input.source_type = 7;
    input.magnitude_scale_q16 = 2 * 65536;
    RuntimeEffectPodPlan first;
    return source.configure(checkpoint_delivery_catalog(technology), error) &&
        source.upsert_instance(input, error) && source.plan_day(1, 1, first, error) &&
        first.intents.size() == 2 && source.commit_day(first, error);
}

bool v4_checkpoint_fixture(const RuntimeEffectPodAuthority &source, uint64_t state_hash,
        uint64_t checksum, std::vector<uint8_t> &bytes, std::string &error) {
    source.serialize(bytes);
    // 该夹具仅有一笔事务。v5 在其尾部、END! 之前附加 20 字节。
    if (bytes.size() == 602) bytes.erase(bytes.end() - 32, bytes.end() - 12);
    if (bytes.size() != 582) { error = "effect_v4_fixture_layout"; return false; }
    bytes[4] = 4;
    for (size_t i = 0; i < sizeof(uint64_t); ++i)
        bytes[44 + i] = static_cast<uint8_t>(state_hash >> (8 * i));
    bytes.resize(bytes.size() - sizeof(uint64_t));
    if (mix_bytes(FNV_OFFSET, bytes.data(), bytes.size()) != checksum) {
        error = "effect_v4_fixture_bytes_changed"; return false;
    }
    append_le(bytes, checksum);
    return true;
}

// 这四份 EFP1 v4 样本的完整校验值及状态哈希取自改前写入器。
bool checkpoint_legacy_deliveries(std::string &error) {
    struct LegacyCase {
        bool technology;
        int received;
        uint64_t state_hash;
        uint64_t checksum;
    };
    const LegacyCase cases[] = {
        {false, 0, 17234183427528012702ull, 7350553031175912302ull},
        {false, 1, 30981229276394305ull, 12033293852511856855ull},
        {false, 2, 4417084045934391327ull, 1037081760976863658ull},
        {true, 0, 789227947764160962ull, 11252559877637169278ull},
    };
    for (const auto &test : cases) {
        RuntimeEffectPodAuthority source, restored;
        RuntimeEffectPodInstanceInput input;
        if (!checkpoint_delivery_setup(source, test.technology, input, error) ||
            !restored.configure(checkpoint_delivery_catalog(test.technology), error)) return false;
        for (int i = 0; i < test.received; ++i) {
            RuntimeDomainAck ack;
            ack.transaction_id = source.snapshot().transactions.front().transaction_id;
            ack.domain = RuntimeEffectPodAuthority::adapter_domain(i == 0 ?
                RuntimeEffectPodAction::MODIFIER_COMMAND : RuntimeEffectPodAction::PUBLISH_EVENT);
            ack.effective_day = 1;
            ack.target_generation = 1;
            if (!source.apply_ack(ack, error)) return false;
        }
        std::vector<uint8_t> bytes;
        if (!v4_checkpoint_fixture(source, test.state_hash, test.checksum, bytes, error)) return false;
        const uint64_t before = restored.snapshot().deterministic_state_hash;
        const bool ok = restored.restore(bytes.data(), bytes.size(), error);
        if (!test.technology && test.received == 0) {
            if (ok || error != "effect_pod_legacy_modifier_context_missing" ||
                restored.snapshot().deterministic_state_hash != before) {
                error = "effect_v4_pending_generic_must_be_refused_atomically"; return false;
            }
        } else if (!ok) {
            return false;
        } else if (test.received != 2) {
            RuntimeEffectPodPlan next;
            if (!restored.plan_day(2, 2, next, error)) return false;
            if (next.intents.size() != (test.technology ? 2u : 1u) ||
                (test.technology && std::none_of(next.intents.begin(), next.intents.end(),
                    [](const auto &intent) {
                        return (intent.reserved & 255) == EFFECT_MODIFIER_TECHNOLOGY;
                    })) || (!test.technology && next.intents.front().target_domain !=
                    static_cast<uint16_t>(RuntimeDomainId::EVENTS))) {
                error = "effect_v4_pending_wrong_commands"; return false;
            }
        }
    }
    return true;
}

RuntimeEffectPodCatalog legacy_owner_catalog(bool shared) {
    auto catalog = checkpoint_delivery_catalog(true);
    catalog.definitions[0].managed = 1;
    if (!shared) {
        catalog.definitions[1].instruction_count = 0;
        catalog.definitions[1].command_count = 0;
    }
    return catalog;
}

bool legacy_owner_pending(RuntimeEffectPodAuthority &source, bool shared, std::string &error) {
    RuntimeEffectPodInstanceInput input;
    input.instance_id = 601;
    input.generation = 1;
    input.program_id = 0;
    input.target_handle = 9;
    input.target_generation = 1;
    RuntimeEffectPodPlan first;
    if (!source.configure(legacy_owner_catalog(shared), error) || !source.upsert_instance(input, error) ||
        !source.plan_day(1, 1, first, error) || !source.commit_day(first, error)) return false;
    RuntimeDomainAck ack;
    ack.transaction_id = source.snapshot().transactions.front().transaction_id;
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    ack.effective_day = 1;
    ack.target_generation = 1;
    if (!source.apply_ack(ack, error)) return false;
    input.program_id = 1;
    return source.upsert_instance(input, error);
}

bool checkpoint_legacy_rebound_owner(std::string &error) {
    for (const bool shared : {false, true}) {
        RuntimeEffectPodAuthority source, reader;
        if (!legacy_owner_pending(source, shared, error) ||
            !reader.configure(legacy_owner_catalog(shared), error)) return false;
        const uint64_t before = reader.snapshot().deterministic_state_hash;
        const uint64_t checksum = shared ? 7235184258039675565ull : 5654307271951125251ull;
        std::vector<uint8_t> bytes;
        if (!v4_checkpoint_fixture(source, 9429535020686053334ull, checksum, bytes, error)) return false;
        const bool restored = reader.restore(bytes.data(), bytes.size(), error);
        if (shared) {
            if (restored || error != "effect_pod_legacy_transaction_program_ambiguous" ||
                reader.snapshot().deterministic_state_hash != before) {
                error = "effect_v4_ambiguous_owner_accepted";
                return false;
            }
        } else if (!restored || reader.snapshot().transactions.front().delivery_program_id != 0) {
            error = "effect_v4_unique_original_owner_lost";
            return false;
        }
    }
    return true;
}

bool checkpoint_same_generation_program_ack(std::string &error) {
    for (const bool issued_by_managed : {false, true}) {
        auto catalog = checkpoint_delivery_catalog(false);
        catalog.definitions[0].managed = issued_by_managed;
        catalog.definitions[1].managed = !issued_by_managed;
        catalog.metric_key_hashes = {51};
        std::vector<uint8_t> direct_save;
        for (const bool late_ack : {false, true}) {
            RuntimeEffectPodAuthority source, reader;
            RuntimeEffectPodInstanceInput input;
            input.instance_id = 700;
            input.generation = 1;
            input.program_id = 0;
            input.target_handle = 9;
            input.target_generation = 1;
            RuntimeEffectPodPlan first;
            if (!source.configure(catalog, error) || !source.upsert_instance(input, error) ||
                !source.set_metric(700, 1, 0, 1, 12, error) ||
                !source.plan_day(1, 1, first, error) || first.intents.size() != 2 ||
                !source.commit_day(first, error)) return false;

            input.program_id = 1;
            if (late_ack && !source.upsert_instance(input, error)) return false;
            for (const auto &intent : first.intents) {
                RuntimeDomainAck ack;
                ack.transaction_id = intent.request_id;
                ack.effective_day = intent.effective_day;
                ack.domain = intent.target_domain;
                ack.target_handle = intent.target_handle;
                ack.target_generation = intent.target_generation;
                if (!source.apply_ack(ack, error)) return false;
            }
            if (!late_ack && !source.upsert_instance(input, error)) return false;
            const auto &instance = source.snapshot().instances.front();
            const int expected_applied = issued_by_managed ? 1 : 0;
            if (instance.program_id != 1 || instance.generation != 1 ||
                instance.effect_applied != expected_applied || instance.applied_stack_count != expected_applied ||
                instance.applied_input_revision != expected_applied || instance.last_acked_fire_sequence != 1 ||
                instance.pending_transaction_id != 0) {
                error = "effect_ack_applied_lifecycle_from_replacement_program";
                return false;
            }
            std::vector<uint8_t> save;
            source.serialize(save);
            if (!reader.configure(catalog, error) || !reader.restore(save.data(), save.size(), error))
                return false;
            if (!late_ack) direct_save = save;
            if (save != direct_save ||
                reader.snapshot().deterministic_state_hash != source.snapshot().deterministic_state_hash) {
                error = "effect_program_ack_order_changed_checkpoint";
                return false;
            }
        }
    }
    return true;
}

bool checkpoint_transaction_cursor(std::string &error) {
    RuntimeEffectPodAuthority source;
    RuntimeEffectPodInstanceInput input;
    if (!checkpoint_delivery_setup(source, true, input, error)) return false;
    const auto catalog = checkpoint_delivery_catalog(true);
    std::vector<uint8_t> current_save, legacy_save;
    source.serialize(current_save);
    if (!v4_checkpoint_fixture(source, 789227947764160962ull,
            11252559877637169278ull, legacy_save, error)) return false;

    const auto with_cursor = [](std::vector<uint8_t> bytes, int64_t next) {
        constexpr size_t offset = 3 * sizeof(uint32_t) + 2 * sizeof(uint64_t);
        std::vector<uint8_t> encoded;
        append_le(encoded, next);
        std::copy(encoded.begin(), encoded.end(), bytes.begin() + offset);
        bytes.resize(bytes.size() - sizeof(uint64_t));
        append_le(bytes, mix_bytes(FNV_OFFSET, bytes.data(), bytes.size()));
        return bytes;
    };
    const int64_t retained_id = source.snapshot().transactions.front().transaction_id;
    const int64_t overflowing_id = std::numeric_limits<int64_t>::max();
    std::string failures;
    for (const auto *save : {&current_save, &legacy_save}) {
        for (const int64_t next : {int64_t{0}, retained_id,
                EFFECT_BUILTIN_TRANSACTION_ID_BASE + 1, overflowing_id}) {
            RuntimeEffectPodAuthority reader;
            if (!reader.configure(catalog, error) ||
                !reader.restore(current_save.data(), current_save.size(), error)) return false;
            const auto damaged = with_cursor(*save, next);
            const bool accepted = reader.restore(damaged.data(), damaged.size(), error);
            std::vector<uint8_t> after;
            reader.serialize(after);
            if (accepted || error != "effect_pod_transaction_cursor_invalid" || after != current_save)
                failures += " v" + std::to_string((*save)[4]) +
                    " cursor=" + std::to_string(next) + " accepted=" + std::to_string(accepted) +
                    " changed=" + std::to_string(after != current_save) + " reason=" + error;
        }
    }
    if (!failures.empty()) {
        error = "effect_checkpoint_invalid_transaction_cursor" + failures;
        return false;
    }

    // The last allocatable number can be used and saved. Later planning that
    // would allocate another number must leave that saved state intact.
    const int64_t final_id = EFFECT_BUILTIN_TRANSACTION_ID_BASE - 1;
    const auto near_limit = with_cursor(current_save, final_id);
    RuntimeEffectPodAuthority reader;
    if (!reader.configure(catalog, error) ||
        !reader.restore(near_limit.data(), near_limit.size(), error)) return false;
    ++input.instance_id;
    RuntimeEffectPodPlan plan;
    if (!reader.upsert_instance(input, error) || !reader.plan_day(2, 2, plan, error) ||
        !reader.commit_day(plan, error)) return false;
    if (reader.snapshot().transactions.back().transaction_id != final_id) {
        error = "effect_checkpoint_last_transaction_id_not_allocated";
        return false;
    }
    std::vector<uint8_t> terminal_save;
    reader.serialize(terminal_save);
    if (!reader.restore(terminal_save.data(), terminal_save.size(), error)) return false;
    ++input.instance_id;
    if (!reader.upsert_instance(input, error)) return false;
    std::vector<uint8_t> before, after;
    reader.serialize(before);
    const bool planned = reader.plan_day(3, 3, plan, error);
    reader.serialize(after);
    if (planned || error != "effect_pod_transaction_id_exhausted" || after != before) {
        error = "effect_checkpoint_exhausted_transaction_cursor_allocated";
        return false;
    }
    return true;
}

bool checkpoint_frozen_delivery_test(std::string &error) {
    RuntimeEffectPodAuthority source, restored;
    RuntimeEffectPodInstanceInput input;
    if (!checkpoint_delivery_setup(source, false, input, error)) return false;
    // 先在 0 号城市格发射，随后把同一实例登记到另一个程序、来源及强度。
    input.program_id = 1;
    input.target_handle = 9;
    input.source_id = 702;
    input.source_type = 8;
    input.magnitude_scale_q16 = 3 * 65536;
    if (!source.upsert_instance(input, error) ||
        !restored.configure(checkpoint_delivery_catalog(false), error)) return false;
    std::vector<uint8_t> bytes;
    source.serialize(bytes);
    if (!restored.restore(bytes.data(), bytes.size(), error)) return false;
    RuntimeEffectPodPlan retry;
    if (!restored.plan_day(2, 2, retry, error)) return false;
    const auto modifier = std::find_if(retry.intents.begin(), retry.intents.end(), [](const auto &intent) {
        return intent.target_domain == static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
    });
    if (modifier == retry.intents.end() || modifier->target_handle != 0 ||
        modifier->magnitude_q16 != 2 * 65536 || modifier->reserved != (2 << 8) ||
        modifier->effect_source_type != 7 || modifier->effect_source_id != 701) {
        error = "effect_checkpoint_discarded_first_delivery"; return false;
    }
    restored.discard_plan();
    const auto before = restored.snapshot().deterministic_state_hash;
    // 校验和正确，但超出目录的程序或强度一律拒绝，并保留读档前的完整快照。
    for (const size_t offset_from_end : {32u, 16u}) {
        auto damaged = bytes;
        damaged[damaged.size() - offset_from_end + 3] = 0x7f;
        damaged.resize(damaged.size() - sizeof(uint64_t));
        append_le(damaged, mix_bytes(FNV_OFFSET, damaged.data(), damaged.size()));
        if (restored.restore(damaged.data(), damaged.size(), error) ||
            error != "effect_pod_delivery_context_invalid" ||
            restored.snapshot().deterministic_state_hash != before) {
            error = "effect_checkpoint_invalid_delivery_installed"; return false;
        }
    }
    return checkpoint_legacy_deliveries(error) && checkpoint_legacy_rebound_owner(error) &&
        checkpoint_same_generation_program_ack(error) && checkpoint_transaction_cursor(error);
}
}
