#include "native_simulation_host.h"
#include "pk_log.h"

namespace pk {
bool NativeSimulationHost::effect_input_order_self_test(
        const RuntimeEffectPodCatalog &catalog, std::string &error) {
    std::string failures;
    const auto check = [&](bool ok, const std::string &label) {
        if (!ok) failures += " " + label;
    };
    const auto row = [](int64_t id) {
        RuntimeEffectPodInstanceInput input;
        input.instance_id = id;
        input.generation = 1;
        input.program_id = 0;
        input.source_handle = id;
        input.target_handle = id;
        input.target_generation = 1;
        input.next_due_day = 2;
        return input;
    };
    {
        auto limit = std::make_unique<NativeSimulationHost>();
        const int64_t last = INT64_MAX / 2;
        check(limit->try_freeze_command_inputs(last) && limit->frozen_command_day() == last,
            "last_representable_command_seal");
    }
    const uint32_t modifier = runtime_domain_mask(RuntimeDomainId::MODIFIER);
    const uint32_t climate = runtime_domain_mask(RuntimeDomainId::CLIMATE);
    const uint32_t economy = runtime_domain_mask(RuntimeDomainId::ECONOMY);
    for (const uint32_t mask : {modifier, climate, modifier | economy, modifier | economy | climate,
                                runtime_domain_mask(RuntimeDomainId::EFFECT), RUNTIME_ALL_DOMAIN_MASK}) {
        auto host = std::make_unique<NativeSimulationHost>();
        if (!host->configure_effect_pod(catalog, error)) return false;
        host->_mode.store(RuntimeSimulationMode::ACTIVE);
        host->_requested_authority_mask.store(mask);
        host->_committed_day.store(1);
        host->_command_seal.store(2);
        host->_effect_input_sealed_day.store(1);
        if (mask & climate) {
            host->_environment_day.store(1);
            for (int day = 2; day <= 4; ++day) {
                RuntimeEnvironmentSnapshot env;
                env.day = day;
                env.generation = day;
                env.cell_count = 1;
                env.terrain = {1};
                env.landform = {0};
                env.has_river = {0};
                env.neighbor_indices.assign(6, -1);
                if (!host->publish_environment(std::move(env), error)) return false;
            }
        }
        if (!host->queue_effect_pod_instance(row(71), error) || !host->try_freeze_command_inputs(2))
            return false;
        if (!host->queue_effect_pod_instance(row(73), error) ||
            !host->queue_effect_pod_metric(71, 1, 0, 1, 90, error) ||
            !host->queue_effect_pod_remove(71, 1, error)) return false;
        {
            // The worker also services callers between simulated days. Merely
            // being on that thread cannot turn an external request into a D2 consequence.
            RuntimeExecutionContext idle_worker(host.get(), mask);
            int64_t accepted_day = 0;
            auto admitted = host->admit_effect_input(accepted_day);
            check(admitted.accepted() && accepted_day == 3, "idle_worker_bypassed_day_seal");
        }
        const auto &queued = host->_effect_instance_queue;
        const auto suffix = " mask=" + std::to_string(mask) + " early/late=" +
            std::to_string(queued.front().admitted_day) + "/" + std::to_string(queued.back().admitted_day);
        check(queued.front().admitted_day == 2 && queued.back().admitted_day == 3 &&
            host->_effect_metric_queue.front().admitted_day == 3 &&
            host->_effect_remove_queue.front().admitted_day == 3, "admission" + suffix);
        if (!host->drain_effect_transport_queues(error, 2)) return false;
        const auto &first = host->_effect_pod_authority.snapshot();
        check(first.instances.size() == 1 && first.instances[0].instance_id == 71 &&
            first.instances[0].active && first.metric_values[0] == 0, "D2" + suffix);
        if (!host->drain_effect_transport_queues(error, 3)) return false;
        const auto &second = host->_effect_pod_authority.snapshot();
        check(second.instances.size() == 2 && !second.instances[0].active &&
            second.instances[1].instance_id == 73 && second.metric_values[0] == 90, "D3" + suffix);
    }
    std::vector<uint8_t> first_pending;
    for (bool interleaved : {false, true}) {
        auto host = std::make_unique<NativeSimulationHost>();
        const auto a = row(17), b = row(41);
        if (!host->configure_effect_pod(catalog, error) ||
            !host->queue_effect_pod_instance(a, error) ||
            (interleaved && !host->queue_effect_pod_instance(b, error)) ||
            !host->queue_effect_pod_remove(17, 1, error) ||
            (!interleaved && !host->queue_effect_pod_instance(b, error)) ||
            !host->queue_effect_pod_instance(a, error) ||
            !host->queue_effect_pod_remove(41, 1, error)) return false;
        const auto pending = host->encode_effect_transport();
        if (interleaved) check(pending == first_pending, "independent_retire_changed_pending_bytes");
        else first_pending = pending;
        auto cold = std::make_unique<NativeSimulationHost>();
        RuntimeSaveBundle archive;
        archive.section_mask |= RUNTIME_SAVE_SECTION_EFFECT_TRANSPORT;
        archive.effect_transport_bytes = pending;
        if (!cold->configure_effect_pod(catalog, error) ||
            !cold->restore_effect_transport(archive, cold->_effect_pod_authority, true))
            return false;
        for (auto *owner : {host.get(), cold.get()}) {
            // The last binding for 17 is still pending on both sides of a cold load.
            if (!owner->queue_effect_pod_instance(a, error)) return false;
            check(owner->encode_effect_transport() == pending, "cold_load_changed_duplicate_binding");
            if (!owner->drain_effect_transport_queues(error, 2)) return false;
            const auto &states = owner->_effect_pod_authority.snapshot().instances;
            check(states.size() == 2 && states[0].instance_id == 17 && states[0].active &&
                states[1].instance_id == 41 && !states[1].active, "binding_and_retirement_reordered");
        }
    }
    {
        auto full = std::make_unique<NativeSimulationHost>();
        if (!full->configure_effect_pod(catalog, error)) return false;
        for (size_t i = 1; i <= RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
            if (!full->queue_effect_pod_instance(row(i), error)) return false;
        }
        auto changed = row(1);
        changed.latched = 1;
        check(full->queue_effect_pod_instance(row(1), error) &&
            !full->queue_effect_pod_instance(changed, error) && error == "effect_instance_capacity_exceeded",
            "interleaving_changed_capacity_for_repeated_binding");
    }
    // The three deliveries all name the same D1 transaction. Only the
    // control receipt arrives before the D2 input boundary.
    std::vector<uint8_t> late_day_two, late_inbox;
    for (int delivery = 0; delivery < 3; ++delivery) {
        auto host = std::make_unique<NativeSimulationHost>();
        if (!host->configure_effect_pod(catalog, error)) return false;
        host->_mode.store(RuntimeSimulationMode::ACTIVE);
        auto original = row(11);
        original.next_due_day = 1;
        RuntimeDayCommit commit;
        RuntimeDomainIntent intent;
        if (!host->queue_effect_pod_instance(original, error) || !host->try_freeze_command_inputs(1) ||
            !host->execute_effect_worker_stage(1, 1, commit, error) ||
            !host->poll_effect_pod_intent(intent)) return false;
        RuntimeDomainAck retry;
        retry.transaction_id = retry.request_id = intent.request_id;
        retry.target_handle = intent.target_handle;
        retry.target_generation = intent.target_generation;
        retry.domain = intent.target_domain;
        retry.effective_day = intent.effective_day;
        retry.code = RuntimeDomainAckCode::RETRY;
        auto pending = row(12);
        pending.next_due_day = 10;
        if (!host->queue_effect_pod_instance(pending, error) ||
            !host->queue_effect_pod_metric(12, 1, 0, 1, 42, error) ||
            (delivery == 0 && !host->submit_effect_pod_ack(retry, error)) ||
            !host->try_freeze_command_inputs(2) ||
            (delivery == 1 && !host->submit_effect_pod_ack(retry, error)) ||
            !host->execute_effect_worker_stage(2, 2, commit, error)) return false;
        int resend = host->poll_effect_pod_intent(intent) ? 2 : 0;
        if (delivery == 2 && !host->submit_effect_pod_ack(retry, error)) return false;
        // Reopening an incomplete whole day must not move the cutoff either.
        if (!host->try_freeze_command_inputs(2) || !host->execute_effect_worker_stage(2, 2, commit, error))
            return false;
        if (delivery != 0) {
            std::vector<uint8_t> day_two;
            if (!host->encode_effect_pod_save(day_two, error)) return false;
            check(host->_effect_pod_authority.snapshot().transactions.front().retry_count == 0,
                "late_receipt_mutated_D2_transaction");
            const auto inbox = host->encode_effect_transport();
            if (delivery == 1) {
                late_day_two = std::move(day_two);
                late_inbox = inbox;
            } else {
                check(day_two == late_day_two && inbox == late_inbox, "late_receipt_changed_D2_save");
            }
        }
        if (!host->try_freeze_command_inputs(3) || !host->execute_effect_worker_stage(3, 3, commit, error))
            return false;
        if (host->poll_effect_pod_intent(intent)) resend = resend == 0 ? 3 : -1;
        pk::log_info("[effect-receipt] schedule=%d tx=%llu resend=D%d", delivery,
            static_cast<unsigned long long>(retry.transaction_id), resend);
        check(resend == (delivery == 0 ? 2 : 3) && intent.request_id == retry.transaction_id,
            "receipt_cutoff_schedule_" + std::to_string(delivery) + "_D" + std::to_string(resend));
    }
    {
        // A transient binding failure leaves the frozen receipt in the bounded inbox.
        auto host = std::make_unique<NativeSimulationHost>();
        auto small = catalog;
        small.max_instances = 1;
        auto original = row(11);
        original.next_due_day = 1;
        RuntimeDayCommit commit;
        RuntimeDomainIntent intent;
        if (!host->configure_effect_pod(small, error) || !host->queue_effect_pod_instance(original, error) ||
            !host->try_freeze_command_inputs(1) || !host->execute_effect_worker_stage(1, 1, commit, error) ||
            !host->poll_effect_pod_intent(intent)) return false;
        RuntimeDomainAck ok;
        ok.transaction_id = ok.request_id = intent.request_id;
        ok.target_handle = intent.target_handle;
        ok.target_generation = intent.target_generation;
        ok.domain = intent.target_domain;
        ok.effective_day = intent.effective_day;
        if (!host->submit_effect_pod_ack(ok, error) || !host->queue_effect_pod_instance(row(12), error) ||
            !host->try_freeze_command_inputs(2)) return false;
        const auto before = host->encode_effect_transport();
        check(!host->execute_effect_worker_stage(2, 2, commit, error) &&
            error == "effect_pod_instance_capacity_exhausted" && host->encode_effect_transport() == before,
            "binding_failure_lost_sealed_receipt");
    }
    {
        // A sealed D2 Country grant can already be waiting on a D1 fire.
        auto host = std::make_unique<NativeSimulationHost>();
        auto peer_catalog = catalog;
        peer_catalog.commands.front().action = RuntimeEffectPodAction::COUNTRY_COMMAND;
        peer_catalog.commands.front().domain = 1;
        if (!host->configure_effect_pod(peer_catalog, error)) return false;
        auto original = row(11);
        original.next_due_day = 1;
        original.target_handle = (uint64_t{1} << 32u) | 7;
        RuntimeDayCommit commit;
        RuntimeDomainIntent intent;
        if (!host->queue_effect_pod_instance(original, error) || !host->try_freeze_command_inputs(1) ||
            !host->execute_effect_worker_stage(1, 1, commit, error) || !host->poll_effect_pod_intent(intent) ||
            !host->try_freeze_command_inputs(2)) return false;
        host->_country_pod_catalog.technology_effect_key_hashes = {peer_catalog.definitions[0].key_hash};
        CountryPeerIntent grant;
        grant.day = 2;
        grant.request_id = 41;
        grant.technology = 0;
        grant.target_handle = original.target_handle;
        grant.effect_instance_id = original.instance_id;
        grant.effect_generation = original.generation;
        const auto waiting = host->resolve_country_technology_effect(grant);
        if (waiting.code != CountryPeerResultCode::PENDING) return false;
        host->_country_worker_intents[grant.request_id] = grant;
        host->_country_worker_results[grant.request_id] = waiting;
        RuntimeDomainAck reply;
        reply.transaction_id = reply.request_id = intent.request_id;
        reply.target_handle = intent.target_handle;
        reply.target_generation = intent.target_generation;
        reply.domain = intent.target_domain;
        reply.effective_day = intent.effective_day;
        if (!host->execute_effect_worker_stage(2, 2, commit, error) ||
            !host->submit_effect_pod_ack(reply, error) ||
            !host->execute_effect_worker_stage(2, 2, commit, error)) return false;
        check(host->resolve_pending_country_effect_peers() == 1 &&
            host->_country_worker_results.at(grant.request_id).code == CountryPeerResultCode::READY,
            "D2_country_wait_lost_prior_fire_receipt");
    }
    std::vector<uint8_t> full_queue;
    for (const bool at_tail : {true, false}) {
        auto host = std::make_unique<NativeSimulationHost>();
        host->set_inline_daily_mode(true);
        if (!host->configure_effect_pod(catalog, error) ||
            !host->start(RuntimeSimulationMode::ACTIVE, true, 1, 0, true,
                         runtime_domain_mask(RuntimeDomainId::EFFECT))) return false;
        const auto target = row(1);
        if (!at_tail && !host->queue_effect_pod_instance(target, error)) return false;
        for (size_t i = 2; i <= RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
            auto other = row(i);
            other.next_due_day = 20;
            if (!host->queue_effect_pod_instance(other, error)) return false;
        }
        if (at_tail && !host->queue_effect_pod_instance(target, error)) return false;
        auto changed = target;
        changed.next_due_day = 3;
        const bool accepted = host->queue_effect_pod_instance(changed, error);
        const std::string result = accepted ? "ok" : error;
        if (at_tail) full_queue = host->encode_effect_transport();
        else check(full_queue == host->encode_effect_transport(), "reschedule_changed_saved_order");
        if (!host->try_freeze_command_inputs(2)) return false;
        changed.next_due_day = 4;
        check(!host->queue_effect_pod_instance(changed, error) && error == "effect_instance_capacity_exceeded",
            "cross_day_reschedule_overwrote_sealed_binding");
        check(host->_effect_instance_queue.size() == RUNTIME_COMMAND_QUEUE_CAPACITY, "reschedule_used_slot");
        RuntimeDayCommit commit;
        RuntimeDomainIntent intent;
        int fired = 0;
        for (int day : {2, 3}) {
            if (!host->execute_effect_worker_stage(day, day, commit, error)) return false;
            if (host->poll_effect_pod_intent(intent) && intent.source_id == 1) fired = day;
        }
        pk::log_info("[effect-capacity] tail=%d update=%s fired=D%d", int(at_tail), result.c_str(), fired);
        check(accepted && fired == 3, "full_reschedule_" + result + "_D" + std::to_string(fired));
        host->request_stop();
    }
    std::vector<uint8_t> first_save;
    uint64_t first_hash = 0;
    std::vector<RuntimeEventsRecord> first_events;
    for (bool reverse : {false, true}) {
        auto host = std::make_unique<NativeSimulationHost>();
        auto peer_catalog = catalog;
        peer_catalog.commands.front().action = RuntimeEffectPodAction::COUNTRY_COMMAND;
        peer_catalog.commands.front().domain = 1;
        if (!host->configure_effect_pod(peer_catalog, error)) return false;
        const auto a = row(17), b = row(41);
        // Pre-existing EFP1 snapshots may have the old insertion order and
        // metric offsets. Build that state through the authority's binding API.
        if (reverse && (!host->_effect_pod_authority.upsert_instance(b, error) ||
                        !host->_effect_pod_authority.upsert_instance(a, error))) return false;
        if (!host->queue_effect_pod_instance(reverse ? b : a, error) ||
            !host->queue_effect_pod_instance(reverse ? a : b, error)) return false;
        for (int64_t id : {17, 41}) {
            if (!host->queue_effect_pod_metric(id, 1, 0, 1, id, error)) return false;
        }
        // Equal observations carry the first revision at which the value changed.
        // Reversing the transport must preserve that revision as well as the value.
        for (int revision : {reverse ? 3 : 2, reverse ? 2 : 3}) {
            if (!host->queue_effect_pod_metric(17, 1, 0, revision, 78, error)) return false;
        }
        if (reverse) {
            // Older checkpoints can retain unsorted identities and their original
            // metric slots. Compare their first plan with uninterrupted execution.
            std::vector<uint8_t> pending;
            auto cold = std::make_unique<NativeSimulationHost>();
            if (!host->drain_effect_transport_queues(error, 2) ||
                !host->encode_effect_pod_save(pending, error) ||
                !cold->configure_effect_pod(peer_catalog, error) ||
                !cold->restore_effect_pod_save(pending.data(), pending.size(), error)) return false;
            host = std::move(cold);
        }
        RuntimeDayCommit commit;
        std::vector<RuntimeCommandPacket> packets;
        if (!host->execute_effect_worker_stage(2, 1, commit, error, &packets)) return false;
        RuntimeEventsSnapshot events;
        RuntimeEventsReport report;
        std::vector<RuntimeCommandReceipt> receipts;
        if (!host->_events_authority.plan_day(2, packets, events, receipts, report, error) ||
            !report.preflight_ok || events.events.size() != 2) return false;
        const auto &snapshot = host->_effect_pod_authority.snapshot();
        std::vector<uint8_t> bytes;
        if (!host->encode_effect_pod_save(bytes, error) || snapshot.transactions.size() != 2) return false;
        const auto metric_slot = host->_effect_pod_authority.instance_index_for_id(17);
        check(metric_slot >= 0 && snapshot.metric_revisions[snapshot.instances[metric_slot].metric_base] == 2,
            "metric_revision_depends_on_arrival");
        if (!reverse) {
            first_save = bytes;
            first_hash = snapshot.deterministic_state_hash;
            first_events = events.events;
        } else {
            check(bytes == first_save && snapshot.deterministic_state_hash == first_hash,
                "registration_order_changed_EFP1_or_hash");
            for (size_t i = 0; i < events.events.size(); ++i) {
                const auto &actual = events.events[i], &expected = first_events[i];
                check(actual.entity_handle == expected.entity_handle && actual.value_i64 == expected.value_i64 &&
                    actual.event_id == expected.event_id && actual.tick == expected.tick,
                    "registration_order_changed_event_tx_for_" + std::to_string(actual.entity_handle));
            }
        }
        check(snapshot.transactions[0].source_instance_id == 17 &&
            snapshot.transactions[1].source_instance_id == 41, "transaction_ids_ignore_identity_order");
        const auto &intent = host->_effect_day_intents.front();
        RuntimeDomainAck correct;
        correct.request_id = correct.transaction_id = intent.request_id;
        correct.target_handle = intent.target_handle;
        correct.target_generation = intent.target_generation;
        correct.domain = intent.target_domain;
        correct.effective_day = intent.effective_day;
        correct.code = RuntimeDomainAckCode::OK;
        auto wrong = correct;
        wrong.target_handle += 100;
        if (!host->submit_effect_pod_ack(reverse ? correct : wrong, error) ||
            !host->submit_effect_pod_ack(reverse ? wrong : correct, error)) return false;
        check(host->drain_effect_transport_queues(error, 2), "rejected_receipt_blocked_valid_day");
        check(host->_effect_pod_authority.snapshot().transactions[0].status ==
            RuntimeEffectPodTransactionStatus::ACKED, "wrong_target_swallowed_correct_receipt");
        check(host->_effect_pod_authority.snapshot().transactions[1].received_ack_mask == 0,
            "wrong_target_changed_other_transaction");
    }
    error = failures;
    return failures.empty();
}
} // namespace pk
