bool EconomyInvariantProbe::run_economy_command_revisit(bool pod_owner, std::string &error) {
    auto economy = std::make_unique<NativeEconomyRuntime>();
    auto host = std::make_unique<NativeSimulationHost>();
    auto &authority = host->_economy_pod_authority;
    economy->_cell_count = 1;
    economy->prepare_restore_candidate_scratch();
    economy->_current_day = economy->_sample_day = 1;
    economy->_last_committed_day = 1;
    economy->_signatures.resize(1);
    auto &population = economy->population_store();
    population.clear(1);
    const int slot = population.allocate_slot(0, 0);
    population.population.write_scalar(slot, 1);
    population.funds.write_scalar(slot, 80);
    const uint64_t cohort = population.handle_for_slot(slot);
    auto &market = economy->market_store();
    market.market_count = market.good_count = 1;
    market.stock.assign(1, 0);
    market.price.assign(1, 100);
    market.demand_ema.assign(1, 0);
    market.last_shortage_q16.assign(1, 0);
    market.cell_to_market.assign(1, 0);
    economy->_opening_totals.population = economy->_closing_totals.population = 1;
    economy->_opening_totals.cohort_funds = economy->_closing_totals.cohort_funds = 80;
    RuntimeEconomyLedgerState ledger;
    if (pod_owner) {
        if (!EconomyAuthorityTransfer::bind_restored_owner(*economy, authority, error)) return false;
    } else {
        economy->capture_committed_ledger_state(ledger);
        if (!authority.import_and_publish_committed_ledger(std::move(ledger), error)) return false;
    }
    host->_mode.store(RuntimeSimulationMode::ACTIVE);
    host->_requested_authority_mask.store(runtime_domain_mask(RuntimeDomainId::ECONOMY));
    host->attach_economy_production_runtime(economy.get());
    auto &ring = authority.snapshot_ring();
    // A freshly installed ledger has no cached business summary. Its sample
    // can predate the current calendar day, just as on a cold ECP2 start.
    host->_economy_pod_committed.store(true);
    host->_economy_pod_committed_day.store(0);
    host->_economy_pod_state_hash.store(authority.state_hash());
    RuntimeDayCommit first_commit;
    first_commit.completed_domain_mask = runtime_domain_mask(RuntimeDomainId::ECONOMY);
    host->publish_day(0, 1, first_commit, {});
    uint32_t previous;
    if (!ring.try_acquire_latest(0, previous)) { error = "economy_cold_summary_missing"; return false; }
    const bool populated = ring.read_buffer(previous).summary_funds == 80;
    ring.release(previous);
    if (!populated) { error = "economy_cold_summary_uninitialized"; return false; }
    RuntimeDayPlan plan;
    plan.context.day = plan.context.input_generation = 2;
    plan.context.frozen_input = {1, 2, 2, 0, 1, 0};
    const RuntimeEnvironmentSnapshot *environment = nullptr;
    std::vector<RuntimeCommandPacket> commands;
    std::vector<RuntimeCommandReceipt> receipts;
    RuntimeDayCommit commit;
    auto &progress = host->_day_progress;
    progress.day = 2;
    NativeSimulationHost::DayExecution day{plan, environment, commands, receipts, 0,
        commit, progress, progress.event_commands};
    RuntimeDomainPlan stage;
    stage.domain = RuntimeDomainId::ECONOMY;
    stage.completed = 1;
    day.remember_completed(stage);

    RuntimeEconomyPodCommand mint;
    mint.request_id = 101;
    mint.opcode = NativeEconomyRuntime::COMMAND_MINT_TO_COHORT;
    mint.target_cohort = cohort;
    mint.payload0 = 20;
    if (!host->submit_economy_pod_command(mint, error)) return false;
    economy->_epoch_active = true;
    if (!host->stage_economy(day, stage) || !stage.completed || !commit.preflight_ok ||
        host->state() == RuntimeWorkerState::FAULTED ||
        authority.pending_command_count() != 1 || authority.terminal_receipt(mint.request_id) ||
        economy->population_store().funds[slot] != 80 ||
        authority.committed_ledger_state().cohort_funds[slot] != 80) {
        error = "economy_revisit_spent_command_during_active_epoch";
        return false;
    }
    // At the next closed boundary the exact request retained above is now eligible.
    economy->_epoch_active = false;
    host->_economy_pod_committed.store(true);
    host->_economy_pod_committed_day.store(2);
    host->_economy_pod_epoch_sample_day.store(2);
    economy->_last_committed_day = economy->_sample_day = 2;
    economy->_current_day = 2;
    commit = {};
    if (!host->stage_economy(day, stage) || !stage.completed || !commit.preflight_ok ||
        host->state() == RuntimeWorkerState::FAULTED) {
        error = "economy_revisit_closed_stage_failed"; return false;
    }
    const auto *terminal = authority.terminal_receipt(mint.request_id);
    if (!terminal || terminal->code != RuntimeEconomyCommandReceiptCode::Committed ||
        authority.pending_command_count() != 0 || economy->population_store().funds[slot] != 100 ||
        authority.committed_ledger_state().cohort_funds[slot] != 100) {
        error = "economy_revisit_closed_command_missing"; return false;
    }
    host->set_economy_execution_mode(EconomyExecutionMode::ACTIVE_WITH_PARITY);
    host->_economy_pod_generation.store(23);
    host->_economy_pod_operation_gate_mask.store(7);
    if (!host->execute_economy_worker_stage(2, 2, 1, 0, 2, error)) return false;
    if (!host->_economy_replay_committed.load() || host->_economy_pod_generation.load() != 23 ||
        !host->_economy_pod_committed.load() || host->_economy_pod_committed_day.load() != 2 ||
        host->_economy_pod_operation_gate_mask.load() != 7 || !authority.terminal_receipt(mint.request_id)) {
        error = "economy_parity_overwrote_production"; return false;
    }
    uint32_t index;
    if (ring.try_acquire_latest(1, index)) {
        ring.release(index);
        error = "economy_revisit_partial_day_published"; return false;
    }
    host->publish_day(1, 2, commit, receipts);
    if (!ring.try_acquire_latest(1, index)) {
        error = "economy_revisit_final_frame_unavailable"; return false;
    }
    const auto &payload = ring.read_buffer(index);
    const bool final = payload.header.committed && payload.header.committed_day == 2 &&
        payload.header.generation == 2 && payload.header.state_hash == authority.state_hash() &&
        payload.header.state_hash == host->_economy_pod_state_hash.load() &&
        payload.summary_funds == 100 && payload.summary_population == 1 && payload.summary_markets == 1 &&
        payload.summary_cohorts == 1 && payload.money_error == 0 && payload.header.operation_gate_mask == 7;
    ring.release(index);
    if (!final) { error = "economy_revisit_final_hash_summary_mismatch"; return false; }
    // A calendar day without a new economic epoch retains the post-command summary.
    host->publish_day(2, 3, commit, receipts);
    if (!ring.try_acquire_latest(2, index)) {
        error = "economy_idle_frame_missing"; return false;
    }
    const auto &idle = ring.read_buffer(index);
    const bool retained = idle.header.generation == 3 && idle.header.committed_day == 2 &&
        idle.summary_funds == 100 && idle.header.state_hash == authority.state_hash();
    ring.release(index);
    if (!retained) { error = "economy_idle_frame_lost_settled_command"; return false; }
    // The next installed ledger also samples day 2, but contains a new generation.
    ++economy->_committed_generation;
    economy->population_store().funds.write_scalar(slot, 120);
    economy->_closing_totals.cohort_funds = 120;
    if (pod_owner) {
        economy->flush_formula_owned_domain_mirrors();
        if (!authority.publish_owned_committed_mirror(economy->committed_generation(), 2, error)) return false;
    } else {
        economy->capture_committed_ledger_state(ledger);
        if (!authority.import_and_publish_committed_ledger(std::move(ledger), error)) return false;
    }
    host->publish_day(3, 4, commit, receipts);
    if (!ring.try_acquire_latest(3, index)) { error = "economy_new_ledger_not_published"; return false; }
    const bool refreshed = ring.read_buffer(index).summary_funds == 120;
    ring.release(index);
    if (!refreshed) error = "economy_summary_from_old_ledger";
    return refreshed;
}
