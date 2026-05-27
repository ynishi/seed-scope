--- EV formula tuning parameters.
--- EV = (Pain^α × WTP^β × PR^ζ × Def^γ × SSF^ε) / T^δ
return {
    exponents = {
        alpha   = 1.0,  -- Pain_level
        beta    = 1.0,  -- Willingness_to_Pay
        zeta    = 1.5,  -- Purchase_Realism (super-linear)
        gamma   = 2.0,  -- Defensibility (squared)
        delta   = 1.5,  -- Time_to_MVP (super-linear)
        epsilon = 1.5,  -- Self_Serve_Fit (super-linear)
    },
    kill_threshold = 3.0,
    min_realistic_mvp = 7,
    self_consistency = {
        sample_count = 5,
    },
}
