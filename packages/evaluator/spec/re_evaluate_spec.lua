local describe, it, expect = lust.describe, lust.it, lust.expect

if not _G.alc then
    _G.alc = {
        math = {
            median = function(vals)
                table.sort(vals)
                return vals[math.floor(#vals / 2 + 0.5)] or 0
            end,
        },
        log = function() end,
    }
end

-- Mock calibrate to avoid LLM calls
package.loaded["calibrate"] = {
    run = function(ctx)
        return { result = { calibrated_value = 0.75 } }
    end,
}
-- Mock panel (required by evaluator top-level)
package.loaded["panel"] = {
    run = function(ctx)
        return { result = { synthesis = "mock" } }
    end,
}

local evaluator = require("evaluator")

describe("evaluator.re_evaluate", function()
    local base_metrics = {
        Pain_level = 7,
        Willingness_to_Pay = 6,
        Purchase_Realism = 5,
        Defensibility = 6,
        Self_Serve_Fit = 7,
        Time_to_MVP = 14,
        Distribution_Fit = 7,
        Implementation_Cost = 4,
    }

    it("grounds WTP upward with strong revenue", function()
        local ctx = evaluator.re_evaluate({
            idea = "Test SaaS idea",
            prior_metrics = base_metrics,
            telemetry = { revenue_usd = 5000, downloads = 100, active_users = 80, months_live = 3 },
        })
        assert(ctx.result, "result missing")
        assert(ctx.result.metrics.Willingness_to_Pay >= base_metrics.Willingness_to_Pay,
            "WTP should increase with strong revenue")
    end)

    it("degrades Defensibility with high churn", function()
        local ctx = evaluator.re_evaluate({
            idea = "Test SaaS idea",
            prior_metrics = base_metrics,
            telemetry = { churn_rate_pct = 25, downloads = 100, active_users = 30, months_live = 6 },
        })
        assert(ctx.result.metrics.Defensibility < base_metrics.Defensibility,
            string.format("Defensibility should decrease: got %d, was %d",
                ctx.result.metrics.Defensibility, base_metrics.Defensibility))
    end)

    it("produces ev_delta between prior and grounded EV", function()
        local ctx = evaluator.re_evaluate({
            idea = "Test SaaS idea",
            prior_metrics = base_metrics,
            telemetry = { revenue_usd = 1000, downloads = 500, active_users = 200, months_live = 4 },
        })
        assert(type(ctx.result.ev_delta) == "number", "ev_delta missing")
        assert(type(ctx.result.prior_ev) == "number", "prior_ev missing")
        assert(type(ctx.result.expected_value) == "number", "expected_value missing")
        assert(math.abs(ctx.result.ev_delta - (ctx.result.expected_value - ctx.result.prior_ev)) < 0.001,
            "ev_delta should equal expected_value - prior_ev")
    end)

    it("returns KILL when telemetry shows product is dead", function()
        local weak_metrics = {
            Pain_level = 3, Willingness_to_Pay = 2, Purchase_Realism = 2,
            Defensibility = 2, Self_Serve_Fit = 3, Time_to_MVP = 60,
            Distribution_Fit = 3, Implementation_Cost = 7,
        }
        local ctx = evaluator.re_evaluate({
            idea = "Test SaaS idea",
            prior_metrics = weak_metrics,
            telemetry = { revenue_usd = 0, downloads = 5, active_users = 0, churn_rate_pct = 80, months_live = 12 },
        })
        assert(ctx.result.decision == "KILL",
            string.format("should KILL: EV=%.3f threshold=%.1f", ctx.result.expected_value, 3.0))
    end)

    it("preserves telemetry and prior_metrics in result", function()
        local telem = { revenue_usd = 2000, downloads = 300 }
        local ctx = evaluator.re_evaluate({
            idea = "Test SaaS idea",
            prior_metrics = base_metrics,
            telemetry = telem,
        })
        assert(ctx.result.telemetry, "telemetry should be preserved in result")
        assert(ctx.result.prior_metrics, "prior_metrics should be preserved in result")
        expect(ctx.result.telemetry.revenue_usd).to.equal(2000)
    end)

    it("includes calibration confidence from calibrate bundled", function()
        local ctx = evaluator.re_evaluate({
            idea = "Test SaaS idea",
            prior_metrics = base_metrics,
            telemetry = { revenue_usd = 1000, downloads = 100 },
        })
        assert(type(ctx.result.calibration_confidence) == "number")
        expect(ctx.result.calibration_confidence).to.equal(0.75)
    end)
end)
