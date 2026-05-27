--- MVP designer: competitive analysis → differentiation → form factor → spec.
--- Outputs a validated MVP spec ready for Vibe Coding.
local panel     = require("panel")
local deliberate = require("deliberate")

local M = {}

M.meta = {
    name        = "designer",
    version     = "0.1.0",
    description = "MVP spec generator with competitive positioning",
    category    = "composite",
}

---------------------------------------------------------------------------
-- Phase A: Competitive collection
---------------------------------------------------------------------------

local function collect_competitors(idea)
    local prompt = string.format([=[Identify the top 5 competitors/alternatives for this micro-SaaS idea.
Include both direct competitors and adjacent tools users currently use as workarounds.

IDEA: %s

Return ONLY valid JSON array:
[{
  "name": "Product Name",
  "url": "https://...",
  "price_range": "$X-Y/mo",
  "target": "who they serve",
  "strengths": ["s1", "s2"],
  "weaknesses": ["w1", "w2"],
  "market_position": "leader|challenger|niche|workaround"
}]]=], idea)

    local raw = alc.llm(prompt, {
        system = "You are a competitive analyst. Output ONLY valid JSON array.",
        max_tokens = 2000,
    })

    return alc.json_extract(raw) or {}
end

---------------------------------------------------------------------------
-- Phase B: Weakness analysis via panel
---------------------------------------------------------------------------

local function analyze_weaknesses(idea, competitors)
    local comp_text = {}
    for _, c in ipairs(competitors) do
        comp_text[#comp_text + 1] = string.format(
            "- %s (%s): strengths=%s, weaknesses=%s",
            c.name, c.price_range or "?",
            table.concat(c.strengths or {}, ", "),
            table.concat(c.weaknesses or {}, ", ")
        )
    end

    local task = string.format([[Analyze competitive weaknesses for this idea.

IDEA: %s

COMPETITORS:
%s

Identify: gaps in existing solutions, underserved segments, pricing opportunities,
UX pain points, and integration gaps.]], idea, table.concat(comp_text, "\n"))

    local ctx = panel.run({
        task = task,
        personas = {
            { id = "buyer", system = "You are a frustrated user of existing tools. Focus on pain points and unmet needs." },
            { id = "analyst", system = "You are a market analyst. Focus on structural gaps and pricing inefficiencies." },
            { id = "builder", system = "You are a solo developer. Focus on what you could build faster/cheaper than incumbents." },
        },
        rounds = 1,
        mode = "structured",
    })

    return ctx.result and ctx.result.synthesis or ""
end

---------------------------------------------------------------------------
-- Phase C: Feature classification (hygiene vs differentiator)
---------------------------------------------------------------------------

local function classify_features(idea, weakness_analysis)
    local prompt = string.format([[Based on this analysis, list the features for an MVP.
Classify each as HYGIENE (must-have to compete) or DIFFERENTIATOR (unique value).

IDEA: %s

ANALYSIS:
%s

Return ONLY valid JSON:
{
  "hygiene": [{"feature": "name", "effort_days": number, "reason": "why must-have"}],
  "differentiators": [{"feature": "name", "effort_days": number, "reason": "why unique"}],
  "total_mvp_days": number,
  "recommended_stack": "string (e.g. Next.js + Supabase)"
}]], idea, weakness_analysis)

    local raw = alc.llm(prompt, {
        system = "You are a product manager for a solo developer. Output ONLY valid JSON.",
        max_tokens = 1500,
    })

    return alc.json_extract(raw)
end

---------------------------------------------------------------------------
-- Phase D: Final selection via deliberate
---------------------------------------------------------------------------

local function deliberate_design(idea, features, competitors)
    local ctx = deliberate.run({
        task = string.format([[Make the final MVP design decision.

IDEA: %s

FEATURES:
- Hygiene: %d items (%d days)
- Differentiators: %d items
- Total MVP: %d days
- Stack: %s

COMPETITORS: %d identified

Key question: Is this MVP differentiated enough to survive 2 years as a solo dev product?
If YES, confirm the design. If NO, explain what's missing.

Return your decision as:
SCAFFOLD: <brief confirmation>
or
KILL: <brief reason>]],
            idea,
            features and #(features.hygiene or {}) or 0,
            features and features.total_mvp_days or 0,
            features and #(features.differentiators or {}) or 0,
            features and features.total_mvp_days or 0,
            features and features.recommended_stack or "TBD",
            #competitors
        ),
    })

    return ctx.result
end

---------------------------------------------------------------------------
-- Phase E: MVP spec generation
---------------------------------------------------------------------------

local function generate_spec(idea, features, competitors, weakness_analysis)
    local prompt = string.format([[Generate a complete MVP specification document.

IDEA: %s

FEATURES:
%s

COMPETITIVE LANDSCAPE:
%s

WEAKNESS ANALYSIS:
%s

Generate a specification with these sections:
1. Problem Statement (2-3 sentences)
2. Target User (specific persona, not generic)
3. Core Value Proposition (1 sentence)
4. Feature List (hygiene + differentiators, prioritized)
5. Technical Stack (recommended)
6. Data Model (key entities and relationships)
7. API Endpoints (if applicable)
8. Pricing Strategy (based on competitor analysis)
9. Launch Checklist (first 30 days)
10. Success Metrics (what to measure in first 90 days)

Write in markdown. Be specific enough that a developer could start building from this spec.
This should be directly usable for Vibe Coding (AI-assisted implementation).]],
        idea,
        alc.json_encode(features or {}),
        alc.json_encode(competitors or {}),
        weakness_analysis or ""
    )

    local raw = alc.llm(prompt, {
        system = "You are a product specification writer. Write clear, actionable specs.",
        max_tokens = 4000,
    })

    return raw
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

function M.run(ctx)
    local idea = ctx.task or error("designer: ctx.task required")
    local mode = ctx.mode or "full"

    alc.log("info", "designer: starting mode=" .. mode)

    -- Phase A: Competitors
    local competitors = collect_competitors(idea)
    alc.log("info", string.format("designer: found %d competitors", #competitors))

    -- Phase B: Weakness analysis
    local weakness_analysis = analyze_weaknesses(idea, competitors)

    if mode == "position_check" then
        ctx.result = {
            competitors = competitors,
            weakness_analysis = weakness_analysis,
        }
        return ctx
    end

    -- Phase C: Feature classification
    local features = classify_features(idea, weakness_analysis)
    alc.log("info", string.format(
        "designer: %d hygiene + %d differentiators = %d days",
        features and #(features.hygiene or {}) or 0,
        features and #(features.differentiators or {}) or 0,
        features and features.total_mvp_days or 0
    ))

    -- Phase D: Final decision via deliberate (structured multi-phase deliberation)
    local decision = deliberate_design(idea, features, competitors)

    -- Phase E: Spec generation — use deliberate's structured recommendation
    local spec = nil
    local is_scaffold = true
    if decision and decision.recommendation then
        local rec = decision.recommendation
        local outcome = (rec.debate_outcome or ""):lower()
        if outcome:find("opponent") or (decision.confidence or 1) < 0.4 then
            is_scaffold = false
        end
        alc.log("info", string.format(
            "designer: deliberate recommendation=%s confidence=%.2f debate=%s wins=%d",
            rec.name or "?",
            decision.confidence or 0,
            rec.debate_outcome or "?",
            rec.ranking_wins or 0
        ))
    end

    if is_scaffold then
        spec = generate_spec(idea, features, competitors, weakness_analysis)
    end

    ctx.result = {
        competitors = competitors,
        weakness_analysis = weakness_analysis,
        features = features,
        decision = decision,
        spec = spec,
    }

    alc.log("info", "designer: complete")
    return ctx
end

return M
