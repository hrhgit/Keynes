#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "economy_hash.h"
#include "economy_runtime_persistence_codec.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "economy_authority_transfer.h"
#include "effect_runtime.h"
#include "modifier_api.h"
#include "runtime_economy_ecp2.h"
#include "pk_log.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <tuple>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace persistence_codec;

#include "economy_runtime_persistence_section_save_capture.inc"

struct NativeEconomyRuntime::RestoreStream {
    NativeEconomyRuntime candidate;
    std::vector<PackedByteArray> chunks;
    uint64_t country_generation = 0;
    int64_t country_hash = 0;
};

Dictionary NativeEconomyRuntime::begin_restore() {
    Dictionary result = open_restore_session();
    if (!static_cast<bool>(result["ok"])) return result;
    auto stream = std::make_shared<RestoreStream>();
    auto &candidate = stream->candidate;
    candidate.attach_country_runtime(_country_runtime);
    // Configuration resolves immutable stat IDs. No archive bytes reach this peer.
    candidate.attach_modifier_runtime(_modifier_runtime);
    Dictionary configured = candidate.configure_runtime(
        _restore_catalog, _restore_profile, _cell_count.get(), _seed.get());
    candidate.attach_modifier_runtime(nullptr);
    if (!static_cast<bool>(configured["ok"])) {
        _restore = {};
        set_restore_rejected_reason(String(configured["reason"]).utf8().get_data());
        return configured;
    }
    candidate._restore.active = true;
    candidate.prepare_restore_candidate_scratch();
    _restore.stream = std::move(stream);
    return result;
}

Dictionary NativeEconomyRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    if (!_restore.stream) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = "restore_not_active";
        return out;
    }
    Dictionary result = _restore.stream->candidate.feed_restore_candidate(chunk);
    if (static_cast<bool>(result["ok"])) {
        if (_restore.stream->chunks.empty()) {
            _restore.stream->country_generation = country_reads().generation();
            _restore.stream->country_hash = country_reads().state_hash();
        }
        _restore.stream->chunks.push_back(chunk);
    } else {
        // Some callers stop at the first rejected feed and never call end.
        // Release the candidate and the session immediately; end can still
        // report the original error once.
        _restore = {};
        _restore.error = String(result["reason"]).utf8().get_data();
        set_restore_rejected_reason(_restore.error);
    }
    return result;
}

Dictionary NativeEconomyRuntime::end_restore() {
    auto stream = std::move(_restore.stream);
    if (!stream) {
        Dictionary out;
        out["ok"] = false;
        out["reason"] = _restore.error.empty() ? String("restore_not_active") : String(_restore.error.c_str());
        _restore.error.clear();
        return out;
    }
    _restore = {};
    // Raw feeds only collect the modifier section. The final cross-reference
    // checks decode it against a private copy with the current peer catalog.
    auto &candidate = stream->candidate;
    candidate.attach_effect_runtime(_effect_runtime);
    Dictionary result;
    if (_modifier_runtime) {
        auto modifier = modifier_api::copy_runtime(*_modifier_runtime);
        modifier_api::attach_economy_runtime(*modifier, &candidate);
        candidate.attach_modifier_runtime(modifier.get());
        result = candidate.finish_restore_candidate(false);
        candidate.attach_modifier_runtime(nullptr);
    } else {
        result = candidate.finish_restore_candidate(false);
    }
    if (!static_cast<bool>(result["ok"])) {
        set_restore_rejected_reason(String(result["reason"]).utf8().get_data());
        return result;
    }
    if (country_reads().generation() != stream->country_generation ||
        country_reads().state_hash() != stream->country_hash) {
        set_restore_rejected_reason("economy_country_restore_order_or_hash_mismatch");
        result["ok"] = false;
        result["reason"] = String(_restore_rejected_reason.c_str());
        return result;
    }
    // The raw stream also supports the opening before the first committed day.
    // Keep its exact bytes and install them in one call at the stopped boundary.
    // The native owner, its non-PKEC inputs and its external bindings keep their identity.
    auto chunks = std::move(stream->chunks);
    stream.reset();
    auto install = [&](const std::vector<PackedByteArray> &wire) {
        Dictionary installed = open_restore_session();
        if (!static_cast<bool>(installed["ok"])) return installed;
        prepare_restore_candidate_scratch();
        for (const auto &chunk : wire) {
            installed = feed_restore_candidate(chunk);
            if (!static_cast<bool>(installed["ok"])) return installed;
        }
        return finish_restore_candidate();
    };
    // Context outside PKEC (for example Country's generation) can have
    // changed between feeds. Keep a rollback point for that final installation.
    RuntimeEconomyEcp2State backup;
    std::vector<PackedByteArray> opening;
    std::string error;
    const bool had_world = _bootstrapped;
    const bool committed = had_world && !_fatal && _last_committed_day.get() >= 0;
    if (committed && !capture_ecp2_authority(backup, error, ECP2_CAPTURE_ROLLBACK_BACKUP)) {
        result["ok"] = false;
        result["reason"] = String(error.c_str());
        set_restore_rejected_reason(error);
        return result;
    }
    if (had_world && !committed) {
        result = begin_forensics_save(4 * 1024 * 1024);
        if (!static_cast<bool>(result["ok"])) return result;
        for (;;) {
            auto chunk = read_save_chunk(4 * 1024 * 1024);
            if (chunk.is_empty()) break;
            opening.push_back(std::move(chunk));
        }
        result = end_save();
        if (!static_cast<bool>(result["ok"])) return result;
    }
    result = install(chunks);
    if (!static_cast<bool>(result["ok"])) {
        const String reason = result["reason"];
        _restore = {};
        if (committed) {
            apply_ecp2_authority_internal(backup, error);
        } else if (had_world) {
            const Dictionary rolled_back = install(opening);
            if (!static_cast<bool>(rolled_back["ok"]))
                error = String(rolled_back["reason"]).utf8().get_data();
        }
        _restore = {};
        result["reason"] = error.empty() ? reason : reason + String(";rollback_failed:") + String(error.c_str());
        set_restore_rejected_reason(String(result["reason"]).utf8().get_data());
    } else {
        _restore_rejected_reason.clear();
    }
    return result;
}

Dictionary NativeEconomyRuntime::open_restore_session() {
    Dictionary out;
    if (!_configured || _epoch_active || _save.active || _restore.active ||
        _fiscal_reservation_continuation.active ||
        _epoch_begin_post_fiscal_pending ||
        _fiscal_settlement_continuation.active ||
        _country_research_procurement_continuation.active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "configure_catalog_before_restore"
                         : (_fiscal_reservation_continuation.active ||
                            _epoch_begin_post_fiscal_pending
                             ? "restore_fiscal_reservation_pending"
                         : (_fiscal_settlement_continuation.active
                             ? "restore_fiscal_settlement_pending"
                         : (_country_research_procurement_continuation.active
                             ? "restore_research_procurement_pending"
                         : (_epoch_active ? "restore_requires_committed_boundary"
                             : "save_restore_already_active"))));
        if (_fiscal_reservation_continuation.active ||
            _epoch_begin_post_fiscal_pending) {
            out["country_cursor"] =
                _fiscal_reservation_continuation.country_cursor;
            out["country_count"] =
                _fiscal_reservation_continuation.country_count;
            out["day"] = _fiscal_reservation_continuation.day_index;
            out["phase"] = _fiscal_reservation_continuation.phase;
            out["epoch_begin_pending"] = _epoch_begin_post_fiscal_pending;
        } else if (_fiscal_settlement_continuation.active) {
            out["country_cursor"] =
                _fiscal_settlement_continuation.country_cursor;
            out["country_count"] =
                _fiscal_settlement_continuation.country_count;
            out["phase"] = _fiscal_settlement_continuation.phase;
            out["last_unused"] =
                _fiscal_settlement_continuation.last_unused;
            out["last_collected"] =
                _fiscal_settlement_continuation.last_collected;
        }
        set_restore_rejected_reason(
            String(out["reason"]).utf8().get_data());
        return out;
    }
    _restore = {};
    _restore.active = true;
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    out["scratch_prepared"] = true;
    out["requires_ecp2"] = true;
    return out;
}


void NativeEconomyRuntime::set_restore_rejected_reason(
        const std::string &reason) {
    _restore_rejected_reason = reason;
}

Dictionary NativeEconomyRuntime::feed_restore_candidate(const PackedByteArray &chunk) {
    Dictionary out;
    if (!_restore.active || _restore.failed || _restore.end_seen || chunk.is_empty()) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                                            : (_restore.end_seen ? "restore_end_already_seen"
                                                                 : "restore_chunk_empty"));
        set_restore_rejected_reason(
            String(out["reason"]).utf8().get_data());
        return out;
    }
    if (!_restore.scratch_prepared) {
        out["ok"] = false;
        out["reason"] = "restore_scratch_not_prepared";
        set_restore_rejected_reason("restore_scratch_not_prepared");
        return out;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(chunk.size()));
    std::memcpy(bytes.data(), chunk.ptr(), bytes.size());
    std::string error;
    if (!decode_restore_chunk(bytes, error)) {
        _restore.failed = true;
        _restore.error = error;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        set_restore_rejected_reason(error);
        return out;
    }
    out["ok"] = true;
    out["header_seen"] = _restore.header_seen;
    out["end_seen"] = _restore.end_seen;
    out["restored_pages"] = _restore.restored_pages;
    out["restored_markets"] = _restore.restored_markets;
    out["restored_cells"] = _restore.restored_cells;
    out["restored_commands"] = _restore.restored_commands;
    out["restored_audits"] = _restore.restored_audits;
    out["restored_signals"] = _restore.restored_signals;
    out["restored_labor_signals"] = _restore.restored_labor_signals;
    out["restored_trade_orders"] = _restore.restored_trade_orders;
    out["restored_trade_flows"] = _restore.restored_trade_flows;
    out["restored_persons"] = _restore.restored_persons;
    out["restored_person_needs"] = _restore.restored_person_needs;
    return out;
}

Dictionary NativeEconomyRuntime::finish_restore_candidate(bool install) {
#include "economy_runtime_persistence_section_restore_validation.inc"
#include "economy_runtime_persistence_section_restore_inventory.inc"
#include "economy_runtime_persistence_section_restore_peers_and_publish.inc"
}

bool NativeEconomyRuntime::begin_restore_internal(std::string &error) {
    error.clear();
    const Dictionary out = open_restore_session();
    if (!static_cast<bool>(out.get("ok", false))) {
        error = String(out.get("reason", "restore_begin_failed")).utf8().get_data();
        set_restore_rejected_reason(error);
        return false;
    }
    return true;
}
bool NativeEconomyRuntime::end_restore_internal(std::string &error) {
    error.clear();
    const Dictionary out = finish_restore_candidate();
    if (!static_cast<bool>(out.get("ok", false))) {
        error = String(out.get("reason", "restore_end_failed")).utf8().get_data();
        set_restore_rejected_reason(error);
        return false;
    }
    return true;
}

// The deferred half of the country-identity check (see `_accept_stale_country_identity`).
//
// `apply_ecp2_authority` skips `country_hash != expected_country_hash` when Country has
// not been installed yet, and records what the archive ASKED for. This compares that
// record against the live Country runtime, which by now holds the archive's real
// checkpoint. Pairing A's Country bytes with B's Economy bytes therefore still fails --
// the important half of "restore is atomic" is not lost, only moved.
bool NativeEconomyRuntime::verify_deferred_country_identity(
        std::string &error) const {
    error.clear();
    if (!_deferred_country_identity_recorded) return true;
    if (_country_runtime == nullptr) {
        error = "economy_deferred_country_runtime_missing";
        return false;
    }
    const uint64_t live_generation =
        static_cast<uint64_t>(country_reads().generation());
    const uint64_t live_hash = static_cast<uint64_t>(country_reads().state_hash());
    if (live_generation != _deferred_country_generation ||
        live_hash != _deferred_country_state_hash) {
        // Name both sides: a mismatch without the two identities is unactionable, and
        // this failure is exactly the one that used to be invisible.
        char detail[128];
        std::snprintf(detail, sizeof(detail),
                      "economy_country_identity_mismatch:expected_gen=%llu_"
                      "hash=%llu:live_gen=%llu_hash=%llu",
                      static_cast<unsigned long long>(_deferred_country_generation),
                      static_cast<unsigned long long>(_deferred_country_state_hash),
                      static_cast<unsigned long long>(live_generation),
                      static_cast<unsigned long long>(live_hash));
        error = detail;
        return false;
    }
    return true;
}

#include "economy_runtime_persistence_section_ecp2_authority.inc"
} // namespace pk
