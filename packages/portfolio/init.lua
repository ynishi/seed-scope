--- Portfolio state management: CRUD, eval history, fingerprinting, Card emission.
--- Single gateway for all persistent state and Card operations.
local M = {}

M.meta = {
    name        = "portfolio",
    version     = "0.1.0",
    description = "Portfolio store with eval history and Card emission",
    category    = "infrastructure",
}

local DEFAULT_NS = "seedscope"

--- DJB2 hash for idea fingerprinting.
function M.make_fingerprint(text)
    return alc.fingerprint(text)
end

function M.make_id(name)
    return name:lower():gsub("[^%w]+", "_"):gsub("_+$", "")
end

--- Load portfolio from alc.state.
function M.load(ns)
    ns = ns or DEFAULT_NS
    local raw = alc.state.get(ns .. "_portfolio")
    if not raw then
        return { arms = {}, ideas = {}, created_at = alc.time() }
    end
    return raw
end

--- Save portfolio to alc.state.
function M.save(portfolio, ns)
    ns = ns or DEFAULT_NS
    portfolio.updated_at = alc.time()
    alc.state.set(ns .. "_portfolio", portfolio)
end

--- Find arm by id.
function M.find_arm(arms, id)
    for _, arm in ipairs(arms) do
        if arm.id == id then return arm end
    end
    return nil
end

--- Load eval history.
function M.load_history(ns)
    ns = ns or DEFAULT_NS
    local raw = alc.state.get(ns .. "_eval_history")
    return raw or {}
end

--- Find evaluation by fingerprint.
function M.find_by_fingerprint(history, fp)
    for _, entry in ipairs(history) do
        if entry.fingerprint == fp then return entry end
    end
    return nil
end

--- Record a new evaluation result.
function M.record_evaluation(idea_text, result, source_info, ns)
    ns = ns or DEFAULT_NS
    local history = M.load_history(ns)
    local fp = M.make_fingerprint(idea_text)

    local entry = {
        id = string.format("%s_%x", ns, math.floor(alc.time())),
        fingerprint = fp,
        idea = idea_text,
        result = result,
        source = source_info,
        created_at = alc.time(),
    }

    -- EMA smoothing if prior exists
    local prior = M.find_by_fingerprint(history, fp)
    if prior and prior.result and prior.result.expected_value then
        local alpha = 0.3
        local old_ev = prior.result.expected_value
        local new_ev = result.expected_value or 0
        entry.result.expected_value_ema = alpha * new_ev + (1 - alpha) * old_ev
    end

    history[#history + 1] = entry
    alc.state.set(ns .. "_eval_history", history)

    alc.log("info", string.format(
        "portfolio: recorded eval id=%s fp=%s decision=%s",
        entry.id, fp, result.decision or "?"
    ))

    return entry
end

--- Record a gate result (pre-evaluation rejection).
function M.record_gate_result(idea_text, decision, reason, source_info, extra, ns)
    ns = ns or DEFAULT_NS
    local history = M.load_history(ns)

    local entry = {
        id = string.format("%s_gate_%x", ns, math.floor(alc.time())),
        fingerprint = M.make_fingerprint(idea_text),
        idea = idea_text,
        result = {
            decision = decision,
            reason = reason,
            gate_reject = true,
        },
        source = source_info,
        extra = extra,
        created_at = alc.time(),
    }

    history[#history + 1] = entry
    alc.state.set(ns .. "_eval_history", history)
    return entry
end

--- Update an existing evaluation entry.
function M.update_evaluation(eval_id, updates, ns)
    ns = ns or DEFAULT_NS
    local history = M.load_history(ns)

    for _, entry in ipairs(history) do
        if entry.id == eval_id then
            for k, v in pairs(updates) do
                entry[k] = v
            end
            entry.updated_at = alc.time()
            alc.state.set(ns .. "_eval_history", history)
            return entry
        end
    end
    return nil
end

--- Emit a Card for an evaluation result.
function M.emit_card(entry, result, prior_card_id, ns)
    ns = ns or DEFAULT_NS
    if not alc.card or not alc.card.create then
        alc.log("info", "portfolio: card emission skipped (alc.card not available)")
        return nil
    end
    local payload = M.to_card_payload(entry, result, prior_card_id)
    local ok, card_id = pcall(alc.card.create, payload)
    if not ok then
        alc.log("warn", "portfolio: card emission failed: " .. tostring(card_id))
        return nil
    end

    local samples = M.to_card_samples(result)
    if samples and #samples > 0 then
        pcall(alc.card.write_samples, card_id, samples)
    end

    alc.log("info", string.format("portfolio: emitted card=%s", card_id))
    return card_id
end

--- Build Card payload from eval entry.
function M.to_card_payload(entry, result, prior_card_id)
    local metrics = result.metrics or {}
    return {
        title = string.format("eval: %s", (entry.idea or ""):sub(1, 60)),
        category = "seedscope.eval",
        body = string.format(
            "decision=%s ev=%.2f pain=%s wtp=%s pr=%s def=%s ssf=%s t=%sd",
            result.decision or "?",
            result.expected_value or 0,
            tostring(metrics.Pain_level or "?"),
            tostring(metrics.Willingness_to_Pay or "?"),
            tostring(metrics.Purchase_Realism or "?"),
            tostring(metrics.Defensibility or "?"),
            tostring(metrics.Self_Serve_Fit or "?"),
            tostring(metrics.Time_to_MVP or "?")
        ),
        prior = prior_card_id,
    }
end

--- Build Card samples from eval result.
function M.to_card_samples(result)
    if not result.raw_scores then return {} end
    local samples = {}
    for i, score in ipairs(result.raw_scores) do
        samples[#samples + 1] = {
            lens = i,
            metrics = score,
        }
    end
    return samples
end

return M
