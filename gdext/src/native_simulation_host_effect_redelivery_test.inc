bool NativeSimulationHost::modifier_effect_redelivery_self_test(
        const RuntimeModifierPodCatalog &modifier_catalog, std::string *out_error) {
    std::string error;
    auto fail = [out_error](const char *reason) {
        if (out_error) *out_error = reason;
        return false;
    };
    // Compare first delivery and same-day redelivery at the published Modifier and
    // Events boundaries. A missing peer catalog leaves a real committed transaction
    // without a receipt until that peer can accept the command.
    bool deliveries_correct = true;
    bool cold_event_correct = true;
    struct Delivery { RuntimeEffectModifierAdapter adapter; bool redeliver; uint32_t count = 1; };
    for (auto [adapter, redeliver, count] : {Delivery{EFFECT_MODIFIER_TECHNOLOGY, false},
             Delivery{EFFECT_MODIFIER_TECHNOLOGY, true}, Delivery{EFFECT_MODIFIER_GENERIC, false},
             Delivery{EFFECT_MODIFIER_GENERIC, true}, Delivery{EFFECT_MODIFIER_TECHNOLOGY, true, 17}}) {
        auto host = std::make_unique<NativeSimulationHost>();
        RuntimeEffectPodCatalog effects;
        RuntimeEffectPodDefinition program;
        program.key_hash = RuntimeEffectPodAuthority::hash_text("redelivery.technology");
        program.instruction_count = count;
        program.command_count = count;
        program.target_domain = 3; // country
        effects.definitions.push_back(program);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        RuntimeEffectPodCommandDefinition tech;
        tech.action = RuntimeEffectPodAction::MODIFIER_COMMAND;
        tech.opcode = static_cast<uint16_t>(RuntimeModifierPodOpcode::APPLY);
        tech.domain = 1; // country
        tech.value_mode = RuntimeEffectPodValueMode::CONSTANT;
        tech.value = 2 * 65536;
        tech.command_key_hash = RuntimeEffectPodAuthority::hash_text("technology.modifier");
        RuntimeModifierPodCatalog peer_catalog = modifier_catalog;
        std::vector<std::pair<uint64_t, int32_t>> bindings;
        std::vector<int32_t> expected_definitions;
        for (uint32_t i = 0; i < count; ++i) {
            // More than 16 commands cross the low-nibble boundary of sequence.
            // Give each its own definition so an aliased ordinal changes the published rows.
            emit.arg0 = static_cast<int32_t>(i);
            effects.instructions.push_back(emit);
            tech.definition_key_hash = 900 + i;
            effects.commands.push_back(tech);
            effects.command_native_adapters.push_back(adapter);
            auto id = static_cast<int32_t>(peer_catalog.definitions.size());
            peer_catalog.definitions.push_back(modifier_catalog.definitions[2]);
            bindings.emplace_back(tech.definition_key_hash, id);
            expected_definitions.push_back(id);
        }
        auto configure_peer = [&] {
            if (!host->configure_modifier_pod(peer_catalog, error)) return false;
            host->set_modifier_definition_key_hashes(bindings);
            return true;
        };
        RuntimeEffectPodInstanceInput country_tech;
        country_tech.program_id = 0;
        country_tech.instance_id = (7LL << 16) | 9;
        country_tech.source_type = 0x54454348; // TECH
        country_tech.source_id = country_tech.instance_id;
        country_tech.source_handle = country_tech.target_handle = 7;
        country_tech.target_generation = 1;
        country_tech.next_due_day = 1;
        if (!host->configure_effect_pod(effects, error) ||
            !host->queue_effect_pod_instance(country_tech, error) ||
            (!redeliver && !configure_peer())) return fail(error.c_str());
        RuntimeDayCommit day;
        std::vector<RuntimeCommandPacket> packets;
        std::string peer_error;
        auto visit_effect = [&] { return host->execute_effect_worker_stage(1, 1, day, error, &packets); };
        auto visit_modifier = [&] {
            return host->execute_modifier_worker_stage(1, 1, {}, true, nullptr, peer_error, error);
        };
        if (!visit_effect() || host->_effect_day_modifier_intents.size() != count || packets.size() != count)
            return fail("redelivery_missing_first_transaction");
        const auto first = host->_effect_day_modifier_intents.front();
        if (!redeliver && adapter == EFFECT_MODIFIER_TECHNOLOGY) {
            // Save after first publication with the Modifier receipt outstanding.
            // A one-row journal makes the original idempotency key genuinely expire.
            RuntimeEventsAuthority events;
            events.reset(1);
            RuntimeEventsSnapshot journal;
            RuntimeEventsReport report;
            std::vector<RuntimeCommandReceipt> receipts;
            RuntimeDomainIntent other = first;
            other.request_id = 999;
            other.sequence++;
            other.idempotency_key++;
            auto fill = make_effect_intent_events_packet(other, 1);
            if (!events.plan_day(1, {packets.front(), fill}, journal, receipts, report, error) ||
                report.appended_events != 2 || !events.commit_day(journal, error) ||
                events.snapshot().events.front().value_i64 != 999 ||
                events.snapshot().idempotency.size() != 1) return fail("redelivery_event_not_evicted");
            auto restored = std::make_unique<NativeSimulationHost>();
            std::vector<uint8_t> effect_bytes, journal_bytes;
            if (!events.serialize(journal_bytes, error) ||
                !host->encode_effect_pod_save(effect_bytes, error) ||
                !restored->configure_effect_pod(effects, error) ||
                !restored->restore_effect_pod_save(effect_bytes.data(), effect_bytes.size(), error) ||
                !restored->_events_authority.restore(journal_bytes.data(), journal_bytes.size(), error) ||
                !restored->configure_modifier_pod(peer_catalog, error)) return fail(error.c_str());
            restored->set_modifier_definition_key_hashes(bindings);
            std::vector<RuntimeCommandPacket> replay;
            if (!restored->execute_effect_worker_stage(2, 2, day, error, &replay) ||
                restored->_effect_day_modifier_intents.size() != 1 ||
                restored->_effect_day_modifier_intents.front().request_id != first.request_id ||
                !restored->execute_modifier_worker_stage(2, 2, {}, true, nullptr, peer_error, error) ||
                restored->_effect_pod_authority.report().acked_transaction_count != 1 ||
                !restored->_events_authority.plan_day(2, replay, journal, receipts, report, error) ||
                !restored->_events_authority.commit_day(journal, error)) return fail(error.c_str());
            pk::log_info("[effect-redelivery] cold tx=%llu acked=1 packets=%zu appended=%u last=%lld",
                         static_cast<unsigned long long>(first.request_id), replay.size(), report.appended_events,
                         static_cast<long long>(restored->_events_authority.snapshot().events.back().value_i64));
            cold_event_correct = replay.empty() && report.appended_events == 0 &&
                restored->_events_authority.snapshot().events.back().value_i64 == 999;
        }
        if (redeliver) {
            if (visit_modifier() || error != "modifier_pod_not_configured" ||
                host->_effect_pod_authority.report().pending_transaction_count != 1)
                return fail("redelivery_missing_real_wait");
            // A second ENSURE can update the same generation before receipt.
            country_tech.source_type = 123;
            country_tech.source_id = 888;
            country_tech.magnitude_scale_q16 = 3 * 65536;
            if (!host->queue_effect_pod_instance(country_tech, error)) return fail(error.c_str());
            if (!configure_peer() || !visit_effect() || host->_effect_day_modifier_intents.size() != count)
                return fail("redelivery_missing_pending_command");
            const auto &again = host->_effect_day_modifier_intents.front();
            if (again.request_id != first.request_id || again.sequence != first.sequence ||
                again.idempotency_key != first.idempotency_key || packets.size() != count)
                return fail("redelivery_transaction_or_event_duplicated");
        }
        if (!visit_modifier() || host->_effect_pod_authority.report().acked_transaction_count != 1)
            return fail("redelivery_missing_peer_receipt");
        uint32_t slot;
        if (!host->reserve_modifier_day_publication(1, slot)) return fail("redelivery_reserve_failed");
        host->finish_modifier_day_publication(slot, true);
        if (!host->try_acquire_modifier_snapshot(0, slot)) return fail("redelivery_publish_failed");
        const auto snapshot = host->modifier_snapshot_buffer(slot);
        host->release_modifier_snapshot(slot);
        RuntimeEventsSnapshot journal;
        std::vector<RuntimeCommandReceipt> receipts;
        RuntimeEventsReport report;
        if (!host->_events_authority.plan_day(1, packets, journal, receipts, report, error) ||
            !host->_events_authority.commit_day(journal, error)) return fail(error.c_str());
        const auto &events = host->_events_authority.snapshot().events;
        if (events.size() != count || events.front().type != 900 ||
            events.front().value_i64 != static_cast<int64_t>(first.request_id))
            return fail("redelivery_journal_wrong");
        if (snapshot.committed_day != 1 || snapshot.entries.size() != count || snapshot.buckets.size() != 1)
            return fail("redelivery_published_rows_missing");
        std::vector<int32_t> installed;
        for (const auto &row : snapshot.entries) installed.push_back(row.definition_id);
        std::sort(installed.begin(), installed.end());
        if (installed != expected_definitions)
            return fail("redelivery_command_resolved_to_another_definition");
        const auto &entry = snapshot.entries.front();
        const auto &bucket = snapshot.buckets.front();
        pk::log_info("[effect-redelivery] adapter=%d resend=%d tx=%llu seq=%llu source=%llu magnitude_q16=%d "
                     "sum=%.1f acked=1 events=%zu", adapter, redeliver,
                     static_cast<unsigned long long>(first.request_id),
                     static_cast<unsigned long long>(first.sequence),
                     static_cast<unsigned long long>(entry.source_id), entry.magnitude_q16,
                     bucket.sum_add, events.size());
        const bool technology = adapter == EFFECT_MODIFIER_TECHNOLOGY;
        const uint64_t expected_source = technology ? 9 : (7ULL << 16) | 9;
        const int32_t expected_units = technology ? 1 : 2;
        if (entry.source_type != 0x54454348 || entry.source_id != expected_source ||
            entry.scope != 2 || entry.entity_handle != 7 || entry.magnitude_q16 != expected_units * 65536 ||
            bucket.scope_id != 7 || bucket.active_count != count || bucket.sum_add != expected_units * count)
            deliveries_correct = false;
    }
    if (!cold_event_correct) return fail("redelivery_cold_event_republished");
    if (!deliveries_correct) return fail("redelivery_published_source_or_settlement_wrong");
    return true;
}
