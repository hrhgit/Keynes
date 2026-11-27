namespace {

bool mixed_ack_setup(RuntimeEffectPodAuthority &authority, int modifier_domain,
        const std::vector<RuntimeEffectPodAction> &actions, std::string &error) {
    RuntimeEffectPodCatalog catalog;
    RuntimeEffectPodDefinition definition;
    definition.key_hash = RuntimeEffectPodAuthority::hash_text("mixed_ack");
    definition.max_work = 64;
    definition.instruction_count = static_cast<uint32_t>(2 * actions.size());
    definition.command_count = static_cast<uint32_t>(actions.size());
    catalog.definitions.push_back(definition);
    for (size_t i = 0; i < actions.size(); ++i) {
        RuntimeEffectPodCommandDefinition command;
        command.action = actions[i];
        command.domain = command.action == RuntimeEffectPodAction::MODIFIER_COMMAND ? modifier_domain : 1;
        command.opcode = 1;
        command.command_key_hash = 100 + i;
        catalog.commands.push_back(command);
        RuntimeEffectPodInstruction load;
        load.op = RuntimeEffectPodInstructionOp::CONST;
        load.value = 65536;
        catalog.instructions.push_back(load);
        RuntimeEffectPodInstruction emit;
        emit.op = RuntimeEffectPodInstructionOp::EMIT_COMMAND;
        emit.arg0 = static_cast<int32_t>(i);
        catalog.instructions.push_back(emit);
    }
    RuntimeEffectPodInstanceInput instance;
    instance.instance_id = 1;
    instance.target_handle = 99;
    instance.target_generation = 3;
    instance.source_handle = 9;
    instance.program_id = 0;
    RuntimeEffectPodPlan plan;
    return authority.configure(catalog, error) && authority.upsert_instance(instance, error) &&
        authority.plan_day(0, 1, plan, error) && plan.intents.size() == actions.size() &&
        authority.commit_day(plan, error);
}

bool mixed_adapter_ack_self_test(std::string &error) {
    using Action = RuntimeEffectPodAction;
    const auto modifier = Action::MODIFIER_COMMAND;
    const auto country = Action::COUNTRY_COMMAND;
    const auto domain_for = [](Action action) {
        return static_cast<uint16_t>(action == Action::COUNTRY_COMMAND
            ? RuntimeDomainId::COUNTRY : RuntimeDomainId::MODIFIER);
    };
    RuntimeDomainAck ack;
    ack.target_handle = 99;
    ack.target_generation = 3;
    ack.effective_day = 0;
    for (auto first : {country, modifier}) {
        RuntimeEffectPodAuthority authority;
        if (!mixed_ack_setup(authority, 3, {country, modifier}, error)) return false;
        ack.transaction_id = authority.snapshot().transactions.front().transaction_id;
        ack.domain = domain_for(first);
        if (!authority.apply_ack(ack, error)) return false;
        std::vector<RuntimeDomainIntent> remaining;
        authority.append_committed_pending_intents(0, remaining);
        const auto second = first == country ? modifier : country;
        if (remaining.size() != 1 || remaining[0].target_domain != domain_for(second) ||
            remaining[0].request_id != ack.transaction_id ||
            authority.snapshot().transactions.front().received_ack_mask !=
                RuntimeEffectPodAuthority::adapter_ack_bit(first)) {
            error = "test_only_effect_mixed_ack_settled_another_adapter";
            return false;
        }
        ack.domain = domain_for(second);
        if (!authority.apply_ack(ack, error) ||
            authority.snapshot().transactions.front().status != RuntimeEffectPodTransactionStatus::ACKED)
            return false;
    }

    // The legacy subdomain 1 can designate both a Country command and a
    // country-targeted Modifier. A receipt lacking an unambiguous adapter
    // must leave the whole transaction pending.
    RuntimeEffectPodAuthority ambiguous;
    if (!mixed_ack_setup(ambiguous, 1, {country, modifier}, error)) return false;
    ack.transaction_id = ambiguous.snapshot().transactions.front().transaction_id;
    ack.domain = 1;
    const uint64_t saved = ambiguous.snapshot().deterministic_state_hash;
    if (ambiguous.apply_ack(ack, error) || error != "effect_pod_ack_command_mismatch" ||
        ambiguous.snapshot().deterministic_state_hash != saved) {
        error = "test_only_effect_ambiguous_legacy_ack_accepted";
        return false;
    }

    // Several commands for one adapter still share one bit, including when
    // the legacy caller returns the original Modifier subdomain.
    RuntimeEffectPodAuthority legacy;
    if (!mixed_ack_setup(legacy, 1, {modifier, modifier}, error)) return false;
    ack.transaction_id = legacy.snapshot().transactions.front().transaction_id;
    return legacy.apply_ack(ack, error) &&
        legacy.snapshot().transactions.front().status == RuntimeEffectPodTransactionStatus::ACKED;
}

} // namespace
