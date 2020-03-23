module DgSolver

# Note: there are more includes at the bottom that depend on DG internals
include("interpolation.jl")
include("dg_containers.jl")
include("l2projection.jl")

using ...Trixi
using ..Solvers # Use everything to allow method extension via "function <parent_module>.<method>"
using ...Equations: AbstractEquation, initial_conditions, calcflux!, calcflux_twopoint!,
                    riemann!, sources, calc_max_dt,
	                  cons2entropy, cons2indicator, cons2indicator!, cons2prim
import ...Equations: nvariables # Import to allow method extension
using ...Auxiliary: timer, parameter
using ...Mesh: TreeMesh
using ...Mesh.Trees: leaf_cells, length_at_cell, n_directions, has_neighbor,
                     opposite_direction, has_coarse_neighbor, has_child, has_children
using .Interpolation: interpolate_nodes, calc_dhat, calc_dsplit,
                      polynomial_interpolation_matrix, calc_lhat, gauss_lobatto_nodes_weights,
		      vandermonde_legendre, nodal2modal
import .L2Projection # Import to satisfy Gregor

using StaticArrays: SVector, SMatrix, MMatrix, MArray
using TimerOutputs: @timeit
using Printf: @sprintf, @printf

export Dg
export set_initial_conditions
export nvariables
export equations
export polydeg
export rhs!
export calc_dt
export calc_error_norms
export calc_entropy_timederivative
export analyze_solution
export refine!
export coarsen!
export calc_amr_indicator


# Main DG data structure that contains all relevant data for the DG solver
mutable struct Dg{Eqn <: AbstractEquation, V, N, Np1, NAna, NAnap1} <: AbstractSolver
  equations::Eqn
  elements::ElementContainer{V, N}
  n_elements::Int

  surfaces::SurfaceContainer{V, N}
  n_surfaces::Int

  mortar_type::Symbol
  l2mortars::L2MortarContainer{V, N}
  n_l2mortars::Int
  ecmortars::EcMortarContainer{V, N}
  n_ecmortars::Int

  nodes::SVector{Np1}
  weights::SVector{Np1}
  inverse_weights::SVector{Np1}
  inverse_vandermonde_legendre::SMatrix{Np1, Np1}
  lhat::SMatrix{Np1, 2}

  volume_integral_type::Symbol
  dhat::SMatrix{Np1, Np1}
  dsplit::SMatrix{Np1, Np1}
  dsplit_transposed::SMatrix{Np1, Np1}

  mortar_forward_upper::SMatrix{Np1, Np1}
  mortar_forward_lower::SMatrix{Np1, Np1}
  l2mortar_reverse_upper::SMatrix{Np1, Np1}
  l2mortar_reverse_lower::SMatrix{Np1, Np1}
  ecmortar_reverse_upper::SMatrix{Np1, Np1}
  ecmortar_reverse_lower::SMatrix{Np1, Np1}

  analysis_nodes::SVector{NAnap1}
  analysis_weights::SVector{NAnap1}
  analysis_weights_volume::SVector{NAnap1}
  analysis_vandermonde::SMatrix{NAnap1, Np1}
  analysis_total_volume::Float64

  amr_indicator::Symbol

  element_variables::Dict{Symbol, Union{Vector{Float64}, Vector{Int}}}
end


# Convenience constructor to create DG solver instance
function Dg(equation::AbstractEquation{V}, mesh::TreeMesh, N::Int) where V
  # Get cells for which an element needs to be created (i.e., all leaf cells)
  leaf_cell_ids = leaf_cells(mesh.tree)

  # Initialize element container
  elements = init_elements(leaf_cell_ids, mesh, Val(V), Val(N))
  n_elements = nelements(elements)

  # Initialize surface container
  surfaces = init_surfaces(leaf_cell_ids, mesh, Val(V), Val(N), elements)
  n_surfaces = nsurfaces(surfaces)

  # Initialize mortar containers
  mortar_type = Symbol(parameter("mortar_type", "l2", valid=["l2", "ec"]))
  l2mortars, ecmortars = init_mortars(leaf_cell_ids, mesh, Val(V), Val(N), elements, mortar_type)
  n_l2mortars = nmortars(l2mortars)
  n_ecmortars = nmortars(ecmortars)

  # Sanity check
  if n_l2mortars == 0 && n_ecmortars == 0
    @assert n_surfaces == 2*n_elements ("For 2D and periodic domains and conforming elements, "
                                        * "n_surf must be the same as 2*n_elem")
  end

  # Initialize interpolation data structures
  n_nodes = N + 1
  nodes, weights = gauss_lobatto_nodes_weights(n_nodes)
  inverse_weights = 1 ./ weights
  _, inverse_vandermonde_legendre = vandermonde_legendre(nodes)
  lhat = zeros(n_nodes, 2)
  lhat[:, 1] = calc_lhat(-1.0, nodes, weights)
  lhat[:, 2] = calc_lhat( 1.0, nodes, weights)

  # Initialize differentiation operator
  volume_integral_type = Symbol(parameter("volume_integral_type", "weak_form",
                                          valid=["weak_form", "split_form", "shock_capturing"]))
  dhat = calc_dhat(nodes, weights)
  dsplit = calc_dsplit(nodes, weights)
  dsplit_transposed = transpose(calc_dsplit(nodes, weights))

  # Initialize L2 mortar projection operators
  mortar_forward_upper = L2Projection.calc_forward_upper(n_nodes)
  mortar_forward_lower = L2Projection.calc_forward_lower(n_nodes)
  l2mortar_reverse_upper = L2Projection.calc_reverse_upper(n_nodes, Val(:gauss))
  l2mortar_reverse_lower = L2Projection.calc_reverse_lower(n_nodes, Val(:gauss))
  ecmortar_reverse_upper = L2Projection.calc_reverse_upper(n_nodes, Val(:gauss_lobatto))
  ecmortar_reverse_lower = L2Projection.calc_reverse_lower(n_nodes, Val(:gauss_lobatto))

  # Initialize data structures for error analysis (by default, we use twice the
  # number of analysis nodes as the normal solution)
  NAna = 2 * (n_nodes) - 1
  analysis_nodes, analysis_weights = gauss_lobatto_nodes_weights(NAna + 1)
  analysis_weights_volume = analysis_weights
  analysis_vandermonde = polynomial_interpolation_matrix(nodes, analysis_nodes)
  analysis_total_volume = mesh.tree.length_level_0^ndim

  # Initialize AMR
  amr_indicator = Symbol(parameter("amr_indicator", "n/a",
                                   valid=["n/a", "gauss", "isentropic_vortex"]))

  # Initialize storage for element variables
  element_variables = Dict{Symbol, Union{Vector{Float64}, Vector{Int}}}()
  # Initialize element variables such that they are available in the first solution file
  if volume_integral_type === :shock_capturing
    element_variables[:blending_factor] = zeros(n_elements)
  end

  # Create actual DG solver instance
  dg = Dg{typeof(equation), V, N, n_nodes, NAna, NAna + 1}(
      equation,
      elements, n_elements,
      surfaces, n_surfaces,
      mortar_type,
      l2mortars, n_l2mortars,
      ecmortars, n_ecmortars,
      nodes, weights, inverse_weights, inverse_vandermonde_legendre, lhat,
      volume_integral_type, dhat, dsplit, dsplit_transposed,
      mortar_forward_upper, mortar_forward_lower,
      l2mortar_reverse_upper, l2mortar_reverse_lower,
      ecmortar_reverse_upper, ecmortar_reverse_lower,
      analysis_nodes, analysis_weights, analysis_weights_volume,
      analysis_vandermonde, analysis_total_volume,
      amr_indicator,
      element_variables)

  return dg
end


# Return polynomial degree for a DG solver
@inline polydeg(::Dg{Eqn, V, N}) where {Eqn, V, N} = N


# Return number of nodes in one direction
@inline nnodes(::Dg{Eqn, V, N}) where {Eqn, V, N} = N + 1


# Return system of equations instance for a DG solver
@inline Solvers.equations(dg::Dg) = dg.equations


# Return number of variables for the system of equations in use
@inline nvariables(dg::Dg) = nvariables(equations(dg))


# Return number of degrees of freedom
@inline Solvers.ndofs(dg::Dg) = dg.n_elements * (polydeg(dg) + 1)^ndim


# Count the number of surfaces that need to be created
function count_required_surfaces(mesh::TreeMesh, cell_ids)
  count = 0

  # Iterate over all cells
  for cell_id in cell_ids
    for direction in 1:n_directions(mesh.tree)
      # Only count surfaces in positive direction to avoid double counting
      if direction % 2 == 1
        continue
      end

      # If no neighbor exists, current cell is small and thus we need a mortar
      if !has_neighbor(mesh.tree, cell_id, direction)
        continue
      end

      # Skip if neighbor has children
      neighbor_id = mesh.tree.neighbor_ids[direction, cell_id]
      if has_children(mesh.tree, neighbor_id)
        continue
      end

      count += 1
    end
  end

  return count
end


# Count the number of mortars that need to be created
function count_required_mortars(mesh::TreeMesh, cell_ids)
  count = 0

  # Iterate over all cells and count mortars from perspective of coarse cells
  for cell_id in cell_ids
    for direction in 1:n_directions(mesh.tree)
      # If no neighbor exists, cell is small with large neighbor -> do nothing
      if !has_neighbor(mesh.tree, cell_id, direction)
        continue
      end

      # If neighbor has no children, this is a conforming interface -> do nothing
      neighbor_id = mesh.tree.neighbor_ids[direction, cell_id]
      if !has_children(mesh.tree, neighbor_id)
        continue
      end

      count +=1
    end
  end

  return count
end


# Create element container, initialize element data, and return element container for further use
#
# V: number of variables
# N: polynomial degree
function init_elements(cell_ids, mesh, ::Val{V}, ::Val{N}) where {V, N}
  # Initialize container
  n_elements = length(cell_ids)
  elements = ElementContainer{V, N}(n_elements)

  # Store cell ids
  elements.cell_ids .= cell_ids

  # Determine node locations
  n_nodes = N + 1
  nodes, _ = gauss_lobatto_nodes_weights(n_nodes)

  # Calculate inverse Jacobian and node coordinates
  for element_id in 1:nelements(elements)
    # Get cell id
    cell_id = cell_ids[element_id]

    # Get cell length
    dx = length_at_cell(mesh.tree, cell_id)

    # Calculate inverse Jacobian as 1/(h/2)
    elements.inverse_jacobian[element_id] = 2/dx

    # Calculate node coordinates
    for j = 1:n_nodes
      for i = 1:n_nodes
        elements.node_coordinates[1, i, j, element_id] = (
            mesh.tree.coordinates[1, cell_id] + dx/2 * nodes[i])
        elements.node_coordinates[2, i, j, element_id] = (
            mesh.tree.coordinates[2, cell_id] + dx/2 * nodes[j])
      end
    end
  end

  return elements
end


# Create surface container, initialize surface data, and return surface container for further use
#
# V: number of variables
# N: polynomial degree
function init_surfaces(cell_ids, mesh, ::Val{V}, ::Val{N}, elements) where {V, N}
  # Initialize container
  n_surfaces = count_required_surfaces(mesh, cell_ids)
  surfaces = SurfaceContainer{V, N}(n_surfaces)

  # Connect elements with surfaces
  init_surface_connectivity!(elements, surfaces, mesh)

  return surfaces
end


# Create mortar container, initialize mortar data, and return mortar container for further use
#
# V: number of variables
# N: polynomial degree
function init_mortars(cell_ids, mesh, ::Val{V}, ::Val{N}, elements, mortar_type) where {V, N}
  # Initialize containers
  n_mortars = count_required_mortars(mesh, cell_ids)
  if mortar_type === :l2
    n_l2mortars = n_mortars
    n_ecmortars = 0
  elseif mortar_type === :ec
    n_l2mortars = 0
    n_ecmortars = n_mortars
  else
    error("unknown mortar type '$(mortar_type)'")
  end
  l2mortars = L2MortarContainer{V, N}(n_l2mortars)
  ecmortars = EcMortarContainer{V, N}(n_ecmortars)

  # Connect elements with surfaces and l2mortars
  if mortar_type === :l2
    init_mortar_connectivity!(elements, l2mortars, mesh)
  elseif mortar_type === :ec
    init_mortar_connectivity!(elements, ecmortars, mesh)
  else
    error("unknown mortar type '$(mortar_type)'")
  end

  return l2mortars, ecmortars
end


# Initialize connectivity between elements and surfaces
function init_surface_connectivity!(elements, surfaces, mesh)
  # Construct cell -> element mapping for easier algorithm implementation
  tree = mesh.tree
  c2e = zeros(Int, length(tree))
  for element_id in 1:nelements(elements)
    c2e[elements.cell_ids[element_id]] = element_id
  end

  # Reset surface count
  count = 0

  # Iterate over all elements to find neighbors and to connect via surfaces
  for element_id in 1:nelements(elements)
    # Get cell id
    cell_id = elements.cell_ids[element_id]

    # Loop over directions
    for direction in 1:n_directions(mesh.tree)
      # Only create surfaces in positive direction
      if direction % 2 == 1
        continue
      end

      # If no neighbor exists, current cell is small and thus we need a mortar
      if !has_neighbor(mesh.tree, cell_id, direction)
        continue
      end
      
      # Skip if neighbor has children
      neighbor_cell_id = mesh.tree.neighbor_ids[direction, cell_id]
      if has_children(mesh.tree, neighbor_cell_id)
        continue
      end

      # Create surface between elements (1 -> "left" of surface, 2 -> "right" of surface)
      count += 1
      surfaces.neighbor_ids[2, count] = c2e[neighbor_cell_id]
      surfaces.neighbor_ids[1, count] = element_id

      # Set orientation (x -> 1, y -> 2)
      surfaces.orientations[count] = div(direction, 2)
    end
  end

  @assert count == nsurfaces(surfaces) ("Actual surface count ($count) does not match " *
                                        "expectations $(nsurfaces(surfaces))")
end


# Initialize connectivity between elements and mortars
function init_mortar_connectivity!(elements, mortars, mesh)
  # Construct cell -> element mapping for easier algorithm implementation
  tree = mesh.tree
  c2e = zeros(Int, length(tree))
  for element_id in 1:nelements(elements)
    c2e[elements.cell_ids[element_id]] = element_id
  end

  # Reset surface count
  count = 0

  # Iterate over all elements to find neighbors and to connect via surfaces
  for element_id in 1:nelements(elements)
    # Get cell id
    cell_id = elements.cell_ids[element_id]

    for direction in 1:n_directions(mesh.tree)
      # If no neighbor exists, cell is small with large neighbor -> do nothing
      if !has_neighbor(mesh.tree, cell_id, direction)
        continue
      end

      # If neighbor has no children, this is a conforming interface -> do nothing
      neighbor_cell_id = mesh.tree.neighbor_ids[direction, cell_id]
      if !has_children(mesh.tree, neighbor_cell_id)
        continue
      end

      # Create mortar between elements:
      # 1 -> small element in negative coordinate direction
      # 2 -> small element in positive coordinate direction
      # 3 -> large element
      count += 1
      mortars.neighbor_ids[3, count] = element_id
      if direction == 1
        mortars.neighbor_ids[1, count] = c2e[mesh.tree.child_ids[2, neighbor_cell_id]]
        mortars.neighbor_ids[2, count] = c2e[mesh.tree.child_ids[4, neighbor_cell_id]]
      elseif direction == 2
        mortars.neighbor_ids[1, count] = c2e[mesh.tree.child_ids[1, neighbor_cell_id]]
        mortars.neighbor_ids[2, count] = c2e[mesh.tree.child_ids[3, neighbor_cell_id]]
      elseif direction == 3
        mortars.neighbor_ids[1, count] = c2e[mesh.tree.child_ids[3, neighbor_cell_id]]
        mortars.neighbor_ids[2, count] = c2e[mesh.tree.child_ids[4, neighbor_cell_id]]
      elseif direction == 4
        mortars.neighbor_ids[1, count] = c2e[mesh.tree.child_ids[1, neighbor_cell_id]]
        mortars.neighbor_ids[2, count] = c2e[mesh.tree.child_ids[2, neighbor_cell_id]]
      else
        error("should not happen")
      end

      # Set large side, which denotes the direction (1 -> negative, 2 -> positive) of the large side
      if direction in [2, 4]
        mortars.large_sides[count] = 1
      else
        mortars.large_sides[count] = 2
      end

      # Set orientation (x -> 1, y -> 2)
      if direction in [1, 2]
        mortars.orientations[count] = 1
      else
        mortars.orientations[count] = 2
      end
    end
  end

  @assert count == nmortars(mortars) ("Actual mortar count ($count) does not match " *
                                      "expectations $(nmortars(mortars))")
end


# Calculate L2/Linf error norms based on "exact solution"
function calc_error_norms(dg::Dg, t::Float64)
  # Gather necessary information
  equation = equations(dg)
  n_nodes_analysis = length(dg.analysis_nodes)

  # Set up data structures
  l2_error = zeros(nvariables(equation))
  linf_error = zeros(nvariables(equation))
  u_exact = zeros(nvariables(equation))

  # Iterate over all elements for error calculations
  for element_id = 1:dg.n_elements
    # Interpolate solution and node locations to analysis nodes
    u = interpolate_nodes(dg.elements.u[:, :, :, element_id],
                          dg.analysis_vandermonde, nvariables(equation))
    x = interpolate_nodes(dg.elements.node_coordinates[:, :, :, element_id],
                          dg.analysis_vandermonde, ndim)

    # Calculate errors at each analysis node
    weights = dg.analysis_weights_volume
    jacobian_volume = (1 / dg.elements.inverse_jacobian[element_id])^ndim
    for j = 1:n_nodes_analysis
      for i = 1:n_nodes_analysis
        u_exact = initial_conditions(equation, x[:, i, j], t)
        diff = similar(u_exact)
        @. diff = u_exact - u[:, i, j]
        @. l2_error += diff^2 * weights[i] * weights[j] * jacobian_volume
        @. linf_error = max(linf_error, abs(diff))
      end
    end
  end

  # For L2 error, divide by total volume
  @. l2_error = sqrt(l2_error / dg.analysis_total_volume)

  return l2_error, linf_error
end

# Calculate L2/Linf error norms based on "exact solution"
function calc_entropy_timederivative(dg::Dg, t::Float64)
  # Gather necessary information
  equation = equations(dg)
  n_nodes = nnodes(dg)
  # Compute entropy variables for all elements and nodes with current solution u
  duds = cons2entropy(equation,dg.elements.u,n_nodes,dg.n_elements)
  # Compute ut = rhs(u) with current solution u
  Solvers.rhs!(dg, t, disable_timers=true)
  # Quadrature weights
  weights = dg.weights
  # Integrate over all elements to get the total semi-discrete entropy update
  dsdu_ut = 0.0
  for element_id = 1:dg.n_elements
    jacobian_volume = (1 / dg.elements.inverse_jacobian[element_id])^ndim
    for j = 1:n_nodes
      for i = 1:n_nodes
         dsdu_ut += jacobian_volume*weights[i]*weights[j]*sum(duds[:,i,j,element_id].*dg.elements.u_t[:,i,j,element_id])
      end
    end
  end
  # Normalize with total volume
  dsdu_ut = dsdu_ut/dg.analysis_total_volume
  return dsdu_ut
end

# Calculate error norms and print information for user
function Solvers.analyze_solution(dg::Dg, time::Real, dt::Real, step::Integer,
                                  runtime_absolute::Real, runtime_relative::Real)
  equation = equations(dg)

  l2_error, linf_error = calc_error_norms(dg, time)
  duds_ut = calc_entropy_timederivative(dg, time)

  println()
  println("-"^80)
  println(" Simulation running '$(equation.name)' with N = $(polydeg(dg))")
  println("-"^80)
  println(" #timesteps:    " * @sprintf("% 14d", step))
  println(" dt:            " * @sprintf("%10.8e", dt))
  println(" sim. time:     " * @sprintf("%10.8e", time))
  println(" run time:      " * @sprintf("%10.8e s", runtime_absolute))
  println(" Time/DOF/step: " * @sprintf("%10.8e s", runtime_relative))
  print(" Variable:    ")
  for v in 1:nvariables(equation)
    @printf("  %-14s", equation.varnames_cons[v])
  end
  println()
  print(" L2 error:    ")
  for v in 1:nvariables(equation)
    @printf("  %10.8e", l2_error[v])
  end
  println()
  print(" Linf error:  ")
  for v in 1:nvariables(equation)
    @printf("  %10.8e", linf_error[v])
  end
  println()
  print(" Semi-discrete Entropy update:  ")
  @printf("  %10.8e", duds_ut)

  println()
  println()
end


# Call equation-specific initial conditions functions and apply to all elements
function Solvers.set_initial_conditions(dg::Dg, time::Float64)
  equation = equations(dg)

  for element_id = 1:dg.n_elements
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        dg.elements.u[:, i, j, element_id] .= initial_conditions(
            equation, dg.elements.node_coordinates[:, i, j, element_id], time)
      end
    end
  end
end


# Calculate time derivative
function Solvers.rhs!(dg::Dg, t_stage; disable_timers=false)
  # Run rhs! without timing the individual contributions
  # FIXME: This should be done properly, e.g., by a macro call
  if disable_timers
    dg.elements.u_t .= 0.0
    calc_volume_integral!(dg)
    prolong2surfaces!(dg)
    calc_surface_flux!(dg)
    prolong2mortars!(dg)
    calc_mortar_flux!(dg)
    calc_surface_integral!(dg)
    apply_jacobian!(dg)
    calc_sources!(dg, t_stage)
    return
  end

  # Reset u_t
  @timeit timer() "reset ∂u/∂t" dg.elements.u_t .= 0.0

  # Calculate volume integral
  @timeit timer() "volume integral" calc_volume_integral!(dg)

  # Prolong solution to surfaces
  @timeit timer() "prolong2surfaces" prolong2surfaces!(dg)

  # Calculate surface fluxes
  @timeit timer() "surface flux" calc_surface_flux!(dg)

  # Prolong solution to mortars
  @timeit timer() "prolong2mortars" prolong2mortars!(dg)

  # Calculate mortar fluxes
  @timeit timer() "mortar flux" calc_mortar_flux!(dg)

  # Calculate surface integrals
  @timeit timer() "surface integral" calc_surface_integral!(dg)

  # Apply Jacobian from mapping to reference element
  @timeit timer() "Jacobian" apply_jacobian!(dg)

  # Calculate source terms
  @timeit timer() "source terms" calc_sources!(dg, t_stage)
end


# Calculate volume integral and update u_t
function calc_volume_integral!(dg)
  if dg.volume_integral_type == :weak_form
    calc_volume_integral!(dg, Val(:weak_form), dg.elements.u_t, dg.dhat)
  elseif dg.volume_integral_type == :split_form
    calc_volume_integral!(dg, Val(:split_form), dg.elements.u_t, dg.dsplit_transposed)
  elseif dg.volume_integral_type == :shock_capturing
    calc_volume_integral!(dg, Val(:shock_capturing), dg.elements.u_t, dg.dsplit_transposed)
  else
    error("unknown volume integral type")
  end
end


# Calculate volume integral (DGSEM in weak form)
function calc_volume_integral!(dg, ::Val{:weak_form}, u_t::Array{Float64, 4}, dhat::SMatrix)
  # Type alias only for convenience
  A3d = MArray{Tuple{nvariables(dg), nnodes(dg), nnodes(dg)}, Float64}

  # Pre-allocate data structures to speed up computation (thread-safe)
  f1_threaded = [A3d(undef) for _ in 1:Threads.nthreads()]
  f2_threaded = [A3d(undef) for _ in 1:Threads.nthreads()]

  #=@inbounds Threads.@threads for element_id = 1:dg.n_elements=#
  Threads.@threads for element_id in 1:dg.n_elements
    # Choose thread-specific pre-allocated container
    f1 = f1_threaded[Threads.threadid()]
    f2 = f2_threaded[Threads.threadid()]

    # Calculate volume fluxes
    calcflux!(f1, f2, equations(dg), dg.elements.u, element_id, nnodes(dg))

    # Calculate volume integral
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        for v = 1:nvariables(dg)
          for l = 1:nnodes(dg)
            u_t[v, i, j, element_id] += dhat[i, l] * f1[v, l, j] + dhat[j, l] * f2[v, i, l]
          end
        end
      end
    end
  end
end


# Calculate volume integral (DGSEM in split form)
function calc_volume_integral!(dg, ::Val{:split_form}, u_t::Array{Float64, 4},
                               dsplit_transposed::SMatrix)
  # Type alias only for convenience
  A4d = MArray{Tuple{nvariables(dg), nnodes(dg), nnodes(dg), nnodes(dg)}, Float64}
  A3d = MArray{Tuple{nvariables(dg), nnodes(dg), nnodes(dg)}, Float64}

  # Pre-allocate data structures to speed up computation (thread-safe)
  f1_threaded = [A4d(undef) for _ in 1:Threads.nthreads()]
  f2_threaded = [A4d(undef) for _ in 1:Threads.nthreads()]
  f1_diag_threaded = [A3d(undef) for _ in 1:Threads.nthreads()]
  f2_diag_threaded = [A3d(undef) for _ in 1:Threads.nthreads()]

  #=@inbounds Threads.@threads for element_id = 1:dg.n_elements=#
  Threads.@threads for element_id = 1:dg.n_elements
    # Choose thread-specific pre-allocated container
    f1 = f1_threaded[Threads.threadid()]
    f2 = f2_threaded[Threads.threadid()]
    f1_diag = f1_diag_threaded[Threads.threadid()]
    f2_diag = f2_diag_threaded[Threads.threadid()]

    # Calculate volume fluxes (one more dimension than weak form)
    calcflux_twopoint!(f1, f2, f1_diag, f2_diag, equations(dg), dg.elements.u,
                       element_id, nnodes(dg))

    # Calculate volume integral
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        for v = 1:nvariables(dg)
          for l = 1:nnodes(dg)
            u_t[v, i, j, element_id] += (dsplit_transposed[l, i] * f1[v, l, i, j] +
                                         dsplit_transposed[l, j] * f2[v, l, i, j])
          end
        end
      end
    end
  end
end


# Calculate volume integral (DGSEM in split form with shock capturing)
function calc_volume_integral!(dg, ::Val{:shock_capturing}, u_t::Array{Float64, 4},
                               dsplit_transposed::SMatrix)
  # (Re-)initialize element variable storage for blending factor
  if (!haskey(dg.element_variables, :blending_factor) ||
      length(dg.element_variables[:blending_factor]) != dg.n_elements)
    dg.element_variables[:blending_factor] = Vector{Float64}(undef, dg.n_elements)
  end

  calc_volume_integral!(dg, Val(:shock_capturing), u_t, dsplit_transposed,
                        dg.inverse_weights, dg.element_variables[:blending_factor])
end

function calc_volume_integral!(dg, ::Val{:shock_capturing}, u_t::Array{Float64, 4},
                               dsplit_transposed::SMatrix, inverse_weights::SVector,
                               alpha::Vector{Float64})
  # Calculate blending factors α: u = u_DG * (1 - α) + u_FV * α
  # Note: We need this 'out' shenanigans as otherwise the timer does not work
  # properly and causes a huge increase in memory allocations.
  out = Any[]
  @timeit timer() "blending factors" calc_blending_factors(alpha, out, dg, dg.elements.u)
  element_ids_dg, element_ids_dgfv = out

  # Type alias only for convenience
  A4d = Array{Float64, 4}
  A3d = Array{Float64, 3}
  A3dp1_x = Array{Float64, 3}
  A3dp1_y = Array{Float64, 3}
  A2d = Array{Float64, 2}
  A1d = Array{Float64, 1}

  # Pre-allocate data structures to speed up computation (thread-safe)
  # Note: Prefixing the array with the type ("A4d[A4d(...") seems to be
  # necessary for optimal performance
  f1_threaded = A4d[A4d(undef, nvariables(dg), nnodes(dg), nnodes(dg), nnodes(dg))
                    for _ in 1:Threads.nthreads()]
  f2_threaded = A4d[A4d(undef, nvariables(dg), nnodes(dg), nnodes(dg), nnodes(dg))
                    for _ in 1:Threads.nthreads()]
  f1_diag_threaded = A3d[A3d(undef, nvariables(dg), nnodes(dg), nnodes(dg))
                         for _ in 1:Threads.nthreads()]
  f2_diag_threaded = A3d[A3d(undef, nvariables(dg), nnodes(dg), nnodes(dg))
                         for _ in 1:Threads.nthreads()]
  fstar1_threaded = A3dp1_x[A3dp1_x(undef, nvariables(dg), nnodes(dg)+1, nnodes(dg))
                            for _ in 1:Threads.nthreads()]
  fstar2_threaded = A3dp1_y[A3dp1_y(undef, nvariables(dg), nnodes(dg), nnodes(dg)+1)
                            for _ in 1:Threads.nthreads()]
  u_leftright_threaded = A2d[A2d(undef, 2, nvariables(equations(dg)))
                             for _ in 1:Threads.nthreads()]
  fstarnode_threaded = A1d[A1d(undef, nvariables(dg)) for _ in 1:Threads.nthreads()]

  # Loop over pure DG elements
  #=@timeit timer() "pure DG" @inbounds Threads.@threads for element_id in element_ids_dg=#
  @timeit timer() "pure DG" Threads.@threads for element_id in element_ids_dg
    # Choose thread-specific pre-allocated container
    f1 = f1_threaded[Threads.threadid()]
    f2 = f2_threaded[Threads.threadid()]
    f1_diag = f1_diag_threaded[Threads.threadid()]
    f2_diag = f2_diag_threaded[Threads.threadid()]

    # Calculate volume fluxes (one more dimension than weak form)
    calcflux_twopoint!(f1, f2, f1_diag, f2_diag, equations(dg), dg.elements.u,
                       element_id, nnodes(dg))

    # Calculate volume integral
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        for v = 1:nvariables(dg)
          for l = 1:nnodes(dg)
            u_t[v, i, j, element_id] += (dsplit_transposed[l, i] * f1[v, l, i, j] +
                                         dsplit_transposed[l, j] * f2[v, l, i, j])
          end
        end
      end
    end
  end

  # Loop over blended DG-FV elements
  #=@timeit timer() "blended DG-FV" @inbounds Threads.@threads for element_id in element_ids_dgfv=#
  @timeit timer() "blended DG-FV" Threads.@threads for element_id in element_ids_dgfv
    # Choose thread-specific pre-allocated container
    f1 = f1_threaded[Threads.threadid()]
    f2 = f2_threaded[Threads.threadid()]
    f1_diag = f1_diag_threaded[Threads.threadid()]
    f2_diag = f2_diag_threaded[Threads.threadid()]

    # Calculate volume fluxes (one more dimension than weak form)
    calcflux_twopoint!(f1, f2, f1_diag, f2_diag, equations(dg), dg.elements.u,
                       element_id, nnodes(dg))

    # Calculate DG volume integral contribution
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        for v = 1:nvariables(dg)
          for l = 1:nnodes(dg)
            u_t[v, i, j, element_id] += ((1 - alpha[element_id]) *
                                         (dsplit_transposed[l, i] * f1[v, l, i, j] +
                                          dsplit_transposed[l, j] * f2[v, l, i, j]))
          end
        end
      end
    end

    # Calculate volume fluxes (one more dimension than weak form)
    fstar1 = fstar1_threaded[Threads.threadid()]
    fstar2 = fstar2_threaded[Threads.threadid()]
    u_leftright = u_leftright_threaded[Threads.threadid()]
    fstarnode = fstarnode_threaded[Threads.threadid()]
    calcflux_fv!(fstar1, fstar2, u_leftright, fstarnode, equations(dg),
                 dg.elements.u, element_id, nnodes(dg))

    # Calculate FV volume integral contribution
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        for v = 1:nvariables(dg)
          u_t[v, i, j, element_id] += ((alpha[element_id])
                                       *(inverse_weights[i]*(fstar1[v, i+1, j] - fstar1[v,i,j]) +
                                         inverse_weights[j]*(fstar2[v, i, j+1] - fstar2[v,i,j])))

        end
      end
    end
  end
end


# Calculate 2D two-point flux (element version)
@inline function calcflux_fv!(fstar1::AbstractArray{Float64},
                              fstar2::AbstractArray{Float64},
                              u_leftright::AbstractArray{Float64},
                              fstarnode::AbstractArray{Float64},
                              equation::AbstractEquation,
                              u::AbstractArray{Float64},
                              element_id::Int, n_nodes::Int)
  for j in 1:n_nodes
    for v in 1:nvariables(equation)
      fstar1[v, 1,         j] = 0.0
      fstar1[v, n_nodes+1, j] = 0.0
    end
  end
  for j = 1:n_nodes
    for i = 2:n_nodes
      for v in 1:nvariables(equation)
        u_leftright[1,v] = u[v,i-1,j,element_id]
        u_leftright[2,v] = u[v,i,j,element_id]
      end
      riemann!(fstarnode,
               u_leftright[1, 1], u_leftright[1, 2], u_leftright[1, 3], u_leftright[1, 4],
               u_leftright[2, 1], u_leftright[2, 2], u_leftright[2, 3], u_leftright[2, 4],
               equation, 1)
      for v in 1:nvariables(equation)
        fstar1[v,i,j] = fstarnode[v]
      end
    end
  end
  for i in 1:n_nodes
    for v in 1:nvariables(equation)
      fstar2[v,i,1]         = 0.0
      fstar2[v,i,n_nodes+1] = 0.0
    end
  end
  for j = 2:n_nodes
    for i = 1:n_nodes
      for v in 1:nvariables(equation)
        u_leftright[1,v] = u[v,i,j-1,element_id]
        u_leftright[2,v] = u[v,i,j,element_id]
      end
      riemann!(fstarnode,
               u_leftright[1, 1], u_leftright[1, 2], u_leftright[1, 3], u_leftright[1, 4],
               u_leftright[2, 1], u_leftright[2, 2], u_leftright[2, 3], u_leftright[2, 4],
               equation, 2)
      for v in 1:nvariables(equation)
        fstar2[v,i,j] = fstarnode[v]
      end
    end
  end
end


# Prolong solution to surfaces (for GL nodes: just a copy)
function prolong2surfaces!(dg)
  equation = equations(dg)

  for s = 1:dg.n_surfaces
    left_element_id = dg.surfaces.neighbor_ids[1, s]
    right_element_id = dg.surfaces.neighbor_ids[2, s]
    for l = 1:nnodes(dg)
      for v = 1:nvariables(dg)
        if dg.surfaces.orientations[s] == 1
          # Surface in x-direction
          dg.surfaces.u[1, v, l, s] = dg.elements.u[v, nnodes(dg), l, left_element_id]
          dg.surfaces.u[2, v, l, s] = dg.elements.u[v,          1, l, right_element_id]
        else
          # Surface in y-direction
          dg.surfaces.u[1, v, l, s] = dg.elements.u[v, l, nnodes(dg), left_element_id]
          dg.surfaces.u[2, v, l, s] = dg.elements.u[v, l,          1, right_element_id]
        end
      end
    end
  end
end


# Prolong solution to mortars (select correct method based on mortar type)
prolong2mortars!(dg) = prolong2mortars!(dg, Val(dg.mortar_type))

# Prolong solution to mortars (l2mortar version)
function prolong2mortars!(dg, ::Val{:l2})
  equation = equations(dg)

  for m = 1:dg.n_l2mortars
    large_element_id = dg.l2mortars.neighbor_ids[3, m]
    upper_element_id = dg.l2mortars.neighbor_ids[2, m]
    lower_element_id = dg.l2mortars.neighbor_ids[1, m]

    # Copy solution small to small
    if dg.l2mortars.large_sides[m] == 1 # -> small elements on right side
      if dg.l2mortars.orientations[m] == 1
        # L2 mortars in x-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.l2mortars.u_upper[2, v, l, m] = dg.elements.u[v, 1, l, upper_element_id]
            dg.l2mortars.u_lower[2, v, l, m] = dg.elements.u[v, 1, l, lower_element_id]
          end
        end
      else
        # L2 mortars in y-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.l2mortars.u_upper[2, v, l, m] = dg.elements.u[v, l, 1, upper_element_id]
            dg.l2mortars.u_lower[2, v, l, m] = dg.elements.u[v, l, 1, lower_element_id]
          end
        end
      end
    else # large_sides[m] == 2 -> small elements on left side
      if dg.l2mortars.orientations[m] == 1
        # L2 mortars in x-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.l2mortars.u_upper[1, v, l, m] = dg.elements.u[v, nnodes(dg), l, upper_element_id]
            dg.l2mortars.u_lower[1, v, l, m] = dg.elements.u[v, nnodes(dg), l, lower_element_id]
          end
        end
      else
        # L2 mortars in y-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.l2mortars.u_upper[1, v, l, m] = dg.elements.u[v, l, nnodes(dg), upper_element_id]
            dg.l2mortars.u_lower[1, v, l, m] = dg.elements.u[v, l, nnodes(dg), lower_element_id]
          end
        end
      end
    end

    # Local storage for surface data of large element
    u_large = zeros(nvariables(dg), nnodes(dg))

    # Interpolate large element face data to small surface locations
    for v = 1:nvariables(dg)
      if dg.l2mortars.large_sides[m] == 1 # -> large element on left side
        if dg.l2mortars.orientations[m] == 1
          # L2 mortars in x-direction
          for l in 1:nnodes(dg)
            u_large[v, l] = dg.elements.u[v, nnodes(dg), l, large_element_id]
          end
        else
          # L2 mortars in y-direction
          for l in 1:nnodes(dg)
            u_large[v, l] = dg.elements.u[v, l, nnodes(dg), large_element_id]
          end
        end
        @views dg.l2mortars.u_upper[1, v, :, m] .= dg.mortar_forward_upper * u_large[v, :]
        @views dg.l2mortars.u_lower[1, v, :, m] .= dg.mortar_forward_lower * u_large[v, :]
      else # large_sides[m] == 2 -> large element on right side
        if dg.l2mortars.orientations[m] == 1
          # L2 mortars in x-direction
          for l in 1:nnodes(dg)
            u_large[v, l] = dg.elements.u[v, 1, l, large_element_id]
          end
        else
          # L2 mortars in y-direction
          for l in 1:nnodes(dg)
            u_large[v, l] = dg.elements.u[v, l, 1, large_element_id]
          end
        end
        @views dg.l2mortars.u_upper[2, v, :, m] .= dg.mortar_forward_upper * u_large[v, :]
        @views dg.l2mortars.u_lower[2, v, :, m] .= dg.mortar_forward_lower * u_large[v, :]
      end
    end
  end
end


# Prolong solution to mortars (ecmortar version)
function prolong2mortars!(dg, ::Val{:ec})
  equation = equations(dg)

  for m = 1:dg.n_ecmortars
    large_element_id = dg.ecmortars.neighbor_ids[3, m]
    upper_element_id = dg.ecmortars.neighbor_ids[2, m]
    lower_element_id = dg.ecmortars.neighbor_ids[1, m]

    # Copy solution small to small
    if dg.ecmortars.large_sides[m] == 1 # -> small elements on right side, large element on left
      if dg.ecmortars.orientations[m] == 1
        # L2 mortars in x-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.ecmortars.u_upper[v, l, m] = dg.elements.u[v, 1,          l, upper_element_id]
            dg.ecmortars.u_lower[v, l, m] = dg.elements.u[v, 1,          l, lower_element_id]
            dg.ecmortars.u_large[v, l, m] = dg.elements.u[v, nnodes(dg), l, large_element_id]
          end
        end
      else
        # L2 mortars in y-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.ecmortars.u_upper[v, l, m] = dg.elements.u[v, l, 1,          upper_element_id]
            dg.ecmortars.u_lower[v, l, m] = dg.elements.u[v, l, 1,          lower_element_id]
            dg.ecmortars.u_large[v, l, m] = dg.elements.u[v, l, nnodes(dg), large_element_id]
          end
        end
      end
    else # large_sides[m] == 2 -> small elements on left side, large element on right
      if dg.ecmortars.orientations[m] == 1
        # L2 mortars in x-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.ecmortars.u_upper[v, l, m] = dg.elements.u[v, nnodes(dg), l, upper_element_id]
            dg.ecmortars.u_lower[v, l, m] = dg.elements.u[v, nnodes(dg), l, lower_element_id]
            dg.ecmortars.u_large[v, l, m] = dg.elements.u[v, 1,          l, large_element_id]
          end
        end
      else
        # L2 mortars in y-direction
        for l in 1:nnodes(dg)
          for v in 1:nvariables(dg)
            dg.ecmortars.u_upper[v, l, m] = dg.elements.u[v, l, nnodes(dg), upper_element_id]
            dg.ecmortars.u_lower[v, l, m] = dg.elements.u[v, l, nnodes(dg), lower_element_id]
            dg.ecmortars.u_large[v, l, m] = dg.elements.u[v, l, 1,          large_element_id]
          end
        end
      end
    end
  end
end


# Calculate and store fluxes across surfaces
calc_surface_flux!(dg) = calc_surface_flux!(dg.elements.surface_flux,
                                            dg.surfaces.neighbor_ids,
                                            dg.surfaces.u, dg,
                                            dg.surfaces.orientations)
function calc_surface_flux!(surface_flux::Array{Float64, 4}, neighbor_ids::Matrix{Int},
                            u_surfaces::Array{Float64, 4}, dg::Dg,
                            orientations::Vector{Int})
  # Type alias only for convenience
  A2d = MArray{Tuple{nvariables(dg), nnodes(dg)}, Float64}
  A1d = MArray{Tuple{nvariables(dg)}, Float64}

  # Pre-allocate data structures to speed up computation (thread-safe)
  fstar_threaded = [A2d(undef) for _ in 1:Threads.nthreads()]
  fstarnode_threaded = [A1d(undef) for _ in 1:Threads.nthreads()]

  #=@inbounds Threads.@threads for s = 1:dg.n_surfaces=#
  Threads.@threads for s = 1:dg.n_surfaces
    # Choose thread-specific pre-allocated container
    fstar = fstar_threaded[Threads.threadid()]
    fstarnode = fstarnode_threaded[Threads.threadid()]

    # Calculate flux
    riemann!(fstar, fstarnode, u_surfaces, s, equations(dg), nnodes(dg), orientations)

    # Get neighboring elements
    left_neighbor_id  = neighbor_ids[1, s]
    right_neighbor_id = neighbor_ids[2, s]

    # Determine surface direction with respect to elements:
    # orientation = 1: left -> 2, right -> 1
    # orientation = 2: left -> 4, right -> 3
    left_neighbor_direction = 2 * orientations[s]
    right_neighbor_direction = 2 * orientations[s] - 1

    # Copy flux to left and right element storage
    for i in 1:nnodes(dg)
      for v in 1:nvariables(dg)
        surface_flux[v, i, left_neighbor_direction,  left_neighbor_id]  = fstar[v, i]
        surface_flux[v, i, right_neighbor_direction, right_neighbor_id] = fstar[v, i]
      end
    end
  end
end


# Calculate and store fluxes across mortars (select correct method based on mortar type)
calc_mortar_flux!(dg) = calc_mortar_flux!(dg, Val(dg.mortar_type))


# Calculate and store fluxes across L2 mortars
calc_mortar_flux!(dg, ::Val{:l2}) = calc_mortar_flux!(dg.elements.surface_flux, dg, Val(:l2),
                                                      dg.l2mortars.neighbor_ids,
                                                      dg.l2mortars.u_lower,
                                                      dg.l2mortars.u_upper,
                                                      dg.l2mortars.orientations)
function calc_mortar_flux!(surface_flux::Array{Float64, 4}, dg, ::Val{:l2},
                           neighbor_ids::Matrix{Int}, u_lower::Array{Float64, 4},
                           u_upper::Array{Float64, 4}, orientations::Vector{Int})
  # Type alias only for convenience
  A2d = MArray{Tuple{nvariables(dg), nnodes(dg)}, Float64}
  A1d = MArray{Tuple{nvariables(dg)}, Float64}

  # Pre-allocate data structures to speed up computation (thread-safe)
  fstar_upper_threaded = [A2d(undef) for _ in 1:Threads.nthreads()]
  fstar_lower_threaded = [A2d(undef) for _ in 1:Threads.nthreads()]
  fstarnode_upper_threaded = [A1d(undef) for _ in 1:Threads.nthreads()]
  fstarnode_lower_threaded = [A1d(undef) for _ in 1:Threads.nthreads()]

  #=@inbounds Threads.@threads for m = 1:dg.n_l2mortars=#
  Threads.@threads for m = 1:dg.n_l2mortars
    large_element_id = dg.l2mortars.neighbor_ids[3, m]
    upper_element_id = dg.l2mortars.neighbor_ids[2, m]
    lower_element_id = dg.l2mortars.neighbor_ids[1, m]

    # Choose thread-specific pre-allocated container
    fstar_upper = fstar_upper_threaded[Threads.threadid()]
    fstar_lower = fstar_lower_threaded[Threads.threadid()]
    fstarnode_upper = fstarnode_upper_threaded[Threads.threadid()]
    fstarnode_lower = fstarnode_lower_threaded[Threads.threadid()]

    # Calculate fluxes
    riemann!(fstar_upper, fstarnode_upper, u_upper, m, equations(dg), nnodes(dg), orientations)
    riemann!(fstar_lower, fstarnode_lower, u_lower, m, equations(dg), nnodes(dg), orientations)

    # Copy flux small to small
    if dg.l2mortars.large_sides[m] == 1 # -> small elements on right side
      if dg.l2mortars.orientations[m] == 1
        # L2 mortars in x-direction
        surface_flux[:, :, 1, upper_element_id] .= fstar_upper
        surface_flux[:, :, 1, lower_element_id] .= fstar_lower
      else
        # L2 mortars in y-direction
        surface_flux[:, :, 3, upper_element_id] .= fstar_upper
        surface_flux[:, :, 3, lower_element_id] .= fstar_lower
      end
    else # large_sides[m] == 2 -> small elements on left side
      if dg.l2mortars.orientations[m] == 1
        # L2 mortars in x-direction
        surface_flux[:, :, 2, upper_element_id] .= fstar_upper
        surface_flux[:, :, 2, lower_element_id] .= fstar_lower
      else
        # L2 mortars in y-direction
        surface_flux[:, :, 4, upper_element_id] .= fstar_upper
        surface_flux[:, :, 4, lower_element_id] .= fstar_lower
      end
    end

    # Project small fluxes to large element
    for v = 1:nvariables(dg)
      @views large_surface_flux = (dg.l2mortar_reverse_upper * fstar_upper[v, :] +
                                   dg.l2mortar_reverse_lower * fstar_lower[v, :])
      if dg.l2mortars.large_sides[m] == 1 # -> large element on left side
        if dg.l2mortars.orientations[m] == 1
          # L2 mortars in x-direction
          surface_flux[v, :, 2, large_element_id] .= large_surface_flux
        else
          # L2 mortars in y-direction
          surface_flux[v, :, 4, large_element_id] .= large_surface_flux
        end
      else # large_sides[m] == 2 -> large element on right side
        if dg.l2mortars.orientations[m] == 1
          # L2 mortars in x-direction
          surface_flux[v, :, 1, large_element_id] .= large_surface_flux
        else
          # L2 mortars in y-direction
          surface_flux[v, :, 3, large_element_id] .= large_surface_flux
        end
      end
    end
  end
end


# Calculate and store fluxes across EC mortars
calc_mortar_flux!(dg, ::Val{:ec}) = calc_mortar_flux!(dg.elements.surface_flux, dg, Val(:ec),
                                                      dg.ecmortars.neighbor_ids,
                                                      dg.ecmortars.u_lower,
                                                      dg.ecmortars.u_upper,
                                                      dg.ecmortars.u_large,
                                                      dg.ecmortars.orientations)
function calc_mortar_flux!(surface_flux::Array{Float64, 4}, dg, ::Val{:ec},
                           neighbor_ids::Matrix{Int},
                           u_lower::Array{Float64, 3},
                           u_upper::Array{Float64, 3},
                           u_large::Array{Float64, 3},
                           orientations::Vector{Int})
  # Type alias only for convenience
  A3d = MArray{Tuple{nvariables(dg), nnodes(dg), nnodes(dg)}, Float64}
  A1d = MArray{Tuple{nvariables(dg)}, Float64}

  # Pre-allocate data structures to speed up computation (thread-safe)
  fstar_upper_threaded = [A3d(undef) for _ in 1:Threads.nthreads()]
  fstar_lower_threaded = [A3d(undef) for _ in 1:Threads.nthreads()]
  fstarnode_upper_threaded = [A1d(undef) for _ in 1:Threads.nthreads()]
  fstarnode_lower_threaded = [A1d(undef) for _ in 1:Threads.nthreads()]

  # Store matrix references for convenience (notation: R -> large, L -> small)
  # Note: the same notation is used in the publications of Lucas Friedrich
  PR2L_upper = dg.mortar_forward_upper
  PR2L_lower = dg.mortar_forward_lower
  PL2R_upper = dg.ecmortar_reverse_upper
  PL2R_lower = dg.ecmortar_reverse_lower

  #=@inbounds Threads.@threads for m = 1:dg.n_ecmortars=#
  Threads.@threads for m = 1:dg.n_ecmortars
    large_element_id = dg.ecmortars.neighbor_ids[3, m]
    upper_element_id = dg.ecmortars.neighbor_ids[2, m]
    lower_element_id = dg.ecmortars.neighbor_ids[1, m]

    # Choose thread-specific pre-allocated container
    fstar_upper = fstar_upper_threaded[Threads.threadid()]
    fstar_lower = fstar_lower_threaded[Threads.threadid()]
    fstarnode_upper = fstarnode_upper_threaded[Threads.threadid()]
    fstarnode_lower = fstarnode_lower_threaded[Threads.threadid()]

    # Calculate fluxes
    if dg.ecmortars.large_sides[m] == 1 # -> small elements on right side, large element on left
      riemann!(fstar_upper, fstarnode_upper, u_large, u_upper, m,
               equations(dg), nnodes(dg), orientations)
      riemann!(fstar_lower, fstarnode_lower, u_large, u_lower, m,
               equations(dg), nnodes(dg), orientations)
    else # large_sides[m] == 2 -> small elements on left side, large element on right
      riemann!(fstar_upper, fstarnode_upper, u_upper, u_large, m,
               equations(dg), nnodes(dg), orientations)
      riemann!(fstar_lower, fstarnode_lower, u_lower, u_large, m,
               equations(dg), nnodes(dg), orientations)
    end

    # Transfer fluxes to elements
    if dg.ecmortars.large_sides[m] == 1 # -> small elements on right side, large element on left
      if dg.ecmortars.orientations[m] == 1
        # EC mortars in x-direction
        surface_flux[:, :, 2, large_element_id] .= 0.0
        surface_flux[:, :, 1, upper_element_id] .= 0.0
        surface_flux[:, :, 1, lower_element_id] .= 0.0
        for i in 1:nnodes(dg)
          for l in 1:nnodes(dg)
            for v in 1:nvariables(dg)
              surface_flux[v, i, 2, large_element_id] += (PL2R_upper[i, l] * fstar_upper[v, i, l] +
                                                          PL2R_lower[i, l] * fstar_lower[v, i, l])
              surface_flux[v, i, 1, upper_element_id] +=  PR2L_upper[i, l] * fstar_upper[v, l, i]
              surface_flux[v, i, 1, lower_element_id] +=  PR2L_lower[i, l] * fstar_lower[v, l, i]
            end
          end
        end
      else
        # EC mortars in y-direction
        surface_flux[:, :, 4, large_element_id] .= 0.0
        surface_flux[:, :, 3, upper_element_id] .= 0.0
        surface_flux[:, :, 3, lower_element_id] .= 0.0
        for i in 1:nnodes(dg)
          for l in 1:nnodes(dg)
            for v in 1:nvariables(dg)
              surface_flux[v, i, 4, large_element_id] += (PL2R_upper[i, l] * fstar_upper[v, i, l] +
                                                          PL2R_lower[i, l] * fstar_lower[v, i, l])
              surface_flux[v, i, 3, upper_element_id] +=  PR2L_upper[i, l] * fstar_upper[v, l, i]
              surface_flux[v, i, 3, lower_element_id] +=  PR2L_lower[i, l] * fstar_lower[v, l, i]
            end
          end
        end
      end
    else # large_sides[m] == 2 -> small elements on left side, large element on right
      if dg.ecmortars.orientations[m] == 1
        # EC mortars in x-direction
        surface_flux[:, :, 1, large_element_id] .= 0.0
        surface_flux[:, :, 2, upper_element_id] .= 0.0
        surface_flux[:, :, 2, lower_element_id] .= 0.0
        for i in 1:nnodes(dg)
          for l in 1:nnodes(dg)
            for v in 1:nvariables(dg)
              surface_flux[v, i, 1, large_element_id] += (PL2R_upper[i, l] * fstar_upper[v, l, i] +
                                                          PL2R_lower[i, l] * fstar_lower[v, l, i])
              surface_flux[v, i, 2, upper_element_id] +=  PR2L_upper[i, l] * fstar_upper[v, i, l]
              surface_flux[v, i, 2, lower_element_id] +=  PR2L_lower[i, l] * fstar_lower[v, i, l]
            end
          end
        end
      else
        # EC mortars in y-direction
        surface_flux[:, :, 3, large_element_id] .= 0.0
        surface_flux[:, :, 4, upper_element_id] .= 0.0
        surface_flux[:, :, 4, lower_element_id] .= 0.0
        for i in 1:nnodes(dg)
          for l in 1:nnodes(dg)
            for v in 1:nvariables(dg)
              surface_flux[v, i, 3, large_element_id] += (PL2R_upper[i, l] * fstar_upper[v, l, i] +
                                                          PL2R_lower[i, l] * fstar_lower[v, l, i])
              surface_flux[v, i, 4, upper_element_id] +=  PR2L_upper[i, l] * fstar_upper[v, i, l]
              surface_flux[v, i, 4, lower_element_id] +=  PR2L_lower[i, l] * fstar_lower[v, i, l]
            end
          end
        end
      end
    end
  end
end


# Calculate surface integrals and update u_t
calc_surface_integral!(dg) = calc_surface_integral!(dg.elements.u_t, dg,
                                                    dg.elements.surface_flux, dg.lhat)
function calc_surface_integral!(u_t::Array{Float64, 4}, dg, surface_flux::Array{Float64, 4},
                                lhat::SMatrix)
  for element_id = 1:dg.n_elements
    for l = 1:nnodes(dg)
      for v = 1:nvariables(dg)
        # surface at -x
        u_t[v, 1,          l, element_id] -= surface_flux[v, l, 1, element_id] * lhat[1,          1]
        # surface at +x
        u_t[v, nnodes(dg), l, element_id] += surface_flux[v, l, 2, element_id] * lhat[nnodes(dg), 2]
        # surface at -y
        u_t[v, l, 1,          element_id] -= surface_flux[v, l, 3, element_id] * lhat[1,          1]
        # surface at +y
        u_t[v, l, nnodes(dg), element_id] += surface_flux[v, l, 4, element_id] * lhat[nnodes(dg), 2]
      end
    end
  end
end


# Apply Jacobian from mapping to reference element
function apply_jacobian!(dg)
  for element_id = 1:dg.n_elements
    for j = 1:nnodes(dg)
      for i = 1:nnodes(dg)
        for v = 1:nvariables(dg)
          dg.elements.u_t[v, i, j, element_id] *= -dg.elements.inverse_jacobian[element_id]
        end
      end
    end
  end
end


# Calculate source terms and apply them to u_t
function calc_sources!(dg::Dg, t)
  equation = equations(dg)
  if equation.sources == "none"
    return
  end

  for element_id = 1:dg.n_elements
    sources(equations(dg), dg.elements.u_t, dg.elements.u,
            dg.elements.node_coordinates, element_id, t, nnodes(dg))
  end
end


# Calculate stable time step size
function Solvers.calc_dt(dg::Dg, cfl)
  min_dt = Inf
  for element_id = 1:dg.n_elements
    dt = calc_max_dt(equations(dg), dg.elements.u, element_id, nnodes(dg),
                     dg.elements.inverse_jacobian[element_id], cfl)
    min_dt = min(min_dt, dt)
  end

  return min_dt
end


# Calculate blending factors for shock capturing
function calc_blending_factors(alpha::Vector{Float64}, out, dg, u::AbstractArray{Float64})
  # Calculate blending factor
  indicator = zeros(1, nnodes(dg), nnodes(dg))
  threshold = 0.5 * 10^(-1.8 * (nnodes(dg))^0.25)
  parameter_s = log((1 - 0.0001)/0.0001)
  alpha_min = 0.001
  alpha_max = 0.5

  for element_id in 1:dg.n_elements
    # Calculate indicator variables at Gauss-Lobatto nodes
    cons2indicator!(indicator, equations(dg), u, element_id, nnodes(dg))

    # Convert to modal representation
    modal = nodal2modal(indicator, dg.inverse_vandermonde_legendre)

    # Calculate total energies for all modes, without highest, without two highest
    total_energy = 0.0
    for j in 1:nnodes(dg)
      for i in 1:nnodes(dg)
        total_energy += modal[1, i, j]^2
      end
    end
    total_energy_clip1 = 0.0
    for j in 1:nnodes(dg)
      for i in 1:(nnodes(dg)-1)
        total_energy_clip1 += modal[1, i, j]^2
      end
    end
    total_energy_clip2 = 0.0
    for j in 1:nnodes(dg)
      for i in 1:(nnodes(dg)-2)
        total_energy_clip2 += modal[1, i, j]^2
      end
    end

    # Calculate energy in lower modes
    energy = max((total_energy - total_energy_clip1)/total_energy,
                 (total_energy_clip1 - total_energy_clip2)/total_energy_clip1)

    alpha[element_id] = 1/(1 + exp(-parameter_s/threshold * (energy - threshold)))

    # Take care of the case close to pure DG
    if (alpha[element_id] < alpha_min)
      alpha[element_id] = 0.
    end

    # Take care of the case close to pure FV
    if (alpha[element_id] > 1-alpha_min)
      alpha[element_id] = 1.
    end

    # Clip the maximum amount of FV allowed
    alpha[element_id] = min(alpha_max, alpha[element_id])
  end

  # Diffuse alpha values by setting each alpha to at least 50% of neighboring elements' alpha
  # Loop over surfaces
  for surface_id in 1:dg.n_surfaces
    # Get neighboring element ids
    left = dg.surfaces.neighbor_ids[1, surface_id]
    right = dg.surfaces.neighbor_ids[2, surface_id]

    # Apply smoothing
    alpha[left] = max(alpha[left], 0.5 * alpha[right])
    alpha[right] = max(alpha[right], 0.5 * alpha[left])
  end
 
  # Loop over mortars
  for l2mortar_id in 1:dg.n_l2mortars
    # Get neighboring element ids
    lower = dg.l2mortars.neighbor_ids[1, l2mortar_id]
    upper = dg.l2mortars.neighbor_ids[2, l2mortar_id]
    large = dg.l2mortars.neighbor_ids[3, l2mortar_id]

    # Apply smoothing
    alpha[lower] = max(alpha[lower], 0.5 * alpha[large])
    alpha[upper] = max(alpha[upper], 0.5 * alpha[large])
    alpha[large] = max(alpha[large], 0.5 * alpha[lower])
    alpha[large] = max(alpha[large], 0.5 * alpha[upper])
  end

  # Clip blending factor for values close to zero (-> pure DG)
  dg_only = isapprox.(alpha, 0, atol=1e-12)
  element_ids_dg = collect(1:dg.n_elements)[dg_only .== 1]
  element_ids_dgfv = collect(1:dg.n_elements)[dg_only .!= 1]

  push!(out, element_ids_dg)
  push!(out, element_ids_dgfv)
end


# Note: this is included here since it depends on definitions in the DG main file
include("dg_amr.jl")


end # module
