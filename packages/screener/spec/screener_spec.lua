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

local screener = require("screener")

describe("screener", function()
    describe("rule_filter", function()
        it("rejects enterprise keywords", function()
            local ideas = {
                { text = "SOC2 compliance dashboard for banks" },
                { text = "Simple todo app for freelancers" },
            }
            local passed, rejected = screener.rule_filter(ideas)
            expect(#passed).to.equal(1)
            expect(#rejected).to.equal(1)
            assert(rejected[1].reason:find("enterprise"), "should cite enterprise keyword")
        end)

        it("rejects vague keywords", function()
            local ideas = {
                { text = "Platform for everything in your life" },
                { text = "Invoice tracker for plumbers" },
            }
            local passed, rejected = screener.rule_filter(ideas)
            expect(#passed).to.equal(1)
            expect(#rejected).to.equal(1)
            assert(rejected[1].reason:find("vague"), "should cite vague keyword")
        end)

        it("passes clean ideas through", function()
            local ideas = {
                { text = "Webhook monitoring for Stripe integrations" },
                { text = "Screenshot diff tool for designers" },
            }
            local passed, rejected = screener.rule_filter(ideas)
            expect(#passed).to.equal(2)
            expect(#rejected).to.equal(0)
        end)
    end)

    describe("dedup", function()
        it("removes duplicate ideas by fingerprint", function()
            local ideas = {
                { text = "A cool idea for developers" },
                { text = "A cool idea for developers" },
                { text = "A different idea entirely" },
            }
            local unique, dupes = screener.dedup(ideas, "test_dedup_ns")
            expect(#unique).to.equal(2)
            expect(#dupes).to.equal(1)
        end)
    end)
end)
