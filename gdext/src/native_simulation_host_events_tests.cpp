#include "native_simulation_host.h"

namespace pk {
bool NativeSimulationHost::events_day_publication_self_test(std::string &error) {
    const auto fail = [&error](const char *reason) { error = reason; return false; };
    RuntimeModifierPodCatalog modifier;
    modifier.stats.push_back({});
    modifier.terms.push_back({0, 1.0, 1.0});
    modifier.definitions.push_back({});
    modifier.definitions[0].term_count = 1;
    RuntimeTriggerPodCatalog trigger;
    trigger.catalog_hash = 991;
    if (!configure_modifier_pod(modifier, error) || !configure_trigger_pod(trigger, error)) return false;
    set_inline_daily_mode(true);
    const uint32_t mask = runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE) |
        runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT) | runtime_domain_mask(RuntimeDomainId::MODIFIER) |
        runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT) | runtime_domain_mask(RuntimeDomainId::EVENTS) |
        runtime_domain_mask(RuntimeDomainId::COMMIT);
    if (!start(RuntimeSimulationMode::ACTIVE, true, 0, 0, true, mask))
        return fail("events_host_start_failed");
    const auto capture = [&](int64_t day) {
        RuntimeEnvironmentSnapshot input;
        input.day = day;
        input.generation = static_cast<uint64_t>(day);
        input.cell_count = 1;
        input.terrain = {1};
        input.landform = {0};
        input.has_river = {0};
        input.neighbor_indices.assign(6, -1);
        return publish_environment(std::move(input), error);
    };
    // Keep an actual reader of each published Modifier frame, including the
    // bootstrap frame. No clock or injected failure decides where the day parks.
    const int64_t day = RUNTIME_SNAPSHOT_RING_SIZE;
    std::array<uint32_t, RUNTIME_SNAPSHOT_RING_SIZE> slots{};
    for (size_t i = 0; i < slots.size(); ++i) {
        if (i && (!capture(i) || !run_inline_day().committed)) return fail("events_host_seed_day_failed");
        if (!try_acquire_modifier_snapshot(UINT64_MAX, slots[i])) return fail("events_host_reader_missing");
    }
    RuntimeEventsRecord raw;
    raw.tick = day;
    raw.type = 11;
    raw.source = 1;
    raw.event_id = 71;
    if (!capture(day) || !enqueue_legacy_event_batch({raw}, day, 0, error)) return false;
    const auto first = run_inline_day();
    const uint32_t modifier_bit = runtime_domain_mask(RuntimeDomainId::MODIFIER);
    if (first.committed || !first.continuation_pending || first.completed_domain_mask != (mask & ~modifier_bit))
        return fail("events_host_missing_reservation_wait");
    const bool prematurely_published = _events_authority.snapshot().committed_day == day || _trigger_forward_sequence != 0;
    // Two later admissions: a direct Events packet and one event produced by
    // GameplayEffect. Give the latter a lower sequence to check canonical order.
    raw.event_id = 72;
    raw.type = 12;
    if (!enqueue_legacy_event_batch({raw}, day, 0, error)) return false;
    RuntimeCommandPacket gameplay{};
    gameplay.envelope.request_id = 73;
    gameplay.envelope.producer_id = 77;
    gameplay.envelope.sequence = 1;
    gameplay.envelope.requested_day = day;
    gameplay.envelope.effective_day = day;
    gameplay.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::GAMEPLAY_EFFECT);
    gameplay.envelope.opcode = 4;
    gameplay.envelope.payload_size = 80;
    gameplay.payload[0] = 5; // PUBLISH_EVENT, event domain
    gameplay.payload[4] = 4;
    gameplay.payload[8] = 13;
    gameplay.payload[12] = static_cast<uint8_t>(day);
    gameplay.payload[20] = 1; // target handle and generation
    gameplay.payload[28] = 1;
    gameplay.payload[72] = 73; // idempotency key
    RuntimeCommandPacket invalid{};
    invalid.envelope = gameplay.envelope;
    invalid.envelope.request_id = 74;
    invalid.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    invalid.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
    invalid.envelope.payload_size = 0;
    std::vector<int64_t> admitted;
    if (!enqueue_batch({invalid}, &admitted) || admitted != std::vector<int64_t>{day})
        return fail("events_host_late_admission_failed");
    const auto second = run_inline_day();
    if (second.committed || !second.continuation_pending) return fail("events_host_reader_wait_lost");
    const bool raw_planned = _events_authority.report().appended_events == 2 &&
        _events_authority.report().rejected_commands == 1;
    if (!enqueue_batch({gameplay}, &admitted) || admitted != std::vector<int64_t>{day})
        return fail("events_host_gameplay_admission_failed");
    const auto third = run_inline_day();
    if (third.committed || !third.continuation_pending) return fail("events_host_reader_wait_lost");
    for (uint32_t slot : slots) release_modifier_snapshot(slot);
    if (!run_inline_day().committed) return fail("events_host_resumed_day_failed");
    const auto &journal = _events_authority.snapshot();
    if (journal.committed_day != day || journal.generation != static_cast<uint64_t>(day) ||
        journal.events.size() != 3 || journal.events[0].type != 13 || journal.events[1].type != 11 ||
        journal.events[2].type != 12 || _trigger_forward_sequence != 3) {
        error = "events_host_late_input_or_trigger_delivery_lost: rows=" +
            std::to_string(journal.events.size()) + " forwarded=" + std::to_string(_trigger_forward_sequence);
        return false;
    }
    if (_events_pod_rejected_count.load() != 1 ||
        std::string(_events_authority.report().fallback_reason) != "events_append_header_invalid")
        return fail("events_host_malformed_packet_not_rejected_once");
    unsigned gameplay_receipts = 0;
    RuntimeCommandReceipt receipt;
    while (poll_receipt(receipt)) {
        if (receipt.request_id != gameplay.envelope.request_id) continue;
        if (receipt.code != RuntimeReceiptCode::OK || receipt.effective_day != day)
            return fail("events_host_gameplay_receipt_wrong");
        ++gameplay_receipts;
    }
    if (gameplay_receipts != 1) return fail("events_host_gameplay_receipt_count_wrong");
    if (prematurely_published) return fail("events_host_published_while_reservation_blocked");
    if (!raw_planned) return fail("events_host_late_raw_plan_missing");
    if (!capture(day + 1) || !run_inline_day().committed) return fail("events_host_trigger_day_failed");
    RuntimeTriggerSnapshot received;
    if (!_domain_authority_runner.read_trigger_snapshot(received, error)) return false;
    if (received.committed_day != day + 1 || received.source_cursor[4] != 1 ||
        received.source_cursor[1] != 3 || _trigger_forward_sequence != 3)
        return fail("events_host_trigger_consumption_day_or_count_wrong");
    return true;
}
} // namespace pk
