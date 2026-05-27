--- Idea screener: fingerprint dedup + rule filter + LLM batch screening.
local portfolio = require("portfolio")

local M = {}

M.meta = {
    name        = "screener",
    version     = "0.1.0",
    description = "Multi-stage idea filter: dedup, rules, LLM screen",
    category    = "filter",
}

local ENTERPRISE_KEYWORDS = {
    "enterprise", "SOC2", "HIPAA", "compliance", "procurement",
    "RFP", "on-premise", "government", "federal",
}

local VAGUE_KEYWORDS = {
    "platform for everything", "uber for", "one-stop",
    "revolutionize", "disrupt",
}

--- Check if idea text matches keyword blocklist.
local function keyword_check(text, keywords)
    local lower = text:lower()
    for _, kw in ipairs(keywords) do
        if lower:find(kw:lower(), 1, true) then
            return kw
        end
    end
    return nil
end

--- Fingerprint-based dedup against eval history.
function M.dedup(ideas, ns)
    local history = portfolio.load_history(ns)
    local seen = {}
    for _, entry in ipairs(history) do
        if entry.fingerprint then
            seen[entry.fingerprint] = true
        end
    end

    local unique, dupes = {}, {}
    for _, idea in ipairs(ideas) do
        local fp = portfolio.make_fingerprint(idea.text)
        if seen[fp] then
            dupes[#dupes + 1] = { idea = idea, reason = "duplicate (fingerprint)" }
        else
            seen[fp] = true
            unique[#unique + 1] = idea
        end
    end
    return unique, dupes
end

--- Rule-based filter (enterprise / vague keywords).
function M.rule_filter(ideas)
    local passed, rejected = {}, {}
    for _, idea in ipairs(ideas) do
        local enterprise_hit = keyword_check(idea.text, ENTERPRISE_KEYWORDS)
        if enterprise_hit then
            rejected[#rejected + 1] = {
                idea = idea,
                reason = "enterprise keyword: " .. enterprise_hit,
            }
            goto continue
        end

        local vague_hit = keyword_check(idea.text, VAGUE_KEYWORDS)
        if vague_hit then
            rejected[#rejected + 1] = {
                idea = idea,
                reason = "vague keyword: " .. vague_hit,
            }
            goto continue
        end

        passed[#passed + 1] = idea
        ::continue::
    end
    return passed, rejected
end

--- LLM batch screening for quality/relevance.
function M.llm_screen(ideas)
    if #ideas == 0 then return {}, {} end

    local idea_list = {}
    for i, idea in ipairs(ideas) do
        idea_list[#idea_list + 1] = string.format("%d. %s", i, idea.text:sub(1, 200))
    end

    local prompt = string.format([=[Screen these micro-SaaS ideas for a solo developer (no funding, no team).

REJECT if:
- Requires enterprise sales (SOC2, procurement, government)
- Too vague / no specific pain point
- Requires deep domain expertise the solo dev unlikely has (medical, legal, finance licensing)
- Market too small (<1000 potential customers globally)

IDEAS:
%s

Return ONLY valid JSON array of objects:
[{"index": 1, "pass": true/false, "reason": "brief reason"}]]=], table.concat(idea_list, "\n"))

    local raw = alc.llm(prompt, {
        system = "You are an idea screener. Output ONLY valid JSON array.",
        max_tokens = 1000,
    })

    local parsed = alc.json_extract(raw)
    if not parsed then
        alc.log("warn", "screener: LLM screen parse failed, passing all")
        return ideas, {}
    end

    local passed, rejected = {}, {}
    for _, result in ipairs(parsed) do
        local idx = result.index
        if idx and ideas[idx] then
            if result.pass then
                passed[#passed + 1] = ideas[idx]
            else
                rejected[#rejected + 1] = {
                    idea = ideas[idx],
                    reason = result.reason or "LLM rejected",
                }
            end
        end
    end

    return passed, rejected
end

--- Full screening pipeline.
function M.run(ctx)
    local ideas = ctx.ideas or error("screener: ctx.ideas required")
    local ns = ctx.namespace

    -- Stage 1: Dedup
    local unique, dupes = M.dedup(ideas, ns)
    alc.log("info", string.format("screener: dedup %d -> %d unique", #ideas, #unique))

    -- Stage 2: Rule filter
    local rule_passed, rule_rejected = M.rule_filter(unique)
    alc.log("info", string.format("screener: rules %d -> %d passed", #unique, #rule_passed))

    -- Stage 3: LLM screen
    local llm_passed, llm_rejected = M.llm_screen(rule_passed)
    alc.log("info", string.format("screener: LLM %d -> %d passed", #rule_passed, #llm_passed))

    -- Record gate rejections
    for _, r in ipairs(dupes) do
        portfolio.record_gate_result(r.idea.text, "GATE_REJECT", r.reason, r.idea.source, nil, ns)
    end
    for _, r in ipairs(rule_rejected) do
        portfolio.record_gate_result(r.idea.text, "GATE_REJECT", r.reason, r.idea.source, nil, ns)
    end
    for _, r in ipairs(llm_rejected) do
        portfolio.record_gate_result(r.idea.text, "GATE_REJECT", r.reason, r.idea.source, nil, ns)
    end

    ctx.result = {
        survivors = llm_passed,
        rejected = {
            dedup = dupes,
            rules = rule_rejected,
            llm = llm_rejected,
        },
        stats = {
            input = #ideas,
            after_dedup = #unique,
            after_rules = #rule_passed,
            after_llm = #llm_passed,
        },
    }

    return ctx
end

return M
