--- SeedScope orchestrator: SwarmFrame-based pipeline.
--- source → screen → bundle → evaluate → simulate → design → record
---
--- ALL modes go through the same frame.run_linear pipeline.
--- Mode difference = which steps are pre-completed + initial state setup.
local flow    = require("flow")
local frame   = require("swarm_frame")
local adapter = require("swarm_frame_algocline")

local sourcer   = require("sourcer")
local screener  = require("screener")
local evaluator = require("evaluator")
local simulator = require("simulator")
local designer  = require("designer")
local portfolio = require("portfolio")

local M = {}

M.meta = {
    name        = "seed_scope_orch",
    version     = "0.1.0",
    description = "Idea validation pipeline orchestrator (SwarmFrame)",
    category    = "orchestrator",
}

---------------------------------------------------------------------------
-- Step paths (single pipeline, all modes share this)
---------------------------------------------------------------------------

local PATHS = {
    "/seed_scope_orch/source/sourcer",
    "/seed_scope_orch/screen/screener",
    "/seed_scope_orch/bundle/evaluator",
    "/seed_scope_orch/evaluate/evaluator",
    "/seed_scope_orch/simulate/simulator",
    "/seed_scope_orch/design/designer",
    "/seed_scope_orch/record/recorder",
}

---------------------------------------------------------------------------
-- Pure Lua step handlers
--
-- Contract: function(ctx, spec) -> "DONE path=ok" | "BLOCKED reason=..."
--   - Use ctx.state:get/set for inter-step data
--   - Do NOT call step_mark / commit (run_linear does this)
---------------------------------------------------------------------------

local function handle_source(ctx, _spec)
    local raw_posts = ctx.raw_posts or {}
    if #raw_posts == 0 then
        alc.log("warn", "seed_scope_orch/source: no raw_posts")
        ctx.state:set("ideas", {})
        return "DONE path=ok"
    end
    local ideas = sourcer.extract(raw_posts)
    ctx.state:set("ideas", ideas)
    alc.log("info", string.format("seed_scope_orch/source: %d ideas from %d posts", #ideas, #raw_posts))
    return "DONE path=ok"
end

local function handle_screen(ctx, _spec)
    local ideas = ctx.state:get("ideas") or {}
    if #ideas == 0 then
        ctx.state:set("survivors", {})
        return "DONE path=ok"
    end
    local screen_ctx = screener.run({ ideas = ideas, namespace = ctx.namespace })
    local survivors = screen_ctx.result and screen_ctx.result.survivors or {}
    ctx.state:set("survivors", survivors)
    ctx.state:set("screen_stats", screen_ctx.result and screen_ctx.result.stats)
    alc.log("info", string.format("seed_scope_orch/screen: %d -> %d survivors", #ideas, #survivors))
    return "DONE path=ok"
end

local function handle_bundle(ctx, _spec)
    local survivors = ctx.state:get("survivors") or {}
    if #survivors == 0 then return "DONE path=ok" end

    local bundle_raws = alc.parallel(survivors, function(candidate)
        return evaluator.bundle_request(candidate.text, nil)
    end)

    for i, raw in ipairs(bundle_raws) do
        survivors[i].reference_bundle = evaluator.parse_bundle(raw)
    end
    ctx.state:set("survivors", survivors)
    alc.log("info", string.format("seed_scope_orch/bundle: %d bundles", #survivors))
    return "DONE path=ok"
end

local function handle_evaluate(ctx, _spec)
    local survivors = ctx.state:get("survivors") or {}
    if #survivors == 0 then return "DONE path=ok" end

    local results = {}
    for i, candidate in ipairs(survivors) do
        alc.log("info", string.format("seed_scope_orch/evaluate: %d/%d", i, #survivors))
        local eval_ctx = evaluator.run({
            task = candidate.text,
            reference_bundle = candidate.reference_bundle,
        })
        results[#results + 1] = { candidate = candidate, result = eval_ctx.result }
    end

    local scaffolded, killed = {}, {}
    for _, r in ipairs(results) do
        if r.result and r.result.decision == "SCAFFOLD" then
            scaffolded[#scaffolded + 1] = r
        else
            killed[#killed + 1] = r
        end
    end

    ctx.state:set("eval_results", results)
    ctx.state:set("scaffolded", scaffolded)
    ctx.state:set("killed", killed)
    alc.log("info", string.format("seed_scope_orch/evaluate: %d SCAFFOLD, %d KILL", #scaffolded, #killed))
    return "DONE path=ok"
end

local function handle_simulate(ctx, _spec)
    local scaffolded = ctx.state:get("scaffolded") or {}
    if #scaffolded == 0 then return "DONE path=ok" end

    local sim_survivors = {}
    for i, entry in ipairs(scaffolded) do
        alc.log("info", string.format("seed_scope_orch/simulate: %d/%d", i, #scaffolded))
        local sim_ctx = simulator.run({
            task = entry.candidate.text,
            metrics = entry.result and entry.result.metrics or {},
        })
        if sim_ctx.result and sim_ctx.result.kill then
            alc.log("info", string.format("seed_scope_orch/simulate: KILL — %s", sim_ctx.result.kill_reason or ""))
            entry.result.decision = "KILL"
        else
            sim_survivors[#sim_survivors + 1] = {
                candidate = entry.candidate,
                eval_result = entry.result,
                sim_result = sim_ctx.result,
            }
        end
    end

    ctx.state:set("sim_survivors", sim_survivors)
    alc.log("info", string.format("seed_scope_orch/simulate: %d survive sim", #sim_survivors))
    return "DONE path=ok"
end

local function handle_design(ctx, _spec)
    local sim_survivors = ctx.state:get("sim_survivors") or {}
    if #sim_survivors == 0 then return "DONE path=ok" end

    local designs = {}
    for i, entry in ipairs(sim_survivors) do
        alc.log("info", string.format("seed_scope_orch/design: %d/%d", i, #sim_survivors))
        local design_ctx = designer.run({ task = entry.candidate.text })
        designs[#designs + 1] = {
            candidate = entry.candidate,
            eval_result = entry.eval_result,
            sim_result = entry.sim_result,
            design = design_ctx.result,
        }
    end

    ctx.state:set("designs", designs)
    alc.log("info", string.format("seed_scope_orch/design: %d specs", #designs))
    return "DONE path=ok"
end

local function handle_record(ctx, _spec)
    local results = ctx.state:get("eval_results") or {}
    local ns = ctx.namespace

    for _, r in ipairs(results) do
        local entry = portfolio.record_evaluation(r.candidate.text, r.result, r.candidate.source, ns)
        if r.result.decision == "SCAFFOLD" then
            portfolio.emit_card(entry, r.result, nil, ns)
        end
    end

    alc.log("info", string.format("seed_scope_orch/record: persisted %d evaluations", #results))
    return "DONE path=ok"
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local function register_steps()
    frame.register(PATHS[1], {}, handle_source)
    frame.register(PATHS[2], {}, handle_screen)
    frame.register(PATHS[3], {}, handle_bundle)
    frame.register(PATHS[4], {}, handle_evaluate)
    frame.register(PATHS[5], {}, handle_simulate)
    frame.register(PATHS[6], {}, handle_design)
    frame.register(PATHS[7], {}, handle_record)
end

local function build_instruction(step_id, spec)
    return string.format("=== STEP: %s ===\nReport: DONE path=ok | BLOCKED reason=<text>", step_id)
end

---------------------------------------------------------------------------
-- Mode setup: pre-complete steps + seed state, then run same pipeline
---------------------------------------------------------------------------

local function setup_ingest(ctx, fs)
    -- All steps run. No pre-completion.
end

local function setup_evaluate(ctx, fs)
    -- Skip source/screen: idea is provided directly.
    -- Set up state as if source + screen already ran with 1 survivor.
    local idea = ctx.task or error("seed_scope_orch: ctx.task required for evaluate mode")

    local candidate = { text = idea, source = ctx.source }
    fs:set("ideas", { candidate })
    fs:set("survivors", { candidate })

    -- Mark source and screen as done
    fs:step_mark("source")
    fs:step_mark("screen")

    alc.log("info", "seed_scope_orch/setup_evaluate: source/screen pre-completed, 1 idea seeded")
end

local MODE_SETUP = {
    ingest   = setup_ingest,
    evaluate = setup_evaluate,
}

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

function M.run(ctx)
    local mode = ctx.mode or "evaluate"
    local setup = MODE_SETUP[mode]

    if mode == "status" then
        local p = portfolio.load(ctx.namespace)
        local history = portfolio.load_history(ctx.namespace)
        ctx.result = {
            arm_count = p.arms and #p.arms or 0,
            eval_count = #history,
            portfolio = p,
        }
        return ctx
    end

    if mode == "re_evaluate" then
        local idea = ctx.task or error("seed_scope_orch: ctx.task required for re_evaluate")
        local telemetry = ctx.telemetry or error("seed_scope_orch: ctx.telemetry required for re_evaluate")
        local ns = ctx.namespace

        local history = portfolio.load_history(ns)
        local fp = portfolio.make_fingerprint(idea)
        local prior_entry = portfolio.find_by_fingerprint(history, fp)
        local prior_metrics = prior_entry and prior_entry.result and prior_entry.result.metrics
        if not prior_metrics then
            error("seed_scope_orch: no prior evaluation found for this idea (re_evaluate requires a previous eval)")
        end

        alc.log("info", string.format("seed_scope_orch/re_evaluate: found prior eval id=%s", prior_entry.id or "?"))

        local re_ctx = evaluator.re_evaluate({
            idea = idea,
            prior_metrics = prior_metrics,
            telemetry = telemetry,
            kill_threshold = ctx.kill_threshold,
        })

        local entry = portfolio.record_evaluation(idea, re_ctx.result, {
            type = "re_evaluate",
            telemetry = telemetry,
            prior_eval_id = prior_entry.id,
        }, ns)

        if re_ctx.result.decision == "SCAFFOLD" then
            portfolio.emit_card(entry, re_ctx.result, nil, ns)
        end

        local bandit = require("bandit")
        local converted = re_ctx.result.decision == "SCAFFOLD" and re_ctx.result.ev_delta > 0
        local source_info = prior_entry.source or {}
        if source_info.arm_id then
            local sourcer = require("sourcer")
            sourcer.feedback(source_info.arm_id, converted, ns)
        end

        ctx.result = {
            mode = "re_evaluate",
            prior_eval_id = prior_entry.id,
            re_eval = re_ctx.result,
            portfolio_entry_id = entry.id,
            converted = converted,
        }
        return ctx
    end

    if not setup then error("seed_scope_orch: unknown mode=" .. tostring(mode)) end

    alc.log("info", "seed_scope_orch: mode=" .. mode)

    frame.init({ check_mode = "non-check" })

    local task_id = ctx.task_id or "seedscope-" .. tostring(math.floor(alc.time()))
    local st = flow.state_new({
        key_prefix = "seed_scope_orch",
        id = task_id,
        identity = { task_id = task_id },
        resume = ctx.resume or false,
    })

    local fs = frame.state_new()
    fs:set("task_id", task_id)
    fs:set("namespace", ctx.namespace)

    -- Resume: restore completed steps from flow state
    if st.data and st.data.completed_steps then
        for _, step in ipairs(st.data.completed_steps) do
            fs:step_mark(step)
        end
    end

    -- Mode-specific setup (pre-complete steps, seed state)
    setup(ctx, fs)

    ctx.state = fs
    ctx.dispatcher = adapter.make_dispatcher({
        builder = build_instruction,
        state = st,
    })

    register_steps()
    frame.run_linear(PATHS, ctx)

    -- Sync completed steps from frame state → flow state (disk persistence)
    local completed = {}
    for _, path in ipairs(PATHS) do
        local step_id = frame.step_id_of(path)
        if fs:step_done(step_id) then
            completed[#completed + 1] = step_id
        end
    end
    st.data.completed_steps = completed
    flow.state_save(st)

    -- Collect results from state
    ctx.result = {
        mode = mode,
        screen_stats = fs:get("screen_stats"),
        eval_results = fs:get("eval_results"),
        scaffolded = fs:get("scaffolded"),
        killed = fs:get("killed"),
        sim_survivors = fs:get("sim_survivors"),
        designs = fs:get("designs"),
        pipeline_status = ctx.result and ctx.result.status or "UNKNOWN",
    }

    ctx.dispatcher = nil
    ctx.state = nil
    return ctx
end

return M
