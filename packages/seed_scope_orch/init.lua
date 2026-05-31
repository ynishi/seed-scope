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

    local task_dir = ctx.state:get("task_dir")

    local results = {}
    for i, candidate in ipairs(survivors) do
        alc.log("info", string.format("seed_scope_orch/evaluate: %d/%d", i, #survivors))
        -- Assign stable idea_id (survivor index) for cross-stage spec_<idea_id>/ alignment
        candidate._idea_id = i
        local idea_task_dir = task_dir and (task_dir .. "/spec_" .. i) or nil
        local eval_ctx = evaluator.run({
            task = candidate.text,
            reference_bundle = candidate.reference_bundle,
            task_dir = idea_task_dir,
        })
        local er = eval_ctx.result or {}
        -- Slim eval state: drop raw_scores inline (offloaded to eval.json).
        -- Keep only fields the orch + downstream stages need.
        results[#results + 1] = {
            candidate = candidate,
            result = {
                decision        = er.decision,
                ev              = er.ev,
                expected_value  = er.expected_value,
                metrics         = er.metrics,
                kill_reasons    = er.kill_reasons,
                hard_gate_fails = er.hard_gate_fails,
                sample_count    = er.sample_count,
                eval_path       = er.eval_path,
                eval_summary    = er.eval_summary,
                -- raw_scores only kept when offload failed (inline fallback)
                raw_scores      = er.eval_path == nil and er.raw_scores or nil,
            },
        }
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

    local task_dir = ctx.state:get("task_dir")

    local sim_survivors = {}
    for i, entry in ipairs(scaffolded) do
        alc.log("info", string.format("seed_scope_orch/simulate: %d/%d", i, #scaffolded))
        local idea_id = entry.candidate._idea_id or i
        local idea_task_dir = task_dir and (task_dir .. "/spec_" .. idea_id) or nil
        local sim_ctx = simulator.run({
            task = entry.candidate.text,
            metrics = entry.result and entry.result.metrics or {},
            task_dir = idea_task_dir,
        })
        local sr = sim_ctx.result or {}
        if sr.kill then
            alc.log("info", string.format("seed_scope_orch/simulate: KILL — %s", sr.kill_reason or ""))
            entry.result.decision = "KILL"
        else
            -- Slim sim state: drop simulation inline (offloaded to sim.json).
            sim_survivors[#sim_survivors + 1] = {
                candidate = entry.candidate,
                eval_result = entry.result,
                sim_result = {
                    incumbent     = sr.incumbent,
                    equilibrium   = sr.equilibrium,
                    sim_params    = sr.sim_params,
                    kill          = sr.kill,
                    kill_reason   = sr.kill_reason,
                    sim_path      = sr.sim_path,
                    sim_summary   = sr.sim_summary,
                    -- simulation only kept when offload failed (inline fallback)
                    simulation    = sr.sim_path == nil and sr.simulation or nil,
                },
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

    -- task_dir is resolved once at M.run entry via swarm_frame_algocline.resolve_task_dir
    -- and stored in fs:set("task_dir"). Per-idea sub-dirs (spec_<i>/) are created on demand.
    local task_dir = ctx.state:get("task_dir")

    local designs = {}
    for i, entry in ipairs(sim_survivors) do
        alc.log("info", string.format("seed_scope_orch/design: %d/%d", i, #sim_survivors))
        local idea_id = entry.candidate._idea_id or i
        local idea_task_dir = task_dir and (task_dir .. "/spec_" .. idea_id) or nil
        local design_ctx = designer.run({
            task     = entry.candidate.text,
            task_dir = idea_task_dir,
        })
        local dr = design_ctx.result or {}
        -- Slim design: keep only file paths + summaries. Heavy fields
        -- (competitors / weakness_analysis / features / decision full debate)
        -- are offloaded to {idea_task_dir}/design.json by designer.run when
        -- task_dir is provided. Inline fallback fields are dropped here to
        -- prevent frame state bloat (alc_continue intermediate return).
        designs[#designs + 1] = {
            candidate    = entry.candidate,
            -- Drop heavy eval_result / sim_result inline carry; per-idea
            -- entries[] (final ctx.result) already pulls slim metrics + paths.
            design = {
                competitors_slim = dr.competitors_slim,
                features_slim    = dr.features_slim,
                decision_slim    = dr.decision_slim,
                design_path      = dr.design_path,
                design_summary   = dr.design_summary,
                spec_path        = dr.spec_path,
                spec_summary     = dr.spec_summary,
                -- inline spec only present when file write failed (fallback)
                spec             = dr.spec,
            },
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

    -- Resolve task_dir once at orch entry (avoid per-handler duplication).
    -- Stored in both frame state (for handler access) and flow state.data
    -- (Frame convention: Card metadata auto-attach via swarm_frame_algocline).
    local task_dir, td_err = adapter.resolve_task_dir({
        project_root = ctx.project_root,
        task_id      = task_id,
        namespace    = ctx.namespace,
    })
    if task_dir then
        fs:set("task_dir", task_dir)
        st.data.task_dir = task_dir
        alc.log("info", "seed_scope_orch: task_dir=" .. task_dir)
    else
        alc.log("warn", "seed_scope_orch: task_dir unresolved (" .. tostring(td_err) .. "); offload will fall back to inline")
    end

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

    -- Build slim entries array (per-idea summary with file paths).
    -- Avoids MCP result overflow: heavy payloads (raw_scores, simulation, spec)
    -- are offloaded to {task_dir}/spec_<idea_id>/ by evaluator/simulator/designer.
    local eval_results  = fs:get("eval_results") or {}
    local sim_survivors = fs:get("sim_survivors") or {}
    local designs       = fs:get("designs") or {}

    local sim_by_id, design_by_id = {}, {}
    for _, s in ipairs(sim_survivors) do
        local id = s.candidate and s.candidate._idea_id
        if id then sim_by_id[id] = s end
    end
    for _, d in ipairs(designs) do
        local id = d.candidate and d.candidate._idea_id
        if id then design_by_id[id] = d end
    end

    local entries = {}
    for _, r in ipairs(eval_results) do
        local id = r.candidate and r.candidate._idea_id
        local sim_entry = id and sim_by_id[id]
        local design_entry = id and design_by_id[id]
        local er = r.result or {}
        local sim_r = sim_entry and sim_entry.sim_result or {}
        local des = design_entry and design_entry.design or {}
        local dec_slim = des.decision_slim or {}
        entries[#entries + 1] = {
            idea_id          = id,
            idea_text        = r.candidate and r.candidate.text,
            source           = r.candidate and r.candidate.source,
            decision         = er.decision,
            ev               = er.ev,
            metrics          = er.metrics,
            sample_count     = er.sample_count,
            eval_path        = er.eval_path,
            eval_summary     = er.eval_summary,
            sim_kill         = sim_r.kill,
            sim_kill_reason  = sim_r.kill_reason,
            sim_equilibrium  = sim_r.equilibrium,
            sim_path         = sim_r.sim_path,
            sim_summary      = sim_r.sim_summary,
            spec_path        = des.spec_path,
            spec_summary     = des.spec_summary,
            design_path      = des.design_path,
            design_summary   = des.design_summary,
            design_decision  = dec_slim.recommendation_name,
            design_confidence = dec_slim.confidence,
        }
    end

    ctx.result = {
        mode = mode,
        screen_stats = fs:get("screen_stats"),
        entries = entries,
        counts = {
            evaluated   = #eval_results,
            scaffolded  = #(fs:get("scaffolded") or {}),
            killed      = #(fs:get("killed") or {}),
            sim_survive = #sim_survivors,
            designed    = #designs,
        },
        task_dir = fs:get("task_dir"),
        pipeline_status = ctx.result and ctx.result.status or "UNKNOWN",
    }

    ctx.dispatcher = nil
    ctx.state = nil
    return ctx
end

return M
