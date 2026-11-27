#include "world_ext.h"
#include "runtime_day_tail.h"
#include "economy_api.h"
#include "modifier_api.h"
#include "country_ai_core.h"
#include "country_runtime.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "economy_runtime.h"
#include "native_simulation_host.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <vector>

namespace pk {

using namespace godot;

namespace {
NativeCountryRuntime *country_runtime_from(void *opaque) {
    return static_cast<NativeCountryRuntime *>(opaque);
}

const NativeCountryRuntime *country_runtime_from(const void *opaque) {
    return static_cast<const NativeCountryRuntime *>(opaque);
}

Dictionary country_unavailable() {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = "country_runtime_unavailable";
    return out;
}

NativeCountryRuntime::TaxRead published_tax_values(const ModifierReadView &modifier, const EconomyFrozenTaxView *frozen) {
    NativeCountryRuntime::TaxRead read;
    if (frozen) {
        read.policy_version = frozen->policy_version;
        read.frozen_rate = [frozen](uint64_t handle, int32_t cell, int32_t kind, int32_t item,
                                    int32_t &rate, int32_t &mode) {
            return frozen->lookup(handle, cell, kind, item, rate, mode);
        };
    } else {
        read.modifier_value = [&modifier](uint64_t handle, const std::string &key, int32_t base) {
            return modifier.effective_value(ModifierApi::COUNTRY, modifier.stat_id_for_key(key), handle, 0, base);
        };
    }
    return read;
}

} // namespace

Dictionary DCWorldExt::bootstrap_country(const Dictionary &packet,
                                         const PackedByteArray &is_water) {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_runtime_from(_country_runtime)->bootstrap(packet, is_water);
    if (static_cast<bool>(out.get("ok", false)) &&
        String(out.get("runtime_mode", "ACTIVE")) == "ACTIVE") {
        NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
        const auto publish_start = std::chrono::steady_clock::now();
        const int slot = component_id(StringName("cell_country_slot"));
        if (slot >= 0) {
            write_i32_range(slot, 0, runtime->cell_country_snapshot());
            _flush_slot_to_map(slot);
            const double publish_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - publish_start).count();
            runtime->mark_slot_publication(true, publish_ms);
            out["published_to_slot"] = true;
            out["slot_publish_ms"] = publish_ms;
        } else {
            runtime->mark_slot_publication(false, 0.0, "country_slot_unavailable");
            out["published_to_slot"] = false;
            out["publish_reason"] = "country_slot_unavailable";
        }
    }
    return out;
}


namespace {

const char *country_command_receipt_code_name(
        CountryCommandReceiptCode code) {
    switch (code) {
    case CountryCommandReceiptCode::ADMISSION_REJECTED:
        return "AdmissionRejected";
    case CountryCommandReceiptCode::ACCEPTED:
        return "Accepted";
    case CountryCommandReceiptCode::COMMITTED:
        return "Committed";
    case CountryCommandReceiptCode::REJECTED_AT_EXECUTION:
        return "RejectedAtExecution";
    }
    return "Unknown";
}

} // namespace

Dictionary DCWorldExt::poll_country_command_receipts(
        int64_t after_publication, int limit) {
    Dictionary out;
    if (_runtime_host == nullptr) {
        out["ok"] = false;
        out["code"] = "runtime_worker_not_started";
        return out;
    }
    std::vector<CountryCommandReceipt> receipts;
    const int64_t cursor = std::max<int64_t>(0, after_publication);
    _runtime_host->poll_country_command_publications(
        static_cast<uint64_t>(cursor),
        static_cast<uint32_t>(std::clamp(limit, 0, 4096)), receipts);
    Array rows;
    int64_t publication = cursor;
    for (const CountryCommandReceipt &receipt : receipts) {
        Dictionary row;
        row["request_id"] = static_cast<int64_t>(receipt.request_id);
        row["publication_sequence"] = ++publication;
        row["producer_id"] = static_cast<int>(receipt.producer_id);
        row["sequence"] = static_cast<int64_t>(receipt.sequence);
        row["effective_day"] = receipt.effective_day;
        row["generation"] = static_cast<int64_t>(receipt.generation);
        row["code"] = static_cast<int>(receipt.code);
        row["status"] = country_command_receipt_code_name(receipt.code);
        row["reason"] = String(receipt.reason.c_str());
        rows.push_back(row);
    }
    out["ok"] = true;
    out["available"] = !receipts.empty();
    out["receipts"] = rows;
    out["count"] = rows.size();
    out["last_publication_sequence"] = publication;
    return out;
}

bool DCWorldExt::runtime_country_host_receipt_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_command_receipt_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country receipt self-test] ") + String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_country_host_rejection_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_peer_rejection_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country rejection self-test] ") + String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_country_shadow_parity_self_test() const {
    if (_runtime_host == nullptr) return false;
    std::string error;
    const bool ok = _runtime_host->country_shadow_parity_self_test(error);
    if (!ok) {
        UtilityFunctions::printerr(
            String("[country shadow parity self-test] ") + String(error.c_str()));
    }
    return ok;
}

#include "world_ext_country_section_peer_transport.inc"
#include "world_ext_country_section_worker_read_views.inc"
#include "world_ext_country_section_worker_handoff.inc"
#include "world_ext_country_section_authority_service.inc"
NativeCountryRuntime *DCWorldExt::country_query_runtime() const {
    auto *source = country_runtime_from(_country_runtime);
    if (source == nullptr || _runtime_host == nullptr)
        return source;
    // Prefer any worker-published Country snapshot even after FAULTED revoked
    // the authority grant. Falling back to the frozen sync store on revoke
    // resets the tech UI to bootstrap gen=1 / starter TP stock.
    const auto &tail = _runtime_display_commit.day_tail;
    const auto snapshot = tail && tail->country.snapshot
        ? tail->country.snapshot : _runtime_host->country_asset_snapshot();
    if (!snapshot) return source;
    auto *view = country_query_runtime_from_snapshot(snapshot);
    if (!view) view = country_runtime_from(_country_query_runtime);
    view->mirror_era_reward_reference(source->era_reward_reference_pod());
    return view;
}

NativeCountryRuntime *DCWorldExt::country_query_runtime_from_snapshot(
        const std::shared_ptr<const RuntimeCountryPodSnapshot> &snapshot) const {
    auto *source = country_runtime_from(_country_runtime);
    if (!source || !snapshot) return nullptr;
    if (_country_query_runtime == nullptr)
        _country_query_runtime = new NativeCountryRuntime(*source);
    auto *view = country_runtime_from(_country_query_runtime);
    if (_country_query_snapshot != snapshot) {
        // Only advance the cursor when the replica installs successfully.
        // A rejected shape must retry on the next read instead of locking the
        // UI onto the pre-ACTIVE sync copy forever.
        if (view->apply_committed_read_snapshot(*snapshot)) {
            _country_query_snapshot = snapshot;
            static int s_apply_ok_left = 8;
            if (s_apply_ok_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ui-diag/query] apply ok gen=%d day=%d "
                    "view_gen=%d progress_total=%d pending_words=%d",
                    static_cast<int64_t>(snapshot->generation),
                    snapshot->committed_day,
                    static_cast<int64_t>(view->report().get("generation", 0)),
                    snapshot->research_progress_total.empty()
                        ? 0
                        : static_cast<int64_t>(
                              snapshot->research_progress_total[0]),
                    static_cast<int64_t>(
                        snapshot->country_pending_technologies.size())));
            }
        } else {
            static int s_apply_fail_left = 12;
            if (s_apply_fail_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ui-diag/query] apply FAILED gen=%d day=%d "
                    "countries=%d cells=%d techs=%d — UI stays on prior replica",
                    static_cast<int64_t>(snapshot->generation),
                    snapshot->committed_day,
                    static_cast<int64_t>(snapshot->country_count),
                    static_cast<int64_t>(snapshot->cell_count),
                    static_cast<int64_t>(snapshot->technology_count)));
            }
            return nullptr;
        }
    }
    return view;
}

Dictionary DCWorldExt::get_country_cell_summary(int cell_idx) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->cell_summary(cell_idx);
}

Dictionary DCWorldExt::get_country_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->country_snapshot(handle);
}

Dictionary DCWorldExt::get_country_political_regime_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->political_regime_snapshot(handle);
}

Dictionary DCWorldExt::get_country_treasury_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->treasury_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->research_snapshot(handle);
}

Dictionary DCWorldExt::get_country_research_signal_snapshot(int64_t handle) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->research_signal_snapshot(handle);
}

Dictionary DCWorldExt::consume_country_visual_era_dirty_slots() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_query_runtime()->consume_visual_era_dirty_slots();
}

bool DCWorldExt::has_completed_country_technology(
        int64_t handle, int32_t technology_id) const {
    return _country_runtime != nullptr &&
        country_query_runtime()->has_completed_technology(
            handle, technology_id);
}

NativeCountryRuntime *DCWorldExt::country_query_runtime_for_tax() const {
    if (!_runtime_host || _runtime_host->control_state().mode == RuntimeSimulationMode::OFF)
        return country_runtime_from(_country_runtime);
    return country_query_runtime();
}

const NativeCountryRuntime *DCWorldExt::published_tax_country() const {
    // Keep the policy which supplied the frozen rates, including its local
    // overrides. The ordinary Country replica may advance between UI takes.
    const auto &snapshot = _frozen_tax_view ? _frozen_tax_view->country : _modifier_read_country;
    if (!_modifier_read_view || !snapshot || !_country_runtime) return nullptr;
    if (_country_query_snapshot == snapshot) return country_runtime_from(_country_query_runtime);
    if (_tax_query_snapshot != snapshot) {
        if (!_tax_query_runtime)
            _tax_query_runtime = std::make_unique<NativeCountryRuntime>(*country_runtime_from(_country_runtime));
        if (!_tax_query_runtime->apply_committed_read_snapshot(*snapshot)) return nullptr;
        _tax_query_snapshot = snapshot;
    }
    return _tax_query_runtime.get();
}

Dictionary DCWorldExt::get_country_tax_policy_snapshot(int64_t handle) const {
    if (uses_published_modifier_tax()) {
        const auto *country = published_tax_country();
        if (!country) return country_unavailable();
        const auto read = published_tax_values(*_modifier_read_view, _frozen_tax_view.get());
        return country->tax_policy_snapshot(handle, &read);
    }
    return _country_runtime ? country_query_runtime_for_tax()->tax_policy_snapshot(handle) : country_unavailable();
}

Dictionary DCWorldExt::get_country_cell_tax_policy_snapshot(int cell_idx) const {
    if (uses_published_modifier_tax()) {
        const auto *country = published_tax_country();
        if (!country) return country_unavailable();
        const auto read = published_tax_values(*_modifier_read_view, _frozen_tax_view.get());
        return country->cell_tax_policy_snapshot(cell_idx, &read);
    }
    return _country_runtime ? country_query_runtime_for_tax()->cell_tax_policy_snapshot(cell_idx) : country_unavailable();
}

Dictionary DCWorldExt::get_country_ui_snapshot(int64_t handle,
                                                int section_mask) const {
    if (_country_runtime == nullptr) return country_unavailable();
    const bool fiscal = (section_mask & 2) != 0;
    const bool published_fiscal = fiscal && uses_published_modifier_tax();
    const auto *runtime = published_fiscal ? country_query_runtime_from_snapshot(_display_country_snapshot)
        : (fiscal ? country_query_runtime_for_tax() : country_query_runtime());
    if (!runtime) return country_unavailable();
    Dictionary summary = runtime->country_summary(handle);
    if (!static_cast<bool>(summary.get("ok", false))) return summary;

    Dictionary out;
    // Plan §18.2: the country checkpoint's ABI, exposed so a probe can cross-check it.
    // `country_core` already refuses `country_checkpoint_abi_incompatible` on restore
    // (`country_core.cpp:324-327`); this is the readable half of that contract.
    out["country_checkpoint_abi_version"] =
        static_cast<int64_t>(COUNTRY_CHECKPOINT_ABI_VERSION);
    out["country_checkpoint_schema_version"] =
        static_cast<int64_t>(COUNTRY_CHECKPOINT_SCHEMA_VERSION);
    out["ok"] = true;
    out["country_handle"] = handle;
    out["section"] = section_mask;
    out["section_mask"] = section_mask;
    out["country_generation"] = static_cast<int64_t>(runtime->generation());
    out["country_state_version"] = summary.get("state_version", 0);
    out["revision"] = summary.get("state_version", 0);
    out["published_day"] = published_fiscal ? Variant(_display_country_day)
                                             : runtime->report().get("last_committed_day", -1);
    out["summary"] = summary;

    Dictionary revisions;
    revisions["country_state_version"] = summary.get("state_version", 0);
    revisions["country_generation"] = static_cast<int64_t>(runtime->generation());

    if ((section_mask & 1) != 0) {
        Dictionary research = runtime->research_snapshot(handle);
        out["research"] = research;
        out["research_signals"] = runtime->research_signal_snapshot(handle);
        // Progress-only days must bust the GDScript section cache even when
        // the player reopens the panel without a territory dirty bit.
        revisions["research_progress_total"] = research.get("progress_total", 0);
        revisions["research_consumed_total"] = research.get("consumed_total", 0);
        revisions["research_completed_total"] = research.get(
            "completed_total", 0);
    }
    if ((section_mask & 2) != 0) {
        Dictionary country = summary.duplicate(false);
        country["technology_ids"] = runtime->completed_technology_ids(handle);
        out["country_snapshot"] = country;
        out["treasury"] = runtime->treasury_snapshot(handle);
        out["tax_policy"] = get_country_tax_policy_snapshot(handle);
        out["fiscal"] = get_country_fiscal_snapshot(handle);
        Dictionary trade = get_country_trade_snapshot(
            handle, String("summary"), 0, 1);
        out["trade_summary"] = trade;
        const int64_t trade_revision = trade.get("revision", int64_t{0});
        int64_t class_opinion_revision = 0;
        if (_economy_runtime != nullptr) {
            class_opinion_revision = static_cast<int64_t>(
                static_cast<NativeEconomyRuntime *>(_economy_runtime)->
                    country_class_opinion_snapshot().revision);
        }
        out["economy_trade_revision"] = trade_revision;
        out["economy_class_opinion_revision"] = class_opinion_revision;
        revisions["economy_trade_revision"] = trade_revision;
        revisions["economy_class_opinion_revision"] =
            class_opinion_revision;
    }
    if ((section_mask & 4) != 0) {
        Dictionary ideology = get_ideology_snapshot(handle);
        out["ideology"] = ideology;
        const int64_t support_revision = ideology.get(
            "support_revision", int64_t{0});
        out["ideology_support_revision"] = support_revision;
        revisions["ideology_support_revision"] = support_revision;
    }
    if ((section_mask & 8) != 0) {
        Dictionary politics = runtime->political_regime_snapshot(handle);
        out["politics"] = politics;
        revisions["politics_state_version"] = politics.get(
            "state_version", int64_t{0});
        revisions["politics_catalog_hash"] = politics.get(
            "catalog_hash", int64_t{0});
    }
    out["revision_components"] = revisions;
    return out;
}

Dictionary DCWorldExt::poll_country_events(int64_t after_event_id, int limit) const {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->poll_events(after_event_id, limit);
}

Dictionary DCWorldExt::reset_country(const String &reason) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->reset(reason);
}

Dictionary DCWorldExt::begin_country_save(int chunk_bytes) {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_economy_runtime != nullptr &&
        !static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_save_allowed()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "country_save_requires_committed_economy_boundary";
        return out;
    }
    return country_runtime_from(_country_runtime)->begin_save(chunk_bytes);
}

Dictionary DCWorldExt::begin_country_forensics_save(int chunk_bytes) {
    if (_country_runtime == nullptr) return country_unavailable();
    return country_runtime_from(_country_runtime)->begin_save(chunk_bytes);
}

PackedByteArray DCWorldExt::read_country_save_chunk(int max_bytes) {
    return _country_runtime == nullptr ? PackedByteArray()
        : country_runtime_from(_country_runtime)->read_save_chunk(max_bytes);
}

Dictionary DCWorldExt::end_country_save() {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->end_save();
}

Dictionary DCWorldExt::begin_country_restore() {
    if (_country_runtime == nullptr) return country_unavailable();
    if (_economy_runtime != nullptr &&
        !static_cast<NativeEconomyRuntime *>(_economy_runtime)->country_restore_allowed()) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "country_restore_must_precede_economy_bootstrap";
        return out;
    }
    return country_runtime_from(_country_runtime)->begin_restore();
}

Dictionary DCWorldExt::feed_country_restore_chunk(const PackedByteArray &chunk) {
    return _country_runtime == nullptr ? country_unavailable()
        : country_runtime_from(_country_runtime)->feed_restore_chunk(chunk);
}

Dictionary DCWorldExt::end_country_restore() {
    if (_country_runtime == nullptr) return country_unavailable();
    Dictionary out = country_runtime_from(_country_runtime)->end_restore();
    if (static_cast<bool>(out.get("ok", false)))
        publish_restored_country_territory(out);
    return out;
}

// Every restore path must end here. PKCN restores native territory only; the
// cell_country_slot mirror is what MapData, vision, borders, and the player
// identity binding read. The CPD2 checkpoint path used to skip this, so a load
// through PKSR left every cell at -1 and failed the player-country binding.
void DCWorldExt::publish_restored_country_territory(Dictionary &out) {
    NativeCountryRuntime *runtime = country_runtime_from(_country_runtime);
    const auto publish_start = std::chrono::steady_clock::now();
    const int slot = component_id(StringName("cell_country_slot"));
    if (slot >= 0) {
        write_i32_range(slot, 0, runtime->cell_country_snapshot());
        _flush_slot_to_map(slot);
        const double publish_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - publish_start).count();
        runtime->mark_slot_publication(true, publish_ms);
        out["published_to_slot"] = true;
        out["slot_publish_ms"] = publish_ms;
    } else {
        runtime->mark_slot_publication(false, 0.0, "country_slot_unavailable");
        out["published_to_slot"] = false;
        out["publish_reason"] = "country_slot_unavailable";
    }
}

} // namespace pk
