# By default, Julia/LLVM does not use fused multiply-add operations (FMAs).
# Since these FMAs can increase the performance of many numerical algorithms,
# we need to opt-in explicitly.
# See https://ranocha.de/blog/Optimizing_EC_Trixi for further details.
@muladd begin
#! format: noindent

@doc raw"""
    PolytropicEulerEquations2D(gamma, kappa)

The polytropic Euler equations
```math
\partial t
\begin{pmatrix}
\rho \\ \rho v_1 \\ \rho v_2
\end{pmatrix}
+
\partial x
\begin{pmatrix}
 \rho v_1 \\ \rho v_1^2 + \kappa\rho^\gamma \\ \rho v_1 v_2
\end{pmatrix}
+
\partial y
\begin{pmatrix}
\rho v_2 \\ \rho v_1 v_2 \\ \rho v_2^2 + \kappa\rho^\gamma
\end{pmatrix}
=
\begin{pmatrix}
0 \\ 0 \\ 0
\end{pmatrix}
```
for an ideal gas with ratio of specific heats `gamma`
in two space dimensions.
Here, ``\rho`` is the density and ``v_1`` and`v_2` the velocities and
```math
p = \kappa\rho^\gamma
```
the pressure, which we replaced using this relation.

"""
struct PolytropicEulerEquations2D{RealT <: Real} <:
       AbstractPolytropicEulerEquations{2, 3}
    gamma::RealT               # ratio of specific heats
    kappa::RealT               # fluid scaling factor

    function PolytropicEulerEquations2D(gamma, kappa)
        gamma_, kappa_ = promote(gamma, kappa)
        new{typeof(gamma_)}(gamma_, kappa_)
    end
end

function varnames(::typeof(cons2cons), ::PolytropicEulerEquations2D)
    ("rho", "rho_v1", "rho_v2")
end
varnames(::typeof(cons2prim), ::PolytropicEulerEquations2D) = ("rho", "v1", "v2")

"""
initial_condition_convergence_test(x, t, equations::PolytropicEulerEquations2D)

Manufactured smooth initial condition used for convergence tests.
"""
function initial_condition_convergence_test(x, t, equations::PolytropicEulerEquations2D)
    # manufactured initial condition from Winters (2019) [0.1007/s10543-019-00789-w]
    # domain must be set to [0, 1] x [0, 1]
    h = 8 + cos(2 * pi * x[1]) * sin(2 * pi * x[2]) * cos(2 * pi * t)

    return SVector(h, h / 2, 3 * h / 2)
end


"""
source_terms_eoc_test_polytropic(u, x, t, equations::PolytropicEulerEquations2D)

"""
@inline function source_terms_convergence_test(u, x, t,
                                               equations::PolytropicEulerEquations2D)
    rho, v1, v2 = cons2prim(u, equations)

    # Residual from Winters (2019) [0.1007/s10543-019-00789-w] eq. (5.2).
    h = 8 + cos(2 * pi * x[1]) * sin(2 * pi * x[2]) * cos(2 * pi * t)
    h_t = -2 * pi * cos(2 * pi * x[1]) * sin(2 * pi * x[2]) * sin(2 * pi * t)
    h_x = -2 * pi * sin(2 * pi * x[1]) * sin(2 * pi * x[2]) * cos(2 * pi * t)
    h_y = 2 * pi * cos(2 * pi * x[1]) * cos(2 * pi * x[2]) * cos(2 * pi * t)

    rho_x = h_x
    rho_y = h_y

    b = equations.kappa * equations.gamma * h^(equations.gamma-1)

    r_1 = h_t + h_x / 2 + 3 / 2 * h_y
    r_2 = h_t / 2 + h_x / 4 + b * rho_x + 3 / 4 * h_y
    r_3 = h_t / 2 + 3 / 4 * h_x + 9 / 4 * h_y + b * rho_y

    return SVector(r_1, r_2, r_3)
end

# Calculate 2D flux for a single point
@inline function flux(u, orientation::Integer, equations::PolytropicEulerEquations2D)
    rho, v1, v2 = cons2prim(u, equations)
    p = pressure(u, equations)

    if orientation == 1
        f1 = rho * v1
        f2 = rho * v1^2 + p
        f3 = rho * v1 * v2
    else
        f1 = rho * v2
        f2 = rho * v2 * v1
        f3 = rho * v2^2 + p
    end
    return SVector(f1, f2, f3)
end

# Calculate 1D flux for a single point in the normal direction
# Note, this directional vector is not normalized
@inline function flux(u, normal_direction::AbstractVector,
                      equations::PolytropicEulerEquations2D)
    rho, v1, v2 = cons2prim(u, equations)
    p = pressure(u, equations)

    v_normal = v1 * normal_direction[1] + v2 * normal_direction[2]
    rho_v_normal = rho * v_normal
    f1 = rho_v_normal
    f2 = rho_v_normal * v1 + p * normal_direction[1]
    f3 = rho_v_normal * v2 + p * normal_direction[2]
    return SVector(f1, f2, f3)
end

@inline function flux(u, orientation::Integer, equations::PolytropicEulerEquations2D)
    rho, rho_v1, rho_v2 = u
    v1 = rho_v1 / rho
    v2 = rho_v2 / rho
    p = pressure(u, equations)

    if orientation == 1
        f1 = rho_v1
        f2 = rho_v1 * v1 + p
        f3 = rho_v1 * v2
    else # orientation == 2
        f1 = rho_v2
        f2 = rho_v2 * v1
        f3 = rho_v2 * v2 + p
    end

    return SVector(f1, f2, f3)
end

"""
flux_winters_etal(u_ll, u_rr, normal_direction,
                  equations::PolytropicEulerEquations2D)

Entropy conserving two-point flux for isothermal or polytropic gases.
Requires a special weighted Stolarsky mean for the evaluation of the density
denoted here as `stolarsky_mean`. Note, for isothermal gases where `gamma = 1`
this `stolarsky_mean` becomes the [`ln_mean`](@ref).

For details see Section 3.2 of the following reference
- Andrew R. Winters, Christof Czernik, Moritz B. Schily & Gregor J. Gassner (2020)
Entropy stable numerical approximations for the isothermal and polytropic
Euler equations
[DOI: 10.1007/s10543-019-00789-w](https://doi.org/10.1007/s10543-019-00789-w)
"""
@inline function flux_winters_etal(u_ll, u_rr, normal_direction::AbstractVector,
                                   equations::PolytropicEulerEquations2D)
    # Unpack left and right state
    rho_ll, v1_ll, v2_ll = cons2prim(u_ll, equations)
    rho_rr, v1_rr, v2_rr = cons2prim(u_rr, equations)
    p_ll = equations.kappa * rho_ll^equations.gamma
    p_rr = equations.kappa * rho_rr^equations.gamma
    v_dot_n_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_dot_n_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    # Compute the necessary mean values
    if equations.gamma == 1.0 # isothermal gas
        rho_mean = ln_mean(rho_ll, rho_rr)
    else # equations.gamma > 1 # polytropic gas
        rho_mean = stolarsky_mean(rho_ll, rho_rr, equations.gamma)
    end
    v1_avg = 0.5 * (v1_ll + v1_rr)
    v2_avg = 0.5 * (v2_ll + v2_rr)
    p_avg = 0.5 * (p_ll + p_rr)

    # Calculate fluxes depending on normal_direction
    f1 = rho_mean * 0.5 * (v_dot_n_ll + v_dot_n_rr)
    f2 = f1 * v1_avg + p_avg * normal_direction[1]
    f3 = f1 * v2_avg + p_avg * normal_direction[2]

    return SVector(f1, f2, f3)
end

# Calculate maximum wave speed for local Lax-Friedrichs-type dissipation as the
# maximum velocity magnitude plus the maximum speed of sound
@inline function max_abs_speed_naive(u_ll, u_rr, orientation::Integer,
                                     equations::PolytropicEulerEquations2D)
    rho_ll, v1_ll, v2_ll = cons2prim(u_ll, equations)
    rho_rr, v1_rr, v2_rr = cons2prim(u_rr, equations)
    p_ll = pressure(u_ll, equations)
    p_rr = pressure(u_rr, equations)

    # Get the velocity value in the appropriate direction
    if orientation == 1
        v_ll = v1_ll
        v_rr = v1_rr
    else # orientation == 2
        v_ll = v2_ll
        v_rr = v2_rr
    end

    # Calculate sound speeds
    c_ll = sqrt(equations.gamma * p_ll / rho_ll)
    c_rr = sqrt(equations.gamma * p_rr / rho_rr)

    λ_max = max(abs(v_ll), abs(v_rr)) + max(c_ll, c_rr)
end

@inline function max_abs_speed_naive(u_ll, u_rr, normal_direction::AbstractVector,
                                     equations::PolytropicEulerEquations2D)
    rho_ll, v1_ll, v2_ll = cons2prim(u_ll, equations)
    rho_rr, v1_rr, v2_rr = cons2prim(u_rr, equations)
    p_ll = pressure(u_ll, equations)
    p_rr = pressure(u_rr, equations)

    # Calculate normal velocities and sound speed
    # left
    v_ll = (v1_ll * normal_direction[1]
            + v2_ll * normal_direction[2])
    c_ll = sqrt(equations.gamma * p_ll / rho_ll)
    # right
    v_rr = (v1_rr * normal_direction[1]
            + v2_rr * normal_direction[2])
    c_rr = sqrt(equations.gamma * p_rr / rho_rr)

    return max(abs(v_ll), abs(v_rr)) + max(c_ll, c_rr) * norm(normal_direction)
end

@inline function min_max_speed_naive(u_ll, u_rr, normal_direction::AbstractVector,
                                     equations::PolytropicEulerEquations2D)
    rho_ll, v1_ll, v2_ll = cons2prim(u_ll, equations)
    rho_rr, v1_rr, v2_rr = cons2prim(u_rr, equations)
    p_ll = equations.kappa * rho_ll^equations.gamma
    p_rr = equations.kappa * rho_rr^equations.gamma

    v_normal_ll = v1_ll * normal_direction[1] + v2_ll * normal_direction[2]
    v_normal_rr = v1_rr * normal_direction[1] + v2_rr * normal_direction[2]

    norm_ = norm(normal_direction)
    # The v_normals are already scaled by the norm
    lambda_min = v_normal_ll - sqrt(equations.gamma * p_ll / rho_ll) * norm_
    lambda_max = v_normal_rr + sqrt(equations.gamma * p_rr / rho_rr) * norm_

    return lambda_min, lambda_max
end

@inline function max_abs_speeds(u, equations::PolytropicEulerEquations2D)
    rho, v1, v2 = cons2prim(u, equations)
    c = sqrt(equations.gamma * equations.kappa * rho^(equations.gamma - 1))

    return abs(v1) + c, abs(v2) + c
end

# Convert conservative variables to primitive
@inline function cons2prim(u, equations::PolytropicEulerEquations2D)
    rho, rho_v1, rho_v2 = u

    v1 = rho_v1 / rho
    v2 = rho_v2 / rho

    return SVector(rho, v1, v2)
end

# Convert conservative variables to entropy
@inline function cons2entropy(u, equations::PolytropicEulerEquations2D)
    rho, rho_v1, rho_v2 = u

    v1 = rho_v1 / rho
    v2 = rho_v2 / rho
    v_square = v1^2 + v2^2
    p = pressure(u, equations)
    # Form of the internal energy depends on gas type
    if equations.gamma == 1.0 # isothermal gas
        internal_energy = equations.kappa * log(rho)
    else # equations.gamma > 1 # polytropic gas
        internal_energy = equations.kappa * rho^equations.gamma /
                          (equations.gamma - 1.0)
    end

    w1 = internal_energy + p / rho - 0.5 * v_square
    w2 = v1
    w3 = v2

    return SVector(w1, w2, w3)
end

# Convert primitive to conservative variables
@inline function prim2cons(prim, equations::PolytropicEulerEquations2D)
    rho, v1, v2 = prim
    rho_v1 = rho * v1
    rho_v2 = rho * v2
    return SVector(rho, rho_v1, rho_v2)
end

@inline function density(u, equations::PolytropicEulerEquations2D)
    rho = u[1]
    return rho
end

@inline function pressure(u, equations::PolytropicEulerEquations2D)
    rho, rho_v1, rho_v2 = u
    p = equations.kappa * rho^equations.gamma
    return p
end

end # @muladd
