--- Idea evaluator: 5-persona debate + self-consistency scoring + EV calculation.
--- Produces SCAFFOLD/KILL decision with metrics and kill_reasons.
--- Supports re_evaluate mode: ground LLM metrics with real telemetry.
local panel     = require("panel")
local calibrate = require("calibrate")

local M = {}

M.meta = {
    name        = "evaluator",
    version     = "0.1.0",
    description = "Multi-persona idea evaluation with EV scoring and telemetry grounding",
    category    = "composite",
}

local cfg = require("evaluator.tuning")

local PERSONAS = {
    { id = "pragmatist",  system = "You are a pragmatic solo developer who has shipped 3 micro-SaaS products. You value speed-to-market and self-serve distribution above all." },
    { id = "skeptic",     system = "You are a veteran VC analyst who has seen 1000 pitches. You look for fatal flaws: market size, defensibility, timing." },
    { id = "builder",     system = "You are a technical architect focused on implementation cost. You estimate effort in days and flag hidden complexity." },
    { id = "customer",    system = "You are a potential buyer. You evaluate whether you'd actually pay for this, switch from existing tools, and use it weekly." },
    { id = "contrarian",  system = "You deliberately argue the opposite of consensus. If everyone likes it, you find reasons it will fail. If everyone hates it, you find hidden value." },
}

local METRIC_FIELDS = {
    "Pain_level", "Time_to_MVP", "Willingness_to_Pay",
    "Defensibility", "Distribution_Fit", "Implementation_Cost",
    "Self_Serve_Fit", "Purchase_Realism",
}

local DIVERSITY_LENSES = {
    { name = "default",     instruction = "Score as you normally would." },
    { name = "pessimistic", instruction = "Assume worst-case: strongest competitor enters, economy downturn, user acquisition cost doubles." },
    { name = "optimistic",  instruction = "Assume best-case: viral adoption, no strong competitor, perfect product-market fit." },
    { name = "contrarian",  instruction = "Deliberately score opposite to your gut feeling. If it feels good, score low. If it feels bad, score high." },
    { name = "technical",   instruction = "Focus only on technical feasibility, implementation risk, and maintenance burden." },
}

--- Calculate expected value from metrics.
local function calculate_ev(m)
    local e = cfg.exponents
    local t_market = math.max(m.Time_to_MVP, 1)
    local pr = m.Purchase_Realism or 5
    local zeta = e.zeta or 1.5

    local raw = (m.Pain_level ^ e.alpha
                 * m.Willingness_to_Pay ^ e.beta
                 * pr ^ zeta
                 * m.Defensibility ^ e.gamma
                 * m.Self_Serve_Fit ^ e.epsilon)
                / (t_market ^ e.delta)

    local t_min = math.max(cfg.min_realistic_mvp or 7, 1)
    local max_raw = (10 ^ e.alpha * 10 ^ e.beta * 10 ^ zeta
                     * 10 ^ e.gamma * 10 ^ e.epsilon)
                  / (t_min ^ e.delta)
    local normalized = math.log(1 + raw) / math.log(1 + max_raw) * 100
    return math.floor(normalized * 1000 + 0.5) / 1000
end

--- Check hard gates (instant KILL conditions).
local function check_hard_gates(metrics)
    local gates = {}
    if metrics.Self_Serve_Fit and metrics.Self_Serve_Fit <= 2 then
        gates[#gates + 1] = string.format("Self_Serve_Fit=%d (<=2: requires human sales)", metrics.Self_Serve_Fit)
    end
    if metrics.Purchase_Realism and metrics.Purchase_Realism <= 1 then
        gates[#gates + 1] = string.format("Purchase_Realism=%d (<=1: incumbent fully dominates)", metrics.Purchase_Realism)
    end
    return gates
end

--- Build the scoring prompt for a single lens.
local function build_score_prompt(idea, lens_instruction, reference_bundle)
    local bundle_section = ""
    if reference_bundle then
        if reference_bundle.incumbent_name then
            bundle_section = string.format([[

REFERENCE BUNDLE (commerce reality grounding):
- Incumbent: %s
- Incumbent price: $%s/mo
- Incumbent feature count: ~%s
- Target solo offering price: $%s/mo
- Feature overlap: %s
- Switching cost: %s

Score Purchase_Realism based on realized conversion given this bundle.
Single-feature is NOT automatically low if 4P differentiation exists.
]],
                tostring(reference_bundle.incumbent_name),
                tostring(reference_bundle.price_usd_per_mo or 0),
                tostring(reference_bundle.feature_count or 0),
                tostring(reference_bundle.target_solo_price_usd or 0),
                tostring(reference_bundle.feature_overlap or "?"),
                tostring(reference_bundle.switching_cost_signal or "?")
            )
        else
            bundle_section = "\nREFERENCE BUNDLE: No clear incumbent. Score Purchase_Realism on demand existence.\n"
        end
    end

    return string.format([[You are a cold, data-driven evaluation engine. No poetry. No optimism.

LENS: %s

IDEA:
%s
%s
Score each 1-10 (integer only). Time_to_MVP in calendar days.

METRICS:
- Pain_level: How urgent/painful? (1=mild, 10=hair-on-fire)
- Willingness_to_Pay: Will users pay in absolute terms? (1=never, 10=shut-up-and-take-my-money)
- Purchase_Realism: Given the REFERENCE BUNDLE, what fraction actually purchases? (1=incumbent dominates, 10=structurally superior)
- Defensibility: Solo dev survival 2+ years? (1=commodity, 10=strong moat)
- Self_Serve_Fit: Sell without human sales? (1=enterprise-only, 10=pure-self-serve)
- Distribution_Fit: Fit target surfaces? (1=no fit, 10=native)
- Implementation_Cost: Build difficulty for solo dev? (1=trivial, 10=impossible)
- Time_to_MVP: Calendar days to working MVP

ALSO PROVIDE:
- kill_reasons: array of 3 strongest reasons this idea could fail
- strongest_signal: single most compelling evidence for or against

Return ONLY valid JSON.
{"Pain_level":7,"Willingness_to_Pay":5,"Purchase_Realism":4,"Defensibility":4,"Self_Serve_Fit":6,"Distribution_Fit":8,"Implementation_Cost":3,"Time_to_MVP":21,"kill_reasons":["r1","r2","r3"],"strongest_signal":"signal"}]],
        lens_instruction, idea, bundle_section)
end

--- Validate parsed metrics.
local function validate_metrics(parsed)
    for _, field in ipairs(METRIC_FIELDS) do
        local v = parsed[field]
        if not v or type(v) ~= "number" then return false end
        if field ~= "Time_to_MVP" and (v < 1 or v > 10) then return false end
    end
    return true
end

--- Score with multiple diversity lenses (self-consistency).
function M.score_lens(ctx)
    local idea = ctx.idea or error("evaluator: ctx.idea required")
    local lens_indices = ctx.lens_indices
    local bundle = ctx.reference_bundle

    local lenses = {}
    if lens_indices then
        for _, idx in ipairs(lens_indices) do
            lenses[#lenses + 1] = DIVERSITY_LENSES[idx] or DIVERSITY_LENSES[1]
        end
    else
        lenses = DIVERSITY_LENSES
    end

    local lens_instructions = {}
    for _, lens in ipairs(lenses) do
        lens_instructions[#lens_instructions + 1] = lens.instruction
    end

    local responses = alc.parallel(lens_instructions, function(instruction)
        return {
            prompt = build_score_prompt(idea, instruction, bundle),
            system = "You are a scoring function for a SOLO DEVELOPER with no funding. Output ONLY valid JSON.",
            max_tokens = 500,
        }
    end)

    local valid_samples = {}
    for i, raw in ipairs(responses) do
        local parsed = alc.json_extract(raw)
        if parsed and validate_metrics(parsed) then
            valid_samples[#valid_samples + 1] = parsed
            alc.log_fmt("info",
                "evaluator: lens %d/%d — Pain=%d WTP=%d PR=%s Def=%d SSF=%d T=%dd",
                i, #lenses,
                parsed.Pain_level, parsed.Willingness_to_Pay,
                tostring(parsed.Purchase_Realism or "nil"),
                parsed.Defensibility, parsed.Self_Serve_Fit, parsed.Time_to_MVP
            )
        else
            alc.log("warn", string.format("evaluator: lens %d/%d invalid", i, #lenses))
        end
    end

    if #valid_samples == 0 then
        ctx.result = { status = "error", reason = "no valid samples" }
        return ctx
    end

    -- Aggregate via median
    local metrics = {}
    for _, field in ipairs(METRIC_FIELDS) do
        local vals = {}
        for _, s in ipairs(valid_samples) do
            if s[field] then vals[#vals + 1] = s[field] end
        end
        if #vals > 0 then
            metrics[field] = alc.math.median(vals)
        end
    end

    local ev = calculate_ev(metrics)
    local hard_gate_fails = check_hard_gates(metrics)
    local kill_threshold = ctx.kill_threshold or cfg.kill_threshold

    local decision
    if #hard_gate_fails > 0 then
        decision = "KILL"
    elseif ev < kill_threshold then
        decision = "KILL"
    else
        decision = "SCAFFOLD"
    end

    -- Collect kill_reasons from samples
    local kill_reasons = {}
    for _, s in ipairs(valid_samples) do
        if s.kill_reasons then
            for _, r in ipairs(s.kill_reasons) do
                kill_reasons[#kill_reasons + 1] = r
            end
        end
    end

    ctx.result = {
        decision = decision,
        expected_value = ev,
        metrics = metrics,
        kill_reasons = kill_reasons,
        hard_gate_fails = hard_gate_fails,
        raw_scores = valid_samples,
        sample_count = #valid_samples,
        ev = ev,
    }

    alc.log("info", string.format(
        "evaluator: EV=%.3f decision=%s samples=%d",
        ev, decision, #valid_samples
    ))

    return ctx
end

--- Build reference bundle extraction request.
function M.bundle_request(idea, market_research)
    return {
        prompt = string.format([[You are a market analyst. Identify the dominant incumbent product that target users currently use.

IDEA:
%s

%s

Return ONLY valid JSON:
{
  "incumbent_name": "string or null",
  "price_usd_per_mo": number,
  "feature_count": number,
  "target_solo_price_usd": number,
  "feature_overlap": "high|medium|low",
  "switching_cost_signal": "high|medium|low"
}]], idea, market_research or ""),
        system = "You are a factual market analyst. Output ONLY valid JSON.",
        max_tokens = 400,
    }
end

function M.parse_bundle(raw)
    if not raw then return nil end
    local parsed = alc.json_extract(raw)
    if not parsed then
        alc.log("warn", "evaluator: bundle parse failed")
        return nil
    end
    return parsed
end

function M.extract_bundle(idea, market_research)
    local req = M.bundle_request(idea, market_research)
    local raw = alc.llm(req.prompt, { system = req.system, max_tokens = req.max_tokens })
    return M.parse_bundle(raw)
end

--- Telemetry grounding: anchor LLM metrics with real-world signals.
---
--- ctx.prior_metrics: table — previous LLM-scored metrics
--- ctx.telemetry: table — real data { downloads, revenue_usd, active_users,
---                         churn_rate_pct, months_live }
--- ctx.idea: string — idea text (for calibrate context)
---
--- Returns grounded metrics + recalculated EV + updated decision.
function M.re_evaluate(ctx)
    local prior = ctx.prior_metrics or error("evaluator.re_evaluate: prior_metrics required")
    local telem = ctx.telemetry or error("evaluator.re_evaluate: telemetry required")
    local idea = ctx.idea or ctx.task or ""
    local kill_threshold = ctx.kill_threshold or cfg.kill_threshold

    local grounded = {}
    for k, v in pairs(prior) do grounded[k] = v end

    if telem.revenue_usd and telem.revenue_usd > 0 then
        local revenue_signal = math.min(10, math.max(1, math.log(telem.revenue_usd + 1) / math.log(1000) * 10))
        grounded.Willingness_to_Pay = math.floor((prior.Willingness_to_Pay + revenue_signal) / 2 + 0.5)
    end

    if telem.active_users and telem.active_users > 0 and telem.downloads and telem.downloads > 0 then
        local retention = telem.active_users / telem.downloads
        local ssf_signal = math.min(10, math.max(1, retention * 15))
        grounded.Self_Serve_Fit = math.floor((prior.Self_Serve_Fit + ssf_signal) / 2 + 0.5)
    end

    if telem.churn_rate_pct then
        local churn_penalty = math.max(0, (telem.churn_rate_pct - 5) / 10)
        grounded.Defensibility = math.max(1, math.floor(prior.Defensibility - churn_penalty * 3 + 0.5))
    end

    if telem.downloads and telem.downloads > 0 then
        local dl_signal = math.min(10, math.max(1, math.log(telem.downloads + 1) / math.log(10000) * 10))
        grounded.Purchase_Realism = math.floor((prior.Purchase_Realism + dl_signal) / 2 + 0.5)
    end

    if telem.months_live and telem.months_live > 0 then
        grounded.Time_to_MVP = prior.Time_to_MVP
    end

    local cal_ctx = calibrate.run({
        task = string.format(
            "Calibrate this evaluation given real telemetry.\n\nIDEA: %s\n\n"
            .. "PRIOR METRICS: Pain=%s WTP=%s PR=%s Def=%s SSF=%s T=%sd\n"
            .. "TELEMETRY: downloads=%s revenue=$%s active=%s churn=%s%% months=%s\n"
            .. "GROUNDED METRICS: Pain=%s WTP=%s PR=%s Def=%s SSF=%s T=%sd\n\n"
            .. "How confident are you that the grounded metrics reflect reality?",
            idea,
            tostring(prior.Pain_level), tostring(prior.Willingness_to_Pay),
            tostring(prior.Purchase_Realism), tostring(prior.Defensibility),
            tostring(prior.Self_Serve_Fit), tostring(prior.Time_to_MVP),
            tostring(telem.downloads or 0), tostring(telem.revenue_usd or 0),
            tostring(telem.active_users or 0), tostring(telem.churn_rate_pct or 0),
            tostring(telem.months_live or 0),
            tostring(grounded.Pain_level), tostring(grounded.Willingness_to_Pay),
            tostring(grounded.Purchase_Realism), tostring(grounded.Defensibility),
            tostring(grounded.Self_Serve_Fit), tostring(grounded.Time_to_MVP)
        ),
        scale = "probability",
    })

    local confidence = cal_ctx.result and cal_ctx.result.calibrated_value or 0.5

    local ev = calculate_ev(grounded)
    local hard_gate_fails = check_hard_gates(grounded)

    local decision
    if #hard_gate_fails > 0 then
        decision = "KILL"
    elseif ev < kill_threshold then
        decision = "KILL"
    else
        decision = "SCAFFOLD"
    end

    local prior_ev = calculate_ev(prior)
    local ev_delta = ev - prior_ev

    alc.log("info", string.format(
        "evaluator.re_evaluate: EV %.3f -> %.3f (delta=%+.3f) decision=%s confidence=%.2f",
        prior_ev, ev, ev_delta, decision, confidence
    ))

    ctx.result = {
        decision = decision,
        expected_value = ev,
        prior_ev = prior_ev,
        ev_delta = ev_delta,
        metrics = grounded,
        prior_metrics = prior,
        telemetry = telem,
        calibration_confidence = confidence,
        hard_gate_fails = hard_gate_fails,
    }

    return ctx
end

--- Full evaluation pipeline: debate + score + decide.
function M.run(ctx)
    local idea = ctx.task or ctx.idea or error("evaluator: idea required")
    local kill_threshold = ctx.kill_threshold or cfg.kill_threshold

    -- Phase 1: Panel debate
    local debate_ctx = panel.run({
        task = idea,
        personas = PERSONAS,
        rounds = 2,
        mode = "structured",
    })
    local synthesis = debate_ctx.result and debate_ctx.result.synthesis or ""

    -- Phase 2: Score with all lenses
    local score_ctx = M.score_lens({
        idea = idea .. "\n\nDEBATE SYNTHESIS:\n" .. synthesis,
        reference_bundle = ctx.reference_bundle,
        kill_threshold = kill_threshold,
    })

    ctx.result = score_ctx.result
    if ctx.result then
        ctx.result.debate_synthesis = synthesis
    end

    return ctx
end

return M
