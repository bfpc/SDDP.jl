#  Copyright 2018, Oscar Dowson
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.
#############################################################################

"""
    StaticPriceInterpolation(; kwargs...)

Constuctor for the static price interpolation value function described in

Gjelsvik, A., Belsnes, M., and Haugstad, A., (1999). An Algorithm for Stochastic
Medium Term Hydro Thermal Scheduling under Spot Price Uncertainty. In PSCC: 13th
Power Systems Computation Conference : Proceedings P. 1328. Trondheim: Executive
Board of the 13th Power Systems Computation Conference, 1999.

### Keyword arguments
 - `dynamics`: a function that takes four arguments
        1. `price`: a Float64 that gives the price in the previous stage.
        2. `noise`: a single `NoiseRealization` of the price noise observed at
            the start of the stage.
        3. `t::Int`: the index of the stage of the problem t=1, 2, ..., T.
        4. `i::Int`: the markov state index of the problem i=1, 2, ..., S(t).
        The function should return a Float64 of the price for the current stage.
 - `initial_price`: a Float64 for the an initial value for each dimension of the price states.
 - `rib_locations`: an `AbstractVector{Float64}` giving the points at which to
    discretize the price dimension.
 - `noise`: a finite-discrete distribution generated by `DiscreteDistribution`
 - `cut_oracle`: any `AbstractCutOracle`

# Example

    StaticPriceInterpolation(
        dynamics = (price, noise, t, i) -> begin
                return price + noise - t
            end,
        initial_price = 50.0
        rib_locations = 0.0:10.0:100.0,
        noise = DiscreteDistribution([-10.0, 40.0], [0.8, 0.2]),
    )
"""
function StaticPriceInterpolation(;
               cut_oracle = DefaultCutOracle(),
                 dynamics = (p,w,t,i)->p,
            initial_price::T = 0.0,
            rib_locations::AbstractVector{T} = [0.0, 1.0],
                    noise = DiscreteDistribution([0.0])
        ) where T
    StaticPriceInterpolation(
        initial_price,
        initial_price,
        collect(rib_locations),
        JuMP.Variable[],
        typeof(cut_oracle)[],
        noise,
        (p)->QuadExpr(p),
        dynamics,
        0.0
    )
end

summarise(::Type{V}) where {V<:StaticPriceInterpolation} = "Static Price Interpolation"

function initializevaluefunction(vf::StaticPriceInterpolation{C, T, T2}, m::JuMP.Model, sense, bound) where {C<:AbstractCutOracle, T, T2}
    vf.bound = bound
    for r in vf.rib_locations
        push!(vf.variables, futureobjective!(sense, m, bound))
        push!(vf.cutoracles, C())
    end
    vf
end

# stage, markov, price, cut
asynccutstoragetype(::Type{StaticPriceInterpolation{C, T, T2}}) where {C<:AbstractCutOracle, T, T2} = Tuple{Int, Int, T, Cut}

function interpolate(vf::StaticPriceInterpolation)
    y = AffExpr(0.0)
    if length(vf.rib_locations) == 1
        append!(y, vf.variables[1])
    else
        upper_idx = length(vf.rib_locations)
        for i in 2:length(vf.rib_locations)
            if vf.location <= vf.rib_locations[i]
                upper_idx = i
                break
            end
        end
        lower_idx = upper_idx - 1
        lambda = (vf.location - vf.rib_locations[lower_idx]) / (vf.rib_locations[upper_idx] - vf.rib_locations[lower_idx])
        if (lambda < 0.0) || (lambda > 1.0)
            error("The location $(vf.location) is outside the interpolated region.")
        end

        append!(y, vf.variables[lower_idx] * (1-lambda))
        append!(y, vf.variables[upper_idx] * lambda)
    end
    y
end

function updatevaluefunction!(m::SDDPModel{V}, settings::Settings, t::Int, sp::JuMP.Model) where V<:StaticPriceInterpolation
    vf = valueoracle(sp)
    ex = ext(sp)
    for (i, (rib, theta, cutoracle)) in enumerate(zip(vf.rib_locations, vf.variables, vf.cutoracles))
        cut = constructcut(m, sp, ex, t, rib)
        if !settings.is_asyncronous && isopen(settings.cut_output_file)
            writecut!(settings.cut_output_file, ex.stage, ex.markovstate, rib, cut)
        end

        storecut!(cutoracle, m, sp, cut)
        addcuttoJuMPmodel!(vf, sp, theta, cut)

        if settings.is_asyncronous
            storeasynccut!(m, sp, rib, cut)
        end
    end
end

function addcuttoJuMPmodel!(vf::StaticPriceInterpolation, sp::JuMP.Model, theta::JuMP.Variable, cut::Cut)
    affexpr = cuttoaffexpr(sp, cut)
    addcutconstraint!(ext(sp).sense, sp, theta, affexpr)
end

function addasynccut!(m::SDDPModel{StaticPriceInterpolation{C,T,T2}}, cut::Tuple{Int, Int, T, Cut}) where {C<:AbstractCutOracle, T, T2}
    sp = getsubproblem(m, cut[1], cut[2])
    vf = valueoracle(sp)
    price_idx = findfirst(vf.rib_locations, cut[3])
    if price_idx < 1
        error("Attempting to add a cut at the price $(cut[3]), but there is no rib in the value function. Rib locations are $(vf.rib_locations).")
    end
    storecut!(vf.cutoracles[price_idx], m, sp, cut[4])
    addcuttoJuMPmodel!(vf, sp, vf.variables[price_idx], cut[4])
end

# ==============================================================================
#   rebuildsubproblem!

function rebuildsubproblem!(m::SDDPModel{V}, sp::JuMP.Model) where V<:StaticPriceInterpolation
    vf = valueoracle(sp)
    n = n_args(m.build!)
    ex = ext(sp)
    for i in 1:nstates(sp)
        pop!(ex.states)
    end
    for i in 1:length(ex.noises)
        pop!(ex.noises)
    end
    sp2 = Model(solver = sp.solver)

    empty!(vf.variables)
    for r in vf.rib_locations
        push!(vf.variables, futureobjective!(optimisationsense(m.sense), sp2, ex.problembound))
    end

    sp2.ext[:SDDP] = ex
    if n == 2
        m.build!(sp2, ex.stage)
    elseif n == 3
        m.build!(sp2, ex.stage, ex.markovstate)
    end

    # re-add cuts
    for i in 1:length(vf.variables)
        for cut in validcuts(vf.cutoracles[i])
            addcuttoJuMPmodel!(vf, sp2, vf.variables[i], cut)
        end
    end
    m.stages[ex.stage].subproblems[ex.markovstate] = sp2
end
rebuildsubproblem!(m::SDDPModel{StaticPriceInterpolation{DefaultCutOracle,T,T2}}, sp::JuMP.Model) where {T,T2} = nothing

# ==============================================================================
#   Plotting

function processvaluefunctiondata(vf::StaticPriceInterpolation{C,Float64,T2}, is_minimization::Bool, states::Union{Float64, AbstractVector{Float64}}...) where {C,T2}
    prices = Float64[]
    cuts   = Cut[]
    for (price, oracle) in zip(vf.rib_locations, vf.cutoracles)
        for cut in validcuts(oracle)
            push!(cuts, cut)
            push!(prices, price)
        end
    end
    _processvaluefunctiondata(prices, cuts, minimum(prices), maximum(prices), is_minimization, Inf, vf.bound, states...)
end
