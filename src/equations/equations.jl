
# Retrieve number of variables from equation instance
@inline nvariables(::AbstractEquations{NDIMS, NVARS}) where {NDIMS, NVARS} = NVARS

# TODO: Taal performance, 1:NVARS vs. Base.OneTo(NVARS) vs. SOneTo(NVARS)
@inline eachvariable(equations::AbstractEquations) = Base.OneTo(nvariables(equations))

"""
    get_name(equations::AbstractEquations)

Returns the canonical, human-readable name for the given system of equations.

# Examples
```jldoctest
julia> Trixi.get_name(CompressibleEulerEquations1D(1.4))
"CompressibleEulerEquations1D"
```
"""
get_name(equations::AbstractEquations) = equations |> typeof |> nameof |> string


# Add methods to show some information on systems of equations.
function Base.show(io::IO, equations::AbstractEquations)
  # Since this is not performance-critical, we can use `@nospecialize` to reduce latency.
  @nospecialize equations # reduce precompilation time

  print(io, get_name(equations), " with ")
  if nvariables(equations) == 1
    print(io, "one variable")
  else
    print(io, nvariables(equations), " variables")
  end
end

function Base.show(io::IO, ::MIME"text/plain", equations::AbstractEquations)
  # Since this is not performance-critical, we can use `@nospecialize` to reduce latency.
  @nospecialize equations # reduce precompilation time

  if get(io, :compact, false)
    show(io, equations)
  else
    summary_header(io, get_name(equations))
    summary_line(io, "#variables", nvariables(equations))
    for variable in eachvariable(equations)
      summary_line(increment_indent(io),
                   "variable " * string(variable),
                   varnames(cons2cons, equations)[variable])
    end
    summary_footer(io)
  end
end


@inline Base.ndims(::AbstractEquations{NDIMS}) where NDIMS = NDIMS


"""
    flux(u, orientation_or_normal, equations)

Given the conservative variables `u`, calculate the (physical) flux in Cartesian
direction `orientation::Integer` or in arbitrary direction `normal::AbstractVector`
for the corresponding set of governing `equations`.
`orientation` is `1`, `2`, and `3` for the x-, y-, and z-directions, respectively.
"""
function flux end


"""
    rotate_to_x(u, normal, equations)

Apply the rotation that maps `normal` onto the x-axis to the convservative variables `u`.
This is used by [`FluxRotated`](@ref) to calculate the numerical flux of rotationally
invariant equations in arbitrary normal directions.

See also: [`rotate_from_x`](@ref)
"""
function rotate_to_x end

"""
    rotate_from_x(u, normal, equations)

Apply the rotation that maps the x-axis onto `normal` to the convservative variables `u`.
This is used by [`FluxRotated`](@ref) to calculate the numerical flux of rotationally
invariant equations in arbitrary normal directions.

See also: [`rotate_to_x`](@ref)
"""
function rotate_from_x end


"""
    BoundaryConditionDirichlet(boundary_value_function)

Create a Dirichlet boundary condition that uses the function `boundary_value_function`
to specify the values at the boundary.
This can be used to create a boundary condition that specifies exact boundary values
by passing the exact solution of the equation.
The passed boundary value function will be called with the same arguments as an initial condition function is called, i.e., as
```julia
boundary_value_function(x, t, equations)
```
where `x` specifies the coordinates, `t` is the current time, and `equation` is the corresponding system of equations.

# Examples
```julia
julia> BoundaryConditionDirichlet(initial_condition_convergence_test)
```
"""
struct BoundaryConditionDirichlet{B}
  boundary_value_function::B
end

# Dirichlet-type boundary condition for use with TreeMesh or CurvedMesh
@inline function (boundary_condition::BoundaryConditionDirichlet)(u_inner, orientation_or_normal,
                                                                  direction,
                                                                  x, t,
                                                                  surface_flux_function, equations)
  u_boundary = boundary_condition.boundary_value_function(x, t, equations)

  # Calculate boundary flux
  if direction in (2, 4, 6) # u_inner is "left" of boundary, u_boundary is "right" of boundary
    flux = surface_flux_function(u_inner, u_boundary, orientation_or_normal, equations)
  else # u_boundary is "left" of boundary, u_inner is "right" of boundary
    flux = surface_flux_function(u_boundary, u_inner, orientation_or_normal, equations)
  end

  return flux
end

# Dirichlet-type boundary condition for use with UnstructuredQuadMesh
# Note: For unstructured we lose the concept of an "absolute direction"
@inline function (boundary_condition::BoundaryConditionDirichlet)(u_inner,
                                                                  normal_direction::AbstractVector,
                                                                  x, t,
                                                                  surface_flux_function, equations)
  # get the external value of the solution
  u_boundary = boundary_condition.boundary_value_function(x, t, equations)

  # Calculate boundary flux
  flux = surface_flux_function(u_inner, u_boundary, normal_direction, equations)

  return flux
end

"""
    BoundaryConditionWall(boundary_value_function)

Create a generic wall type boundary condition that uses the function `boundary_value_function`
to specify the external solution values.
The boundary wall function is called with arguments for an internal solution state from inside an
element `u_inner`, an outward pointing `normal_direction` and a particular set of `equations`, e.g.,
```julia
boundary_value_function(u_inner, normal_direction, equations)
```
which will return an external solution state.

# Example
```julia
julia> BoundaryConditionWall(boundary_state_slip_wall)
```

!!! warning "Experimental code"
    This boundary condition can change any time and is currently only implemented for the
    [`CompressibleEulerEquations2D`](@ref).
"""
struct BoundaryConditionWall{B}
  boundary_value_function::B
end

@inline function (boundary_condition::BoundaryConditionWall)(u_inner,
                                                             normal_direction::AbstractVector,
                                                             x, t,
                                                             surface_flux_function, equations)
  # get the external value of the solution
  u_boundary = boundary_condition.boundary_value_function(u_inner, normal_direction, equations)

  flux = surface_flux_function(u_inner, u_boundary, normal_direction, equations)

  return flux
end


# set sensible default values that may be overwritten by specific equations
have_nonconservative_terms(::AbstractEquations) = Val(false)
have_constant_speed(::AbstractEquations) = Val(false)

default_analysis_errors(::AbstractEquations)     = (:l2_error, :linf_error)
default_analysis_integrals(::AbstractEquations)  = (entropy_timederivative,)


"""
    cons2cons(u, equations)

Return the conserved variables `u`. While this function is as trivial as `identity`,
it is also as useful.
"""
@inline cons2cons(u, ::AbstractEquations) = u
function cons2prim#=(u, ::AbstractEquations)=# end
@inline Base.first(u, ::AbstractEquations) = first(u)

"""
    cons2prim(u, equations)

Convert the conserved variables `u` to the primitive variables for a given set of
`equations`. The inverse conversion is performed by [`prim2cons`](@ref).
"""
function cons2prim end

"""
    prim2cons(u, equations)

Convert the conserved variables `u` to the primitive variables for a given set of
`equations`. The inverse conversion is performed by [`cons2prim`](@ref).
"""
function prim2cons end

"""
    entropy(u, equations)

Return the chosen entropy of the conserved variables `u` for a given set of
`equations`.
"""
function entropy end

"""
    cons2entropy(u, equations)

Convert the conserved variables `u` to the entropy variables for a given set of
`equations` with chosen standard [`entropy`](@ref). The inverse conversion is
performed by [`entropy2cons`](@ref).
"""
function cons2entropy end

"""
    entropy2cons(w, equations)

Convert the entropy variables `w` based on a standard [`entropy`](@ref) to the
conserved variables for a given set of `equations` . The inverse conversion is
performed by [`cons2entropy`](@ref).
"""
function entropy2cons end


"""
    BoundaryConditionCoupled(other_semi_index, indices, uEltype)

Boundary condition to glue 2 meshes together. Solution values at the boundary
of another mesh will be used as boundary values. This requires the use
of [`SemidiscretizationCoupled`](@ref). The other mesh is specified by `other_semi_index`
and is the index of its mesh in the tuple of semidiscretizatios.

# Arguments
- `other_semi_index`: the index in `SemidiscretizationCoupled` of the semidiscretization
                      from which the values are copied
- `indices::Tuple`: node/cell indices at the boundary of the mesh in the other
                    semidiscretization. See examples below.
- `uEltype::Type`: element type of solution

# Examples
'''julia
# Connect the left boundary of mesh 2 to our boundary such that our positive
# boundary direction will match the positive y direction of the other boundary
BoundaryConditionCoupled(2, (1, :i), Float64)

# Connect the same two boundaries oppositely oriented
BoundaryConditionCoupled(2, (1, :mi), Float64)

# Using this as y_neg boundary will connect `our_cells[i, 1, j]` to `other_cells[j, end-i, end]`
BoundaryConditionCoupled(2, (:j, :mi, :end), Float64)
'''                 
"""
mutable struct BoundaryConditionCoupled{NDIMST2M1, uEltype<:Real, I}
  # Buffer for boundary values: [variable, nodes_i, nodes_j, cell_i, cell_j]
  u_boundary       ::Array{uEltype, NDIMST2M1} # NDIMS * 2 - 1
  other_semi_index ::Int
  other_orientation::Int
  indices          ::I

  function BoundaryConditionCoupled(other_semi_index, indices, uEltype)
    NDIMS = length(indices)
    u_boundary = Array{uEltype, NDIMS*2-1}(undef, ntuple(_ -> 0, NDIMS*2-1))

    # This is needed to make indices a Tuple of Symbols and prevent type instabilities
    function one_to_symbol(i)
      if i == 1
        return :one
      else
        return i
      end
    end
    indices_ = one_to_symbol.(indices)

    if indices_[1] in (:one, :end)
      other_orientation = 1
    elseif indices_[2] in (:one, :end)
      other_orientation = 2
    else
      other_orientation = 3
    end
    
    new{NDIMS*2-1, uEltype, typeof(indices_)}(u_boundary, other_semi_index, other_orientation, indices_)
  end
end


function (boundary_condition::BoundaryConditionCoupled)(u_inner, orientation, direction, 
                                                        cell_indices, surface_node_indices,
                                                        surface_flux_function, equations)
  # get_node_vars(), but we don't have a solver here
  u_boundary = SVector(ntuple(v -> boundary_condition.u_boundary[v, surface_node_indices..., cell_indices...], 
                              Val(nvariables(equations))))

  # Calculate boundary flux
  if direction in (2, 4) # u_inner is "left" of boundary, u_boundary is "right" of boundary
    flux = surface_flux_function(u_inner, u_boundary, orientation, equations)
  else # u_boundary is "left" of boundary, u_inner is "right" of boundary
    flux = surface_flux_function(u_boundary, u_inner, orientation, equations)
  end

  return flux
end


# FIXME: Deprecations introduced in v0.3
@deprecate varnames_cons(equations) varnames(cons2cons, equations)
@deprecate varnames_prim(equations) varnames(cons2prim, equations)
@deprecate flux_upwind(u_ll, u_rr, orientation, equations) flux_godunov(u_ll, u_rr, orientation, equations)
@deprecate calcflux(u, orientation, equations) flux(u, orientation, equations)


####################################################################################################
# Include files with actual implementations for different systems of equations.

# Numerical flux formulations that are independent of the specific system of equations
include("numerical_fluxes.jl")

# Linear scalar advection
abstract type AbstractLinearScalarAdvectionEquation{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("linear_scalar_advection_1d.jl")
include("linear_scalar_advection_2d.jl")
include("linear_scalar_advection_3d.jl")

# Inviscid Burgers
abstract type AbstractInviscidBurgersEquation{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("inviscid_burgers_1d.jl")

# CompressibleEulerEquations
abstract type AbstractCompressibleEulerEquations{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("compressible_euler_1d.jl")
include("compressible_euler_2d.jl")
include("compressible_euler_3d.jl")

# CompressibleEulerMulticomponentEquations
abstract type AbstractCompressibleEulerMulticomponentEquations{NDIMS, NVARS, NCOMP} <: AbstractEquations{NDIMS, NVARS} end
include("compressible_euler_multicomponent_1d.jl")
include("compressible_euler_multicomponent_2d.jl")

# Retrieve number of components from equation instance for the multicomponent case
@inline ncomponents(::AbstractCompressibleEulerMulticomponentEquations{NDIMS, NVARS, NCOMP}) where {NDIMS, NVARS, NCOMP} = NCOMP
@inline eachcomponent(equations::AbstractCompressibleEulerMulticomponentEquations) = Base.OneTo(ncomponents(equations))

# Ideal MHD
abstract type AbstractIdealGlmMhdEquations{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("ideal_glm_mhd_1d.jl")
include("ideal_glm_mhd_2d.jl")
include("ideal_glm_mhd_3d.jl")

# IdealGlmMhdMulticomponentEquations
abstract type AbstractIdealGlmMhdMulticomponentEquations{NDIMS, NVARS, NCOMP} <: AbstractEquations{NDIMS, NVARS} end
include("ideal_glm_mhd_multicomponent_1d.jl")
include("ideal_glm_mhd_multicomponent_2d.jl")

# Retrieve number of components from equation instance for the multicomponent case
@inline ncomponents(::AbstractIdealGlmMhdMulticomponentEquations{NDIMS, NVARS, NCOMP}) where {NDIMS, NVARS, NCOMP} = NCOMP
@inline eachcomponent(equations::AbstractIdealGlmMhdMulticomponentEquations) = Base.OneTo(ncomponents(equations))

# Diffusion equation: first order hyperbolic system
abstract type AbstractHyperbolicDiffusionEquations{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("hyperbolic_diffusion_1d.jl")
include("hyperbolic_diffusion_2d.jl")
include("hyperbolic_diffusion_3d.jl")

# Lattice-Boltzmann equation (advection part only)
abstract type AbstractLatticeBoltzmannEquations{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("lattice_boltzmann_2d.jl")
include("lattice_boltzmann_3d.jl")

# Acoustic perturbation equations
abstract type AbstractAcousticPerturbationEquations{NDIMS, NVARS} <: AbstractEquations{NDIMS, NVARS} end
include("acoustic_perturbation_2d.jl")
