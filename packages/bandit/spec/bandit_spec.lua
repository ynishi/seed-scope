local describe, it, expect = lust.describe, lust.it, lust.expect

if not _G.alc then
    _G.alc = {
        math = {
            beta_sample = function(_rng_or_a, a_or_b, b_or_nil)
                if type(_rng_or_a) == "table" then
                    return 0.5
                end
                return 0.5
            end,
            beta_mean = function(a, b) return a / (a + b) end,
            beta_variance = function(a, b)
                return (a * b) / ((a + b)^2 * (a + b + 1))
            end,
            rng_create = function(seed) return { state = seed } end,
        },
        time = function() return 1000 end,
        log = function() end,
    }
end

local bandit = require("bandit")

describe("bandit", function()
    it("update_arm increments alpha on conversion", function()
        local arm = { alpha = 1, beta = 1 }
        bandit.update_arm(arm, true)
        expect(arm.alpha).to.equal(2)
        expect(arm.beta).to.equal(1)
    end)

    it("update_arm increments beta on non-conversion", function()
        local arm = { alpha = 1, beta = 1 }
        bandit.update_arm(arm, false)
        expect(arm.alpha).to.equal(1)
        expect(arm.beta).to.equal(2)
    end)

    it("batch_update processes multiple events", function()
        local arms = {
            { id = "a", alpha = 1, beta = 1 },
            { id = "b", alpha = 1, beta = 1 },
        }
        bandit.batch_update(arms, {
            { arm_id = "a", converted = true },
            { arm_id = "a", converted = true },
            { arm_id = "b", converted = false },
        })
        expect(arms[1].alpha).to.equal(3)
        expect(arms[2].beta).to.equal(2)
    end)

    it("run produces allocations and kill candidates", function()
        local arms = {
            { id = "a", name = "A", alpha = 10, beta = 2, status = "active" },
            { id = "b", name = "B", alpha = 1, beta = 10, status = "active" },
        }
        local ctx = bandit.run({
            arms = arms,
            total_budget = 100,
            n_samples = 1000,
            min_allocation_pct = 5,
            kill_threshold_pct = 20,
        })

        assert(ctx.result.allocations, "allocations missing")
        assert(ctx.result.allocations["a"], "arm a allocation missing")
        assert(ctx.result.allocations["b"], "arm b allocation missing")

        local total = ctx.result.allocations["a"] + ctx.result.allocations["b"]
        assert(math.abs(total - 100) < 0.01, "allocations should sum to 100")

        assert(type(ctx.result.kill_candidates) == "table")
    end)

    it("inactive arms are excluded from allocation", function()
        local arms = {
            { id = "a", alpha = 5, beta = 5, status = "active" },
            { id = "b", alpha = 5, beta = 5, status = "inactive" },
        }
        local ctx = bandit.run({
            arms = arms,
            total_budget = 100,
            n_samples = 100,
        })
        expect(ctx.result.allocations["b"]).to.equal(nil)
    end)
end)
