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
        log_fmt = function() end,
    }
end

local cfg = require("evaluator.tuning")

describe("evaluator", function()
    describe("tuning config", function()
        it("has required exponent fields", function()
            assert(cfg.exponents, "exponents missing")
            assert(cfg.exponents.alpha, "alpha missing")
            assert(cfg.exponents.beta, "beta missing")
            assert(cfg.exponents.gamma, "gamma missing")
            assert(cfg.exponents.delta, "delta missing")
            assert(cfg.exponents.epsilon, "epsilon missing")
        end)

        it("has kill_threshold", function()
            assert(type(cfg.kill_threshold) == "number")
            assert(cfg.kill_threshold > 0)
        end)
    end)

    describe("EV calculation", function()
        local function calculate_ev(m)
            local e = cfg.exponents
            local t_market = math.max(m.Time_to_MVP, 1)
            local pr = m.Purchase_Realism or 5
            local zeta = e.zeta or 1.5

            local raw = (m.Pain_level ^ e.alpha
                         * m.Willingness_to_Pay ^ e.beta
                         * pr ^ zeta
                         * m.Defensibility ^ e.gamma
                         * m.Self_Serve_Fit ^ e.epsilon)
                        / (t_market ^ e.delta)

            local t_min = math.max(cfg.min_realistic_mvp or 7, 1)
            local max_raw = (10 ^ e.alpha * 10 ^ e.beta * 10 ^ zeta
                             * 10 ^ e.gamma * 10 ^ e.epsilon)
                          / (t_min ^ e.delta)
            local normalized = math.log(1 + raw) / math.log(1 + max_raw) * 100
            return math.floor(normalized * 1000 + 0.5) / 1000
        end

        it("returns higher EV for stronger metrics", function()
            local strong = calculate_ev({
                Pain_level = 9, Willingness_to_Pay = 9, Purchase_Realism = 9,
                Defensibility = 8, Self_Serve_Fit = 9, Time_to_MVP = 7,
            })
            local weak = calculate_ev({
                Pain_level = 2, Willingness_to_Pay = 2, Purchase_Realism = 2,
                Defensibility = 2, Self_Serve_Fit = 2, Time_to_MVP = 90,
            })
            assert(strong > weak, string.format("strong=%.3f should > weak=%.3f", strong, weak))
        end)

        it("penalizes long Time_to_MVP", function()
            local fast = calculate_ev({
                Pain_level = 7, Willingness_to_Pay = 7, Purchase_Realism = 7,
                Defensibility = 7, Self_Serve_Fit = 7, Time_to_MVP = 7,
            })
            local slow = calculate_ev({
                Pain_level = 7, Willingness_to_Pay = 7, Purchase_Realism = 7,
                Defensibility = 7, Self_Serve_Fit = 7, Time_to_MVP = 90,
            })
            assert(fast > slow, "faster MVP should yield higher EV")
        end)

        it("EV is between 0 and 100", function()
            local ev = calculate_ev({
                Pain_level = 5, Willingness_to_Pay = 5, Purchase_Realism = 5,
                Defensibility = 5, Self_Serve_Fit = 5, Time_to_MVP = 30,
            })
            assert(ev >= 0 and ev <= 100, string.format("EV=%.3f out of range", ev))
        end)
    end)
end)
