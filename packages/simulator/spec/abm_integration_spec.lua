local describe, it, expect = lust.describe, lust.it, lust.expect

-- Mock alc.math for spec environment (Model.set_seed needs rng_create/rng_float)
if not _G.alc then
    local seed_state = 0
    _G.alc = {
        math = {
            rng_create = function(seed)
                return { state = seed or 1 }
            end,
            rng_float = function(rng)
                rng.state = (rng.state * 1103515245 + 12345) % 2147483648
                return rng.state / 2147483648
            end,
            median = function(vals)
                table.sort(vals)
                return vals[math.floor(#vals / 2)] or 0
            end,
            percentile = function(vals, p)
                table.sort(vals)
                local idx = math.max(1, math.floor(#vals * p / 100))
                return vals[idx] or 0
            end,
            wilson_ci = function(count, total, _conf)
                local rate = total > 0 and count / total or 0
                return { lower = math.max(0, rate - 0.1), upper = math.min(1, rate + 0.1) }
            end,
        },
        log = function() end,
        log_fmt = function() end,
    }
end

local abm = require("abm")

describe("simulator ABM integration", function()
    it("Agent.define creates a valid spec with step function", function()
        local spec = abm.Agent.define {
            state = { users = 0, alive = true },
            step = function(self, _model)
                self.state.users = self.state.users + 1
            end,
        }
        assert(spec._spec, "expected a spec template")
        assert(type(spec.step) == "function")
    end)

    it("mc.run_model produces aggregate stats with CI", function()
        local spec = abm.Agent.define {
            state = { users = 0, revenue = 0, alive = true },
            step = function(self, model)
                if not self.state.alive then return end
                local r = model.rng()
                self.state.users = self.state.users + math.floor(r * 10)
                local churned = math.floor(self.state.users * 0.05)
                self.state.users = math.max(self.state.users - churned, 0)
                self.state.revenue = self.state.users * 15
                if model.step_count > 6 and self.state.users < 3 then
                    self.state.alive = false
                end
            end,
        }

        local result = abm.mc.run_model({
            model_fn = function(_seed)
                local m = abm.Model.new()
                abm.Model.add_agents(m, abm.Agent.new(spec))
                return m
            end,
            steps = 12,
            runs = 50,
            extract_fn = function(model)
                local a = model.agents[1]
                return {
                    survived = a.state.alive,
                    final_users = a.state.users,
                    final_revenue = a.state.revenue,
                }
            end,
            extract = { "survived", "final_users", "final_revenue" },
            classify_fn = function(agg)
                if (agg.survived_rate or 0) < 0.3 then return "dead"
                else return "alive" end
            end,
        })

        assert(result.runs == 50, "expected 50 runs")
        assert(type(result.survived_rate) == "number", "survived_rate missing")
        assert(result.survived_rate >= 0 and result.survived_rate <= 1, "rate out of range")
        assert(type(result.final_revenue_median) == "number", "revenue median missing")
        assert(type(result.final_users_median) == "number", "users median missing")
        assert(result.survived_ci, "CI missing")
        assert(type(result.survived_ci.lower) == "number", "CI lower missing")
        assert(result.equilibrium, "classify_fn result missing")
    end)

    it("classify_fn receives aggregated data and returns equilibrium", function()
        local spec = abm.Agent.define {
            state = { alive = true },
            step = function() end,
        }

        local classify_called = false
        local result = abm.mc.run_model({
            model_fn = function(_seed)
                local m = abm.Model.new()
                abm.Model.add_agents(m, abm.Agent.new(spec))
                return m
            end,
            steps = 2,
            runs = 5,
            extract_fn = function() return { survived = true } end,
            extract = { "survived" },
            classify_fn = function(agg)
                classify_called = true
                assert(type(agg.survived_rate) == "number")
                return "test_equilibrium"
            end,
        })

        assert(classify_called, "classify_fn was not called")
        assert(result.equilibrium == "test_equilibrium")
    end)
end)
