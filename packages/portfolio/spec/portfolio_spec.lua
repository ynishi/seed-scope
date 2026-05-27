local describe, it, expect = lust.describe, lust.it, lust.expect

if not _G.alc then
    local state_store = {}
    _G.alc = {
        state = {
            get = function(key) return state_store[key] end,
            set = function(key, val) state_store[key] = val end,
        },
        time = function() return 1000 end,
        fingerprint = function(text)
            local h = 5381
            for i = 1, #text do
                h = ((h * 33) + string.byte(text, i)) % 2^32
            end
            return string.format("%x", h)
        end,
        log = function() end,
    }
end

local portfolio = require("portfolio")

describe("portfolio", function()
    describe("make_fingerprint", function()
        it("returns consistent hash for same input", function()
            local fp1 = portfolio.make_fingerprint("test idea")
            local fp2 = portfolio.make_fingerprint("test idea")
            expect(fp1).to.equal(fp2)
        end)

        it("returns different hash for different input", function()
            local fp1 = portfolio.make_fingerprint("idea A")
            local fp2 = portfolio.make_fingerprint("idea B")
            expect(fp1).to_not.equal(fp2)
        end)
    end)

    describe("make_id", function()
        it("lowercases and replaces non-alphanumeric", function()
            expect(portfolio.make_id("My Cool Theme")).to.equal("my_cool_theme")
        end)

        it("strips trailing underscores", function()
            expect(portfolio.make_id("trailing---")).to.equal("trailing")
        end)
    end)

    describe("load/save", function()
        it("returns empty portfolio when none exists", function()
            local p = portfolio.load("test_ns_empty")
            expect(p.arms).to.exist()
            expect(#p.arms).to.equal(0)
        end)

        it("round-trips portfolio data", function()
            local p = { arms = {{ id = "x" }}, ideas = {} }
            portfolio.save(p, "test_ns_rt")
            local loaded = portfolio.load("test_ns_rt")
            expect(#loaded.arms).to.equal(1)
            expect(loaded.arms[1].id).to.equal("x")
        end)
    end)

    describe("record_evaluation", function()
        it("records and retrieves evaluation", function()
            local result = { decision = "SCAFFOLD", expected_value = 42 }
            local entry = portfolio.record_evaluation("test idea", result, nil, "test_ns_eval")
            expect(entry.fingerprint).to.exist()
            expect(entry.result.decision).to.equal("SCAFFOLD")

            local history = portfolio.load_history("test_ns_eval")
            assert(#history > 0, "history should have entries")
        end)
    end)

    describe("record_gate_result", function()
        it("records gate rejection", function()
            local entry = portfolio.record_gate_result(
                "bad idea", "GATE_REJECT", "enterprise keyword", nil, nil, "test_ns_gate"
            )
            expect(entry.result.gate_reject).to.equal(true)
            expect(entry.result.reason).to.equal("enterprise keyword")
        end)
    end)

    describe("to_card_payload", function()
        it("builds card payload from entry", function()
            local entry = { idea = "A cool SaaS for developers" }
            local result = {
                decision = "SCAFFOLD",
                expected_value = 25.5,
                metrics = { Pain_level = 8, Willingness_to_Pay = 7, Purchase_Realism = 6,
                            Defensibility = 5, Self_Serve_Fit = 9, Time_to_MVP = 14 },
            }
            local payload = portfolio.to_card_payload(entry, result, nil)
            expect(payload.category).to.equal("seedscope.eval")
            assert(payload.title:find("eval:"), "title should start with eval:")
        end)
    end)
end)
