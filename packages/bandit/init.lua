--- Thompson Sampling engine for multi-armed bandit optimization.
--- Pure math + optional LLM rationale. No conglo-specific logic.
local M = {}

M.meta = {
    name        = "bandit",
    version     = "0.1.0",
    description = "Thompson Sampling with Beta-Binomial model",
    category    = "optimization",
}

function M.beta_sample(alpha, beta)
    return alc.math.beta_sample(alpha, beta)
end

function M.beta_mean(alpha, beta)
    return alc.math.beta_mean(alpha, beta)
end

function M.beta_variance(alpha, beta)
    return alc.math.beta_variance(alpha, beta)
end

function M.update_arm(arm, converted)
    if converted then
        arm.alpha = arm.alpha + 1
    else
        arm.beta = arm.beta + 1
    end
    arm.ev = M.beta_mean(arm.alpha, arm.beta)
    arm.updated_at = alc.time()
    return arm
end

function M.batch_update(arms, events)
    for _, ev in ipairs(events) do
        for _, arm in ipairs(arms) do
            if arm.id == ev.arm_id then
                M.update_arm(arm, ev.converted)
                break
            end
        end
    end
    return arms
end

local function allocate(arms, total_budget, n_samples, min_pct)
    local rng = alc.math.rng_create(42)
    local wins = {}
    for _, arm in ipairs(arms) do
        if arm.status ~= "inactive" then
            wins[arm.id] = 0
        end
    end

    for _ = 1, n_samples do
        local best_id, best_val = nil, -1
        for _, arm in ipairs(arms) do
            if arm.status ~= "inactive" then
                local sample = alc.math.beta_sample(rng, arm.alpha, arm.beta)
                if sample > best_val then
                    best_val = sample
                    best_id = arm.id
                end
            end
        end
        if best_id then
            wins[best_id] = wins[best_id] + 1
        end
    end

    local active_count = 0
    for _ in pairs(wins) do active_count = active_count + 1 end
    if active_count == 0 then return {} end

    local min_alloc = total_budget * (min_pct / 100)
    local allocations = {}

    for id, w in pairs(wins) do
        local raw = (w / n_samples) * total_budget
        allocations[id] = math.max(raw, min_alloc)
    end

    -- Normalize to total_budget
    local sum = 0
    for _, v in pairs(allocations) do sum = sum + v end
    if sum > 0 then
        for id, v in pairs(allocations) do
            allocations[id] = v / sum * total_budget
        end
    end

    return allocations
end

local function find_kill_candidates(arms, threshold_pct)
    local kills = {}
    for _, arm in ipairs(arms) do
        if arm.status ~= "inactive" then
            local mean = M.beta_mean(arm.alpha, arm.beta)
            if mean < threshold_pct / 100 then
                kills[#kills + 1] = {
                    id = arm.id,
                    name = arm.name,
                    mean = mean,
                    reason = string.format("mean=%.3f < threshold=%.3f", mean, threshold_pct / 100),
                }
            end
        end
    end
    return kills
end

function M.run(ctx)
    local arms           = ctx.arms or error("bandit: ctx.arms required")
    local total_budget   = ctx.total_budget or 100
    local n_samples      = ctx.n_samples or 10000
    local min_pct        = ctx.min_allocation_pct or 5
    local kill_threshold = ctx.kill_threshold_pct or 10

    local allocations = allocate(arms, total_budget, n_samples, min_pct)
    local kills = find_kill_candidates(arms, kill_threshold)

    ctx.result = {
        allocations = allocations,
        kill_candidates = kills,
    }

    alc.log("info", string.format(
        "bandit: allocated %d arms, %d kill candidates",
        #arms, #kills
    ))

    return ctx
end

return M
