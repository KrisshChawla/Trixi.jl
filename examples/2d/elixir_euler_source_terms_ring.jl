
using OrdinaryDiffEq
using Trixi

###############################################################################
# semidiscretization of the compressible Euler equations

equations = CompressibleEulerEquations2D(1.4)

initial_condition = initial_condition_convergence_test

source_terms = source_terms_convergence_test

solver = DGSEM(polydeg=3, surface_flux=flux_lax_friedrichs)

function gnomonic_projection(xi, eta, inner_radius, thickness, direction)
  alpha = xi * pi/4

  x = tan(alpha)

  r = sqrt(1 + x^2)
  R = inner_radius + thickness * (0.5 * (eta + 1))

  # Cube coordinates per direction
  cube_coordinates = [SVector(-1, x),
                      SVector( 1, x),
                      SVector(x, -1),
                      SVector(x,  1)]

  R / r * cube_coordinates[direction]
end

function ring_mapping(inner_radius, thickness, direction)
  mapping(xi, eta) = gnomonic_projection(xi, eta, inner_radius, thickness, direction)
end

mapping_as_string(direction) = """
function gnomonic_projection(xi, eta, inner_radius, thickness, direction)
  alpha = xi * pi/4

  x = tan(alpha)

  r = sqrt(1 + x^2)
  R = inner_radius + thickness * (0.5 * (eta + 1))

  # Cube coordinates per direction
  cube_coordinates = [SVector(-1, x),
                      SVector( 1, x),
                      SVector(x, -1),
                      SVector(x,  1)]

  R / r * cube_coordinates[direction]
end; function ring_mapping(inner_radius, thickness, direction)
  mapping(xi, eta) = gnomonic_projection(xi, eta, inner_radius, thickness, direction)
end; mapping = ring_mapping(1, 1, $direction)
"""


mesh1 = CurvedMesh((8, 4), ring_mapping(1, 1, 1), 
                   periodicity=false, mapping_as_string=mapping_as_string(1))

semi1 = SemidiscretizationHyperbolic(mesh1, equations, initial_condition, solver,
  source_terms=source_terms, boundary_conditions=(
    x_neg=Trixi.BoundaryConditionCoupled(3, 1, (1, :i), Float64),
    x_pos=Trixi.BoundaryConditionCoupled(4, 1, (1, :i), Float64),
    y_neg=boundary_condition_convergence_test,
    y_pos=boundary_condition_convergence_test,
  ))

mesh2 = CurvedMesh((8, 4), ring_mapping(1, 1, 2), 
                   periodicity=false, mapping_as_string=mapping_as_string(2))

semi2 = SemidiscretizationHyperbolic(mesh2, equations, initial_condition, solver,
  source_terms=source_terms, boundary_conditions=(
    x_neg=Trixi.BoundaryConditionCoupled(3, 1, (:end, :i), Float64),
    x_pos=Trixi.BoundaryConditionCoupled(4, 1, (:end, :i), Float64),
    y_neg=boundary_condition_convergence_test,
    y_pos=boundary_condition_convergence_test,
  ))

mesh3 = CurvedMesh((8, 4), ring_mapping(1, 1, 3), 
                   periodicity=false, mapping_as_string=mapping_as_string(3))

semi3 = SemidiscretizationHyperbolic(mesh3, equations, initial_condition, solver,
  source_terms=source_terms, boundary_conditions=(
    x_neg=Trixi.BoundaryConditionCoupled(1, 1, (1, :i), Float64),
    x_pos=Trixi.BoundaryConditionCoupled(2, 1, (1, :i), Float64),
    y_neg=boundary_condition_convergence_test,
    y_pos=boundary_condition_convergence_test,
  ))

mesh4 = CurvedMesh((8, 4), ring_mapping(1, 1, 4), 
                   periodicity=false, mapping_as_string=mapping_as_string(4))

semi4 = SemidiscretizationHyperbolic(mesh4, equations, initial_condition, solver,
  source_terms=source_terms, boundary_conditions=(
    x_neg=Trixi.BoundaryConditionCoupled(1, 1, (:end, :i), Float64),
    x_pos=Trixi.BoundaryConditionCoupled(2, 1, (:end, :i), Float64),
    y_neg=boundary_condition_convergence_test,
    y_pos=boundary_condition_convergence_test,
  ))

semi = SemidiscretizationCoupled((semi1, semi2, semi3, semi4))

###############################################################################
# ODE solvers, callbacks etc.

tspan = (0.0, 1.0)
ode = semidiscretize(semi, tspan)

summary_callback = SummaryCallback()

analysis_interval = 100
analysis_callback = AnalysisCallback(semi, interval=analysis_interval)

alive_callback = AliveCallback(analysis_interval=analysis_interval)

save_solution = SaveSolutionCallback(interval=100,
                                     save_initial_solution=true,
                                     save_final_solution=true,
                                     solution_variables=cons2prim)

stepsize_callback = StepsizeCallback(cfl=1.0)

callbacks = CallbackSet(summary_callback,
                        analysis_callback, alive_callback,
                        save_solution,
                        stepsize_callback)
###############################################################################
# run the simulation

sol = solve(ode, CarpenterKennedy2N54(williamson_condition=false),
            dt=1.0, # solve needs some value here but it will be overwritten by the stepsize_callback
            save_everystep=false, callback=callbacks);
summary_callback() # print the timer summary