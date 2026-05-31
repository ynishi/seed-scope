--- Market simulator: incumbent analysis + agent-based market simulation.
--- Outputs survival_rate, equilibrium position, expected lifetime.
--- Uses abm bundled (Agent/Model/mc) for Monte Carlo market sim.
local contrastive = require("contrastive")
local calibrate   = require("calibrate")
local abm         = require("abm")

local M = {}

M.meta = {
    name        = "simulator",
    version     = "0.1.0",
    description = "Market simulation with incumbent analysis and ABM Monte Carlo",
    category    = "composite",
}

local cfg = {
    sim_months = 24,
    monte_carlo_runs = 200,
    kill_threshold = 0.3,
}

---------------------------------------------------------------------------
-- Phase 1a: Incumbent absorption analysis
---------------------------------------------------------------------------

local function analyze_incumbent(idea, metrics)
    local ctx = contrastive.run({
        task = string.format(
            "Analyze the competitive landscape for: %s\nMetrics: Pain=%s Def=%s SSF=%s",
            idea,
            tostring(metrics.Pain_level or "?"),
            tostring(metrics.Defensibility or "?"),
            tostring(metrics.Self_Serve_Fit or "?")
        ),
    })

    local calibrated = calibrate.run({
        task = ctx.result and ctx.result.analysis or "",
        scale = "probability",
    })

    return {
        analysis = ctx.result and ctx.result.analysis,
        calibrated_risk = calibrated.result and calibrated.result.calibrated_value,
    }
end

---------------------------------------------------------------------------
-- Phase 1c: Agent-based market simulation via abm bundled
---------------------------------------------------------------------------

local function extract_sim_params(idea, metrics)
    local prompt = string.format([[Extract market simulation parameters for this micro-SaaS idea.

IDEA: %s
METRICS: Pain=%s, WTP=%s, Def=%s, SSF=%s, T=%sd

Return ONLY valid JSON:
{
  "initial_market_size": number (estimated addressable users),
  "monthly_growth_rate": number (0.01 = 1%%),
  "churn_rate": number (monthly, 0.05 = 5%%),
  "acquisition_cost_usd": number,
  "price_usd": number (monthly subscription),
  "incumbent_market_share": number (0-1),
  "switching_barrier": number (0-1, how hard to switch from incumbent)
}]], idea,
        tostring(metrics.Pain_level or 5),
        tostring(metrics.Willingness_to_Pay or 5),
        tostring(metrics.Defensibility or 5),
        tostring(metrics.Self_Serve_Fit or 5),
        tostring(metrics.Time_to_MVP or 30))

    local raw = alc.llm(prompt, {
        system = "You are a market analyst. Output ONLY valid JSON.",
        max_tokens = 400,
    })

    return alc.json_extract(raw)
end

local function define_market_agent(params)
    return abm.Agent.define {
        state = {
            tag       = "market",
            users     = 0,
            revenue   = 0,
            alive     = true,
            budget    = 500,
            acq_cost  = params.acquisition_cost_usd or 50,
            barrier   = params.switching_barrier or 0.3,
            churn     = params.churn_rate or 0.05,
            price     = params.price_usd or 15,
        },
        step = function(self, model)
            if not self.state.alive then return end
            local s = self.state
            local rng_val = model.rng()

            local new_users = math.floor(s.budget / math.max(s.acq_cost, 1))
            new_users = math.floor(new_users * rng_val * 2 * (1 - s.barrier))
            s.users = s.users + new_users

            local churned = math.floor(s.users * s.churn)
            s.users = math.max(s.users - churned, 0)
            s.revenue = s.users * s.price

            if model.step_count > 6 and s.users < 10 then
                s.alive = false
            end
        end,
    }
end

local function run_market_sim(params, n_runs, n_months)
    if not params then
        return { survived_rate = 0.5, final_revenue_median = 0, final_users_median = 0, runs = n_runs }
    end

    local spec = define_market_agent(params)

    return abm.mc.run_model({
        model_fn = function(_seed)
            local m = abm.Model.new()
            abm.Model.add_agents(m, abm.Agent.new(spec))
            return m
        end,
        steps = n_months,
        runs = n_runs,
        extract_fn = function(model)
            local a = model.agents[1]
            return {
                survived = a.state.alive,
                final_users = a.state.users,
                final_revenue = a.state.revenue,
            }
        end,
        extract = { "survived", "final_users", "final_revenue" },
        classify_fn = function(agg)
            local sr = agg.survived_rate or 0
            local rev = agg.final_revenue_median or 0
            if sr < 0.2 then return "dead"
            elseif sr < 0.4 then return "fragile"
            elseif rev < 500 then return "subsistence"
            elseif sr > 0.7 and rev > 2000 then return "niche_leader"
            else return "contested"
            end
        end,
    })
end

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

function M.run(ctx)
    local idea = ctx.task or error("simulator: ctx.task required")
    local metrics = ctx.metrics or {}

    alc.log("info", "simulator: starting analysis")

    -- Phase 1a: Incumbent analysis
    local incumbent = analyze_incumbent(idea, metrics)
    alc.log("info", string.format(
        "simulator: incumbent risk=%.2f",
        incumbent.calibrated_risk or 0
    ))

    -- Phase 1c: ABM Monte Carlo simulation
    local params = extract_sim_params(idea, metrics)
    local sim = run_market_sim(params, cfg.monte_carlo_runs, cfg.sim_months)
    local equilibrium = sim.equilibrium

    local survival_rate = sim.survived_rate or 0
    local median_revenue = sim.final_revenue_median or 0
    local median_users = sim.final_users_median or 0

    alc.log_fmt("info",
        "simulator: survival=%.1f%% [%.1f-%.1f CI] equilibrium=%s revenue=$%d users=%d",
        survival_rate * 100,
        (sim.survived_ci and sim.survived_ci.lower or 0) * 100,
        (sim.survived_ci and sim.survived_ci.upper or 0) * 100,
        tostring(equilibrium),
        median_revenue, median_users
    )

    -- Kill gate
    local kill = survival_rate < cfg.kill_threshold

    -- Offload simulation (ABM trajectory: per-tick stats / agent counts) to
    -- file when ctx.task_dir is provided. Avoids MCP result overflow.
    local sim_path, sim_summary, sim_inline = nil, nil, sim
    if ctx.task_dir and type(ctx.task_dir) == "string" and #ctx.task_dir > 0 then
        local ok_sf, frame = pcall(require, "swarm_frame")
        if ok_sf and frame.artifact_store and frame.backend_artifact_file then
            local ok_off, rel_or_err = pcall(function()
                local backend = frame.backend_artifact_file({ task_dir = ctx.task_dir })
                local store = frame.artifact_store(backend)
                local rel, err = store:offload(sim, { name = "sim.json", format = "json" })
                if not rel then error(err or "offload returned nil") end
                return rel
            end)
            if ok_off then
                sim_path = ctx.task_dir .. "/" .. rel_or_err
                sim_summary = frame.summarize(
                    {
                        equilibrium = equilibrium,
                        survival_rate = survival_rate,
                        median_revenue = median_revenue,
                        median_users = median_users,
                    },
                    { format = "json", max_chars = 300 }
                )
                sim_inline = nil
                alc.log("info", "simulator: simulation offloaded to " .. sim_path)
            else
                alc.log("warn", "simulator: offload failed, simulation inline: " .. tostring(rel_or_err))
            end
        else
            alc.log("warn", "simulator: swarm_frame artifact_store unavailable; simulation inline")
        end
    end

    ctx.result = {
        incumbent = incumbent,
        simulation = sim_inline,
        equilibrium = equilibrium,
        sim_params = params,
        kill = kill,
        kill_reason = kill and string.format(
            "survival_rate=%.1f%% < threshold=%.1f%%",
            survival_rate * 100, cfg.kill_threshold * 100
        ) or nil,
        sim_path = sim_path,
        sim_summary = sim_summary,
    }

    return ctx
end

return M
