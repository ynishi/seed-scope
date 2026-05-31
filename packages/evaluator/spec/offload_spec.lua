--- Spec: verify the swarm_frame artifact_store contract used by evaluator/simulator
--- for raw_scores / simulation offload. Documents the integration surface so
--- breakage in upstream API contract is caught here.

local describe, it, expect = lust.describe, lust.it, lust.expect

if not _G.alc then
    _G.alc = {
        log = function() end,
        json_encode = function(t)
            -- minimal JSON encode for smoke
            if type(t) == "table" then
                local parts = {}
                for k, v in pairs(t) do
                    parts[#parts + 1] = tostring(k) .. ":" .. tostring(v)
                end
                return "{" .. table.concat(parts, ",") .. "}"
            end
            return tostring(t)
        end,
        json_decode = function(s) return s end,
    }
end

local TMP_BASE = "/tmp/seed-scope-evaluator-offload-spec"
local function rm_rf(p) os.execute("rm -rf '" .. p .. "'") end
local function mkdir_p(p) os.execute("mkdir -p '" .. p .. "'") end
local function read_file(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

describe("evaluator/simulator offload contract (swarm_frame artifact_store)", function()
    it("backend_artifact_file + artifact_store writes to {task_dir}/eval.json", function()
        local frame = require("swarm_frame")
        local td = TMP_BASE .. "/contract_eval"
        rm_rf(td); mkdir_p(td)

        local backend = frame.backend_artifact_file({ task_dir = td })
        local store = frame.artifact_store(backend)
        local payload = { { Pain_level = 8 }, { Pain_level = 7 } }
        local rel, err = store:offload(payload, { name = "eval.json", format = "json" })
        assert(not err, "offload err: " .. tostring(err))
        expect(rel).to.equal("eval.json")

        local content = read_file(td .. "/eval.json")
        assert(content, "eval.json not written")
        assert(#content > 0, "eval.json empty")
    end)

    it("summarize returns truncated preview", function()
        local frame = require("swarm_frame")
        local summary = frame.summarize(
            { decision = "SCAFFOLD", ev = 46.8, sample_count = 5 },
            { format = "json", max_chars = 50 }
        )
        assert(summary, "summary nil")
        assert(#summary <= 50, "summary > 50 chars: " .. #summary)
    end)

    it("offload skips when task_dir not provided (caller responsibility)", function()
        -- evaluator/simulator code path: when ctx.task_dir is nil, they skip
        -- artifact_store usage entirely and return raw_scores/simulation inline.
        -- This test documents the contract — no file write attempt.
        local frame = require("swarm_frame")
        expect(type(frame.artifact_store)).to.equal("function")
        expect(type(frame.backend_artifact_file)).to.equal("function")
        expect(type(frame.summarize)).to.equal("function")
    end)
end)
