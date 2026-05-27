--- Idea sourcer: extract ideas from raw web signals via Thompson Sampling.
--- Manages sourcing arms (themes/categories) with bandit optimization.
local bandit    = require("bandit")
local portfolio = require("portfolio")

local M = {}

M.meta = {
    name        = "sourcer",
    version     = "0.1.0",
    description = "Thompson Sampling idea sourcer with theme/source arms",
    category    = "sourcing",
}

local DEFAULT_STATE_KEY = "seedscope_sourcing"

--- Load sourcing state.
function M.load_state(ns)
    local key = (ns or "seedscope") .. "_sourcing"
    return alc.state.get(key) or {
        arms = {},
        created_at = alc.time(),
    }
end

--- Save sourcing state.
function M.save_state(state, ns)
    local key = (ns or "seedscope") .. "_sourcing"
    state.updated_at = alc.time()
    alc.state.set(key, state)
end

--- Extract ideas from raw posts via LLM.
function M.extract(raw_posts)
    if not raw_posts or #raw_posts == 0 then
        return {}
    end

    local posts_text = {}
    for i, post in ipairs(raw_posts) do
        posts_text[#posts_text + 1] = string.format(
            "%d. [%s] %s\n%s",
            i,
            post.source or "unknown",
            post.title or "",
            (post.body or ""):sub(1, 500)
        )
    end

    local prompt = string.format([[Extract micro-SaaS product ideas from these posts.
Focus on: pain points, unmet needs, workflow inefficiencies, complaints about existing tools.

POSTS:
%s

For each idea found, return:
[{"text": "Clear 1-2 sentence idea description", "source_post": <index>, "pain_signal": "the specific pain/complaint"}]

If no viable ideas found, return empty array: []
Return ONLY valid JSON array.]], table.concat(posts_text, "\n\n"))

    local raw = alc.llm(prompt, {
        system = "You are an idea extractor for a solo micro-SaaS developer. Output ONLY valid JSON array.",
        max_tokens = 2000,
    })

    local parsed = alc.json_extract(raw)
    if not parsed then
        alc.log("warn", "sourcer: extract parse failed")
        return {}
    end

    -- Attach source info
    local ideas = {}
    for _, item in ipairs(parsed) do
        if item.text and #item.text > 10 then
            ideas[#ideas + 1] = {
                text = item.text,
                source = {
                    post_index = item.source_post,
                    pain_signal = item.pain_signal,
                    extracted_at = alc.time(),
                },
            }
        end
    end

    alc.log("info", string.format("sourcer: extracted %d ideas from %d posts", #ideas, #raw_posts))
    return ideas
end

--- Select next sourcing theme via Thompson Sampling.
function M.harvest(ns)
    local state = M.load_state(ns)
    local arms = state.arms

    if #arms == 0 then
        alc.log("info", "sourcer: no arms, need sprout first")
        return nil, "no arms available"
    end

    -- Thompson Sampling to pick best arm
    local best_arm, best_sample = nil, -1
    local rng = alc.math.rng_create(math.floor(alc.time()))
    for _, arm in ipairs(arms) do
        if arm.status ~= "inactive" then
            local sample = alc.math.beta_sample(rng, arm.alpha or 1, arm.beta or 1)
            if sample > best_sample then
                best_sample = sample
                best_arm = arm
            end
        end
    end

    if not best_arm then
        return nil, "all arms inactive"
    end

    alc.log("info", string.format(
        "sourcer: harvest selected arm=%s (alpha=%.1f beta=%.1f)",
        best_arm.name, best_arm.alpha or 1, best_arm.beta or 1
    ))

    return best_arm
end

--- Generate new sourcing themes via LLM.
function M.sprout(existing_themes, ns)
    local theme_list = ""
    if existing_themes and #existing_themes > 0 then
        local names = {}
        for _, t in ipairs(existing_themes) do
            names[#names + 1] = t.name or t.id
        end
        theme_list = "\nEXISTING THEMES (avoid overlap):\n" .. table.concat(names, "\n")
    end

    local prompt = string.format([=[Generate 3 new micro-SaaS sourcing themes for a solo developer.
Each theme should target a specific niche with clear pain points.
%s

Return ONLY valid JSON array:
[{"name": "theme_name", "category": "category", "description": "1 sentence", "search_queries": ["query1", "query2"]}]]=], theme_list)

    local raw = alc.llm(prompt, {
        system = "You are a market researcher. Output ONLY valid JSON array.",
        max_tokens = 1000,
    })

    local parsed = alc.json_extract(raw)
    if not parsed then
        alc.log("warn", "sourcer: sprout parse failed")
        return {}
    end

    local state = M.load_state(ns)
    local new_arms = {}
    for _, theme in ipairs(parsed) do
        local arm = {
            id = portfolio.make_id(theme.name),
            name = theme.name,
            category = theme.category,
            description = theme.description,
            search_queries = theme.search_queries,
            alpha = 1,
            beta = 1,
            status = "active",
            created_at = alc.time(),
        }
        state.arms[#state.arms + 1] = arm
        new_arms[#new_arms + 1] = arm
    end

    M.save_state(state, ns)
    alc.log("info", string.format("sourcer: sprouted %d new themes", #new_arms))
    return new_arms
end

--- Feedback: update arm success/failure after evaluation.
function M.feedback(arm_id, converted, ns)
    local state = M.load_state(ns)
    for _, arm in ipairs(state.arms) do
        if arm.id == arm_id then
            bandit.update_arm(arm, converted)
            M.save_state(state, ns)
            alc.log("info", string.format(
                "sourcer: feedback arm=%s converted=%s alpha=%.1f beta=%.1f",
                arm_id, tostring(converted), arm.alpha, arm.beta
            ))
            return arm
        end
    end
    alc.log("warn", "sourcer: feedback arm not found: " .. tostring(arm_id))
    return nil
end

--- Main entry point.
function M.run(ctx)
    local mode = ctx.mode or "extract"

    if mode == "extract" then
        local ideas = M.extract(ctx.raw_posts or {})
        ctx.result = { ideas = ideas }
    elseif mode == "harvest" then
        local arm, err = M.harvest(ctx.namespace)
        ctx.result = { arm = arm, error = err }
    elseif mode == "sprout" then
        local state = M.load_state(ctx.namespace)
        local new_arms = M.sprout(state.arms, ctx.namespace)
        ctx.result = { new_arms = new_arms }
    elseif mode == "feedback" then
        local arm = M.feedback(ctx.arm_id, ctx.converted, ctx.namespace)
        ctx.result = { arm = arm }
    elseif mode == "sources" then
        local state = M.load_state(ctx.namespace)
        ctx.result = { arms = state.arms }
    else
        error("sourcer: unknown mode=" .. tostring(mode))
    end

    return ctx
end

return M
