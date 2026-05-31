--- E2E tests for seed_scope_orch pipeline with mocked LLM.
--- Follows recipe_deep_panel pattern: install_stubs → fresh require → run.
--- No real LLM calls — all alc.llm / alc.parallel return canned JSON.

local describe, it, expect = lust.describe, lust.it, lust.expect

-- ═══════════════════════════════════════════════════════════════════
-- Stub infrastructure
-- ═══════════════════════════════════════════════════════════════════

local function fresh_store() return {} end

local function install_stubs(store)
    store = store or fresh_store()

    _G.alc = {
        state = {
            get = function(k) return store[k] end,
            set = function(k, v) store[k] = v end,
        },
        log = function() end,
        log_fmt = function() end,
        time = function() return 1000000 end,
        fingerprint = function(text)
            local h = 5381
            for i = 1, #text do
                h = ((h * 33) + string.byte(text, i)) % 2^32
            end
            return string.format("%x", h)
        end,
        json_extract = function(raw)
            if type(raw) == "table" then return raw end
            if type(raw) == "string" then
                local ok, decoded = pcall(function()
                    return (loadstring or load)("return " .. raw)()
                end)
                if ok then return decoded end
                -- Try JSON-like parse for simple cases
                if raw:find("{") then
                    local t = {}
                    for k, v in raw:gmatch('"([%w_]+)"%s*:%s*([%w%."-]+)') do
                        local num = tonumber(v)
                        if num then t[k] = num
                        else t[k] = v:gsub('"', '') end
                    end
                    if next(t) then return t end
                end
            end
            return nil
        end,
        json_encode = function(t) return tostring(t) end,
        math = {
            median = function(vals)
                if #vals == 0 then return 0 end
                table.sort(vals)
                return vals[math.floor(#vals / 2 + 0.5)]
            end,
            rng_create = function(seed) return { state = seed or 1 } end,
            rng_float = function(rng)
                rng.state = (rng.state * 1103515245 + 12345) % 2147483648
                return rng.state / 2147483648
            end,
            beta_sample = function(_rng_or_a, _a_or_b, _b)
                return 0.5
            end,
            beta_mean = function(a, b) return a / (a + b) end,
            beta_variance = function(a, b) return (a*b)/((a+b)^2*(a+b+1)) end,
            percentile = function(vals, p)
                table.sort(vals)
                return vals[math.max(1, math.floor(#vals * p / 100))] or 0
            end,
            wilson_ci = function(count, total)
                local rate = total > 0 and count / total or 0
                return { lower = math.max(0, rate - 0.1), upper = math.min(1, rate + 0.1) }
            end,
        },
        parallel = function(items, fn)
            local results = {}
            for _, item in ipairs(items) do
                local req = fn(item)
                if req and req.prompt then
                    results[#results + 1] = {
                        Pain_level = 7, Willingness_to_Pay = 6,
                        Purchase_Realism = 5, Defensibility = 5,
                        Self_Serve_Fit = 7, Distribution_Fit = 7,
                        Implementation_Cost = 4, Time_to_MVP = 14,
                        kill_reasons = {"market too small", "incumbent strong", "churn risk"},
                        strongest_signal = "strong pain in remote teams",
                    }
                else
                    results[#results + 1] = req
                end
            end
            return results
        end,
        llm = function(_prompt, _opts)
            return {
                incumbent_name = "Notion", price_usd_per_mo = 10,
                feature_count = 50, target_solo_price_usd = 5,
                feature_overlap = "medium", switching_cost_signal = "low",
                Pain_level = 7, Willingness_to_Pay = 6,
                Purchase_Realism = 5, Defensibility = 5,
                Self_Serve_Fit = 7, Distribution_Fit = 7,
                Implementation_Cost = 4, Time_to_MVP = 14,
                kill_reasons = {"m1", "m2", "m3"},
                strongest_signal = "strong pain",
                hygiene = {{feature="auth", effort_days=3, reason="must have"}},
                differentiators = {{feature="ai summary", effort_days=5, reason="unique"}},
                total_mvp_days = 14,
                recommended_stack = "Next.js + Supabase",
            }
        end,
        card = nil,
    }

    -- Mock panel (evaluator dependency)
    package.loaded["panel"] = {
        meta = { name = "panel" },
        run = function(ctx)
            return {
                result = {
                    synthesis = "Mock panel synthesis: strong pain signal, feasible for solo dev.",
                    rounds_completed = 2,
                }
            }
        end,
    }

    -- Mock contrastive (simulator dependency)
    package.loaded["contrastive"] = {
        meta = { name = "contrastive" },
        run = function(ctx)
            return {
                result = {
                    analysis = "Mock contrastive: moderate incumbent risk, niche defensible.",
                }
            }
        end,
    }

    -- Mock calibrate (simulator + evaluator dependency)
    package.loaded["calibrate"] = {
        meta = { name = "calibrate" },
        run = function(ctx)
            return {
                result = {
                    calibrated_value = 0.35,
                }
            }
        end,
    }

    -- Mock deliberate (designer dependency)
    package.loaded["deliberate"] = {
        meta = { name = "deliberate" },
        run = function(ctx)
            return {
                result = {
                    recommendation = {
                        name = "Focus MVP",
                        description = "Build minimal viable product",
                        debate_outcome = "proponent",
                        ranking_wins = 2,
                    },
                    confidence = 0.8,
                    principles = "Focus on pain point",
                    options = {},
                    debates = {},
                    ranking_matches = {},
                    total_options = 3,
                }
            }
        end,
    }

    -- Mock SwarmFrame + flow (seed_scope_orch dependency)
    local frame_registry = {}
    local frame_state_data = {}
    local frame_step_done = {}

    package.loaded["swarm_frame"] = {
        init = function() end,
        register = function(path, _spec, handler)
            frame_registry[path] = handler
        end,
        state_new = function()
            return {
                get = function(_, k) return frame_state_data[k] end,
                set = function(_, k, v) frame_state_data[k] = v end,
                step_mark = function(_, step) frame_step_done[step] = true end,
                step_done = function(_, step) return frame_step_done[step] == true end,
            }
        end,
        step_id_of = function(path)
            return path:match("/([^/]+)$") or path
        end,
        run_linear = function(paths, ctx)
            for _, path in ipairs(paths) do
                local handler = frame_registry[path]
                if handler then
                    local step_id = path:match("/([^/]+)/[^/]+$") or path
                    if not frame_step_done[step_id] then
                        local verdict = handler(ctx, {})
                        if verdict and verdict:find("DONE") then
                            frame_step_done[step_id] = true
                        end
                    end
                end
            end
        end,
    }

    package.loaded["swarm_frame_algocline"] = {
        make_dispatcher = function(_opts)
            return function() return "mock_dispatch" end
        end,
        resolve_task_dir = function(_opts)
            -- E2E non-LLM mock: skip filesystem mkdir, return nil so orch
            -- falls back to inline (no offload, no file I/O).
            return nil, "stub: task_dir disabled in non-LLM spec"
        end,
    }

    package.loaded["flow"] = {
        state_new = function(_opts)
            return { data = {} }
        end,
        state_save = function() end,
    }

    -- Clear cached modules to force fresh require
    for _, k in ipairs({
        "seed_scope_orch", "evaluator", "evaluator.tuning",
        "simulator", "designer", "screener",
        "sourcer", "portfolio", "bandit",
    }) do
        package.loaded[k] = nil
    end

    -- Reset frame state between tests
    frame_state_data = {}
    frame_step_done = {}
    frame_registry = {}

    return store
end

local function reset()
    _G.alc = nil
    for _, k in ipairs({
        "seed_scope_orch", "evaluator", "evaluator.tuning",
        "simulator", "designer", "screener",
        "sourcer", "portfolio", "bandit",
        "panel", "contrastive", "calibrate", "deliberate",
        "swarm_frame", "swarm_frame_algocline", "flow",
        "abm", "abm.mc", "abm.frame.agent", "abm.frame.model",
        "abm.frame.scheduler", "abm.stats", "abm.sweep",
    }) do
        package.loaded[k] = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════
-- E2E: evaluate mode
-- ═══════════════════════════════════════════════════════════════════

describe("seed_scope_orch E2E (evaluate mode, non-LLM)", function()
    lust.after(reset)

    it("runs full evaluate pipeline and produces SCAFFOLD/KILL decision", function()
        local store = install_stubs()
        local orch = require("seed_scope_orch")
        local ctx = orch.run({
            mode = "evaluate",
            task = "A browser extension that highlights dark patterns on checkout pages",
            namespace = "e2e_test",
        })

        assert(ctx.result, "result missing")
        assert(ctx.result.mode == "evaluate", "mode should be evaluate")
        assert(ctx.result.entries, "entries missing")
        assert(#ctx.result.entries > 0, "should have at least 1 entry")
        assert(ctx.result.counts, "counts missing")
        assert(type(ctx.result.counts.evaluated) == "number", "counts.evaluated should be number")

        local first = ctx.result.entries[1]
        assert(first.decision == "SCAFFOLD" or first.decision == "KILL",
            "decision should be SCAFFOLD or KILL, got: " .. tostring(first.decision))
    end)

    it("produces simulation results with equilibrium", function()
        local store = install_stubs()
        local orch = require("seed_scope_orch")
        local ctx = orch.run({
            mode = "evaluate",
            task = "Invoice tracker for freelance plumbers",
            namespace = "e2e_test_sim",
        })

        assert(ctx.result.entries, "entries missing")
        assert(ctx.result.counts, "counts missing")
        -- sim runs only on SCAFFOLD; killed entries have sim_kill=nil
        assert(ctx.result.counts.sim_survive ~= nil or ctx.result.counts.killed ~= nil,
            "should have sim_survive or killed counts")
    end)

    it("produces design specs for surviving ideas", function()
        local store = install_stubs()
        local orch = require("seed_scope_orch")
        local ctx = orch.run({
            mode = "evaluate",
            task = "Slack bot that auto-summarizes threads",
            namespace = "e2e_test_design",
        })

        if (ctx.result.counts and ctx.result.counts.sim_survive or 0) > 0 then
            -- At least one entry should carry design output (spec_path or spec_summary or design_decision)
            local has_design = false
            for _, e in ipairs(ctx.result.entries) do
                if e.spec_path or e.spec_summary or e.design_decision then
                    has_design = true; break
                end
            end
            assert(has_design, "at least one entry should carry design output")
        end
    end)
end)

-- ═══════════════════════════════════════════════════════════════════
-- E2E: status mode
-- ═══════════════════════════════════════════════════════════════════

describe("seed_scope_orch E2E (status mode, non-LLM)", function()
    lust.after(reset)

    it("returns portfolio state without LLM calls", function()
        local store = install_stubs()
        local orch = require("seed_scope_orch")
        local ctx = orch.run({
            mode = "status",
            namespace = "e2e_status",
        })

        assert(ctx.result, "result missing")
        assert(type(ctx.result.eval_count) == "number")
        assert(type(ctx.result.arm_count) == "number")
    end)
end)

-- ═══════════════════════════════════════════════════════════════════
-- E2E: re_evaluate mode
-- ═══════════════════════════════════════════════════════════════════

describe("seed_scope_orch E2E (re_evaluate mode, non-LLM)", function()
    lust.after(reset)

    it("grounds prior eval with telemetry and updates EV", function()
        local store = install_stubs()

        -- First: run evaluate to create a prior entry
        local orch = require("seed_scope_orch")
        orch.run({
            mode = "evaluate",
            task = "Webhook monitor for Stripe",
            namespace = "e2e_reeval",
        })

        -- Reset modules but keep store (portfolio state persists)
        for _, k in ipairs({
            "seed_scope_orch", "evaluator", "evaluator.tuning",
            "simulator", "designer", "screener",
            "sourcer", "portfolio", "bandit",
        }) do
            package.loaded[k] = nil
        end

        -- Re-evaluate with telemetry
        orch = require("seed_scope_orch")
        local ctx = orch.run({
            mode = "re_evaluate",
            task = "Webhook monitor for Stripe",
            namespace = "e2e_reeval",
            telemetry = {
                downloads = 500,
                revenue_usd = 2000,
                active_users = 200,
                churn_rate_pct = 5,
                months_live = 3,
            },
        })

        assert(ctx.result, "result missing")
        assert(ctx.result.mode == "re_evaluate")
        assert(ctx.result.re_eval, "re_eval result missing")
        assert(type(ctx.result.re_eval.expected_value) == "number", "EV missing")
        assert(type(ctx.result.re_eval.ev_delta) == "number", "ev_delta missing")
        assert(ctx.result.re_eval.telemetry, "telemetry should be preserved")
        assert(ctx.result.re_eval.prior_metrics, "prior_metrics should be preserved")
    end)
end)
