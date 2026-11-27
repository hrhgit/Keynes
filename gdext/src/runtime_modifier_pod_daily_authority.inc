bool RuntimeModifierPodAuthority::plan_day(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeModifierPodCommand> &commands,
        const std::vector<RuntimeModifierPodCommand> &intents,
        RuntimeModifierPodSnapshot &planned_snapshot,
        std::vector<RuntimeDomainAck> &acks,
        RuntimeModifierPodReport &report,
        std::string &error,
        const std::vector<RuntimeModifierPodAtomicBatch> *atomic_batches,
        std::vector<uint8_t> *atomic_batch_ok) {
    clear_error(error);
    _plan_ready = false;
    report = RuntimeModifierPodReport{};
    report.generation = _current.generation;
    if (!_configured) { error = "modifier_pod_not_configured"; set_error(report, error.c_str()); return false; }
    if (day < _current.committed_day) { error = "modifier_pod_day_regression"; set_error(report, error.c_str()); return false; }
    acks.clear();
    const bool same_day = day == _current.committed_day;
    struct OrderedCommand {
        RuntimeModifierPodCommand command;
        State::DeliveryId id;
        bool is_intent;
    };
    std::vector<OrderedCommand> ordered;
    ordered.reserve(commands.size() + intents.size());
    for (size_t index = 0; index < commands.size(); ++index) {
        const auto &command = commands[index];
        if (command.effective_day > day) continue;
        State::DeliveryId id{0, command.request_id, command.producer_id, command.sequence};
        if (command.request_id == 0 && command.sequence == 0) {
            // A legacy anonymous packet retains its admission order across a
            // replay. Direct POD callers supply a sealed array instead.
            id = command.submit_order != 0
                ? State::DeliveryId{1, command.submit_order, 0, 0}
                : State::DeliveryId{2, index, 0, 0};
        }
        ordered.push_back({command, id, false});
    }
    for (const auto &intent : intents) {
        RuntimeModifierPodCommand command = intent;
        command.request_id = intent.request_id != 0 ? intent.request_id : intent.source_id;
        command.producer_id = intent.producer_id;
        command.sequence = intent.sequence;
        command.input_generation = input_generation;
        ordered.push_back({command,
            {3, command.request_id, command.producer_id, command.sequence}, true});
    }
    if (intents.size() > RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "modifier_pod_ack_capacity_exceeded";
        set_error(report, error.c_str());
        _plan_ready = false;
        return false;
    }
    std::stable_sort(ordered.begin(), ordered.end(),
        [](const OrderedCommand &a, const OrderedCommand &b) {
            return RuntimeModifierPodAuthority::command_less(a.command, b.command);
        });
    const auto batch_id = [](const RuntimeModifierPodAtomicBatch &batch) -> State::DeliveryId {
        return {4, batch.request_id, batch.producer_id, batch.sequence};
    };
    if (atomic_batch_ok != nullptr) atomic_batch_ok->clear();
    if (same_day && (atomic_batches == nullptr ||
        std::all_of(atomic_batches->begin(), atomic_batches->end(), [&](const auto &batch) {
            return _current.day_receipts.count(batch_id(batch)) != 0;
        })) &&
        std::all_of(ordered.begin(), ordered.end(), [&](const OrderedCommand &item) {
            return _current.day_receipts.count(item.id) != 0;
        })) {
        for (const auto &item : ordered)
            if (item.is_intent) acks.push_back(_current.day_receipts.at(item.id));
        if (atomic_batches != nullptr && atomic_batch_ok != nullptr) {
            for (const auto &batch : *atomic_batches)
                atomic_batch_ok->push_back(
                    _current.day_receipts.at(batch_id(batch)).code == RuntimeDomainAckCode::OK);
        }
        report.reused_snapshot = true;
        report.completed = 1;
        report.state_hash = _current.state_hash;
        report.ack_count = static_cast<uint32_t>(acks.size());
        planned_snapshot = _snapshot;
        _report = report;
        _plan_ready = true;
        return true;
    }
    _next = _current;
    if (!same_day) {
        _next.day_receipts.clear();
        for (DomainState &domain : _next.domains) {
            for (size_t i = 0; i < domain.entries.size(); ++i) {
                auto &entry = domain.entries[i];
                if (entry.modifier_handle != 0 && entry.expires_day >= 0 &&
                    entry.expires_day <= day) {
                    entry.modifier_handle = 0;
                    domain.free_indices.push_back(static_cast<uint32_t>(i));
                    ++domain.version;
                    ++report.expired_entries;
                }
            }
        }
    }
    for (const auto &item : ordered) {
        const auto previous = _next.day_receipts.find(item.id);
        if (previous != _next.day_receipts.end()) {
            if (item.is_intent) acks.push_back(previous->second);
            continue;
        }
        const auto &command = item.command;
        std::string command_error;
        bool valid = validate_command(command, command_error);
        if (valid && command.input_generation != 0 &&
            command.input_generation != input_generation) {
            valid = false;
            command_error = "modifier_pod_input_generation_stale";
        }
        RuntimeDomainAck ack;
        ack.request_id = command.request_id;
        ack.transaction_id = command.request_id;
        ack.target_handle = command.entity_handle;
        ack.target_generation = command.target_generation;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        ack.effective_day = command.effective_day;
        ack.producer_id = command.producer_id;
        ack.sequence = command.sequence;
        bool changed = false;
        bool ok = false;
        if (valid) {
            if (command.opcode == COMMAND_APPLY) {
                ok = apply_command(_next, command, day, ack, changed, command_error);
            } else if (command.opcode == COMMAND_REMOVE) {
                ok = remove_entry(_next, command, day, ack, changed, command_error);
            } else {
                DomainState &domain = _next.domains[command.domain];
                size_t index = 0;
                if (!resolve_entry(domain, command.modifier_handle, index)) {
                    command_error = "modifier_pod_stale_generation";
                    ack.code = RuntimeDomainAckCode::STALE_GENERATION;
                } else {
                    auto &entry = domain.entries[index];
                    if (command.target_generation != 0 &&
                        command.target_generation != entry.target_generation) {
                        command_error = "modifier_pod_stale_generation";
                        ack.code = RuntimeDomainAckCode::STALE_GENERATION;
                    } else if (command.opcode == COMMAND_REFRESH) {
                        if (command.duration_days != -1 && command.duration_days <= 0) {
                            command_error = "modifier_pod_duration_invalid";
                        } else {
                            entry.applied_day = day;
                            entry.expires_day = command.duration_days < 0 ? -1 : day + command.duration_days;
                            ++domain.version;
                            changed = true;
                            ok = true;
                        }
                    } else if (command.opcode == COMMAND_SET_STACKS) {
                        const auto &definition = _catalog.definitions[static_cast<size_t>(entry.definition_id)];
                        if (command.stacks <= 0 || command.stacks > definition.max_stacks) {
                            command_error = "modifier_pod_stack_invalid";
                        } else {
                            entry.stacks = command.stacks;
                            ++domain.version;
                            changed = true;
                            ok = true;
                        }
                    } else {
                        entry.magnitude_q16 = command.magnitude_q16;
                        entry.value_q16 = command.magnitude_q16;
                        ++domain.version;
                        changed = true;
                        ok = true;
                    }
                }
            }
        }
        if (ok) {
            ++report.applied_commands;
            ack.code = RuntimeDomainAckCode::OK;
        } else {
            ++report.rejected_commands;
            if (ack.code == RuntimeDomainAckCode::OK)
                ack.code = command_error == "modifier_pod_stale_generation"
                    ? RuntimeDomainAckCode::STALE_GENERATION : RuntimeDomainAckCode::REJECTED;
        }
        _next.day_receipts.emplace(item.id, ack);
        // Only Effect/cross-domain intents require domain ACKs. Host command
        // receipts remain on the existing RuntimeCommandReceipt path.
        if (item.is_intent) {
            if (acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                error = "modifier_pod_ack_capacity_exceeded";
                set_error(report, error.c_str());
                _plan_ready = false;
                return false;
            }
            acks.push_back(ack);
        }
        if (changed) ++report.work_units;
        if (item.is_intent && !ok) {
            error = command_error.empty() ? "modifier_pod_intent_rejected" : command_error;
            set_error(report, error.c_str());
            _plan_ready = false;
            return false;
        }
        if (!ok && error.empty()) error = command_error;
    }
    // Atomic producer batches (worker ideology transitions): every command in
    // a batch applies, or the batch is rolled back and reported as rejected.
    // They never produce Effect ACKs and never fail the shared Modifier day.
    if (atomic_batches != nullptr) {
        for (const auto &batch : *atomic_batches) {
            const auto id = batch_id(batch);
            const auto previous = _next.day_receipts.find(id);
            if (previous != _next.day_receipts.end()) {
                if (atomic_batch_ok != nullptr)
                    atomic_batch_ok->push_back(previous->second.code == RuntimeDomainAckCode::OK);
                continue;
            }
            if (batch.request_id == 0) {
                report.rejected_commands += static_cast<uint32_t>(batch.commands.size());
                if (atomic_batch_ok != nullptr) atomic_batch_ok->push_back(0);
                continue;
            }
            auto backup = _next.domains;
            uint32_t applied = 0;
            uint32_t changed_units = 0;
            bool batch_ok = true;
            for (const auto &source : batch.commands) {
                RuntimeModifierPodCommand command = source;
                command.input_generation = input_generation;
                std::string command_error;
                RuntimeDomainAck ack;
                bool changed = false;
                bool ok = validate_command(command, command_error);
                if (ok && command.opcode == COMMAND_APPLY)
                    ok = apply_command(_next, command, day, ack, changed, command_error);
                else if (ok && command.opcode == COMMAND_REMOVE)
                    ok = remove_entry(_next, command, day, ack, changed, command_error);
                else if (ok)
                    ok = false;
                if (!ok) { batch_ok = false; break; }
                ++applied;
                if (changed) ++changed_units;
            }
            if (!batch_ok) {
                _next.domains = std::move(backup);
                report.rejected_commands += static_cast<uint32_t>(batch.commands.size());
            } else {
                report.applied_commands += applied;
                report.work_units += changed_units;
            }
            RuntimeDomainAck receipt;
            receipt.code = batch_ok ? RuntimeDomainAckCode::OK : RuntimeDomainAckCode::REJECTED;
            _next.day_receipts.emplace(id, receipt);
            if (atomic_batch_ok != nullptr)
                atomic_batch_ok->push_back(batch_ok ? 1u : 0u);
        }
    }
    for (DomainState &domain : _next.domains) rebuild_expiry_queue(domain);
    _next.generation = same_day ? _current.generation : _current.generation + 1;
    _next.committed_day = day;
    _next.state_hash = state_hash(_next);
    build_snapshot(_next, planned_snapshot);
    planned_snapshot.acks = acks;
    report.generation = _next.generation;
    report.state_hash = planned_snapshot.state_hash;
    report.ack_count = static_cast<uint32_t>(acks.size());
    report.work_units += report.expired_entries;
    report.completed = 1;
    report.preflight_ok = 1;
    _report = report;
    _plan_ready = true;
    return true;
}

bool RuntimeModifierPodAuthority::commit_day(RuntimeModifierPodSnapshot &planned_snapshot,
                                             std::string &error) {
    clear_error(error);
    if (!_plan_ready) { error = "modifier_pod_plan_missing"; return false; }
    const State &expected = _report.reused_snapshot ? _current : _next;
    if (planned_snapshot.catalog_hash != _catalog.catalog_hash ||
        planned_snapshot.generation != expected.generation ||
        planned_snapshot.committed_day != expected.committed_day ||
        planned_snapshot.state_hash != (_report.reused_snapshot ? expected.state_hash : state_hash(expected))) {
        error = "modifier_pod_snapshot_invalid";
        _plan_ready = false;
        return false;
    }
    if (!_report.reused_snapshot) {
        _current = std::move(_next);
        _snapshot = std::move(planned_snapshot);
    }
    _plan_ready = false;
    return true;
}

void RuntimeModifierPodAuthority::discard_plan() {
    _next = _current;
    _plan_ready = false;
}
