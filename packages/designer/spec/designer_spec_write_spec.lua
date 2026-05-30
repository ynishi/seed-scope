--- Non-LLM test: designer spec.md file write behaviour (Bug#2 verification).
--- Verifies that:
---   (a) result.spec_path is set (string ending in .md)
---   (b) spec.md exists on disk and has non-empty content
---   (c) result.spec is nil (full inline payload was dropped)
---   (d) result.spec_summary is a non-empty string
---   (e) when task_dir is nil the inline fallback path sets result.spec (not nil)
--- Temporary files are written under /tmp to avoid repo pollution.

local describe, it, expect = lust.describe, lust.it, lust.expect

-- ─────────────────────────────────────────────────────────────
-- Stub helpers (minimal subset of install_stubs from e2e_nonllm)
-- ─────────────────────────────────────────────────────────────

local SPEC_CONTENT = "# MVP Spec\n\nProblem: solo devs need X.\n\n## Features\n- auth\n- dashboard\n"

local function install_designer_stubs()
    _G.alc = {
        log        = function() end,
        json_encode = function(t) return tostring(t) end,
        json_extract = function(raw)
            if type(raw) == "table" then return raw end
            return nil
        end,
        -- llm stub: returns competitor list for Phase A, features table for Phase C,
        -- and spec markdown for Phase E; Phase B/D delegate to panel/deliberate mocks.
        llm = function(prompt, _opts)
            -- Phase A: returns competitor array (prompt contains "competitors/alternatives")
            if type(prompt) == "string" and prompt:find("competitors/alternatives") then
                return {
                    { name = "Notion", url = "https://notion.so", price_range = "$10/mo",
                      target = "teams", strengths = {"rich editor"}, weaknesses = {"heavy"},
                      market_position = "leader" },
                }
            end
            -- Phase C: returns feature table (prompt contains "HYGIENE (must-have")
            if type(prompt) == "string" and prompt:find("HYGIENE %(must%-have") then
                return {
                    hygiene = {{ feature = "auth", effort_days = 3, reason = "must have" }},
                    differentiators = {{ feature = "ai summary", effort_days = 5, reason = "unique" }},
                    total_mvp_days = 8,
                    recommended_stack = "Next.js + Supabase",
                }
            end
            -- Phase E: returns spec markdown
            return SPEC_CONTENT
        end,
    }

    -- panel stub
    package.loaded["panel"] = {
        meta = { name = "panel" },
        run  = function(_ctx)
            return { result = { synthesis = "mock synthesis", rounds_completed = 1 } }
        end,
    }

    -- deliberate stub (confidence >= 0.4 → is_scaffold = true)
    package.loaded["deliberate"] = {
        meta = { name = "deliberate" },
        run  = function(_ctx)
            return {
                result = {
                    recommendation = {
                        name          = "Focus MVP",
                        description   = "Build minimal viable product",
                        debate_outcome = "proponent",
                        ranking_wins  = 2,
                    },
                    confidence  = 0.8,
                    principles  = "Focus on pain point",
                    options     = {},
                    debates     = {},
                    ranking_matches = {},
                    total_options   = 3,
                }
            }
        end,
    }

    -- clear designer module cache
    package.loaded["designer"] = nil
end

local function reset_designer()
    _G.alc = nil
    package.loaded["designer"]   = nil
    package.loaded["panel"]      = nil
    package.loaded["deliberate"] = nil
end

-- ─────────────────────────────────────────────────────────────
-- Tests
-- ─────────────────────────────────────────────────────────────

describe("designer spec-write (non-LLM)", function()
    lust.after(reset_designer)

    it("writes spec.md to task_dir and returns spec_path", function()
        install_designer_stubs()
        local tmp = "/tmp/seedscope_spectest_" .. tostring(os.time())
        os.execute("mkdir -p " .. tmp)

        local designer = require("designer")
        local ctx = designer.run({
            task     = "Browser extension that highlights dark patterns on checkout pages",
            task_dir = tmp,
        })

        -- (a) spec_path must be a string ending in .md
        assert(type(ctx.result.spec_path) == "string",
            "spec_path should be a string, got: " .. type(ctx.result.spec_path))
        assert(ctx.result.spec_path:match("%.md$"),
            "spec_path should end with .md, got: " .. ctx.result.spec_path)

        -- (b) file must exist and be non-empty
        local fh = io.open(ctx.result.spec_path, "r")
        assert(fh ~= nil, "spec file should exist at: " .. ctx.result.spec_path)
        local content = fh:read("*a")
        fh:close()
        assert(#content > 0, "spec file content should be non-empty")

        -- (c) full inline spec must be nil (dropped to avoid payload overflow)
        assert(ctx.result.spec == nil,
            "result.spec should be nil when spec_path is set, got: " .. tostring(ctx.result.spec))

        -- (d) spec_summary must be a non-empty string
        assert(type(ctx.result.spec_summary) == "string",
            "spec_summary should be a string, got: " .. type(ctx.result.spec_summary))
        assert(#ctx.result.spec_summary > 0, "spec_summary should be non-empty")

        -- cleanup
        os.remove(ctx.result.spec_path)
        os.execute("rmdir " .. tmp)
    end)

    it("falls back to inline spec when task_dir is nil", function()
        install_designer_stubs()

        local designer = require("designer")
        local ctx = designer.run({
            task = "Invoice tracker for freelance plumbers",
            -- task_dir intentionally omitted
        })

        -- inline fallback: spec must be non-nil, spec_path must be nil
        assert(ctx.result.spec ~= nil,
            "result.spec should be non-nil for inline fallback")
        assert(ctx.result.spec_path == nil,
            "spec_path should be nil for inline fallback, got: " .. tostring(ctx.result.spec_path))
    end)
end)
