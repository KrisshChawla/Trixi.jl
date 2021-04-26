
using OrdinaryDiffEq
using Trixi

###############################################################################
# semidiscretization of the compressible Euler equations

equations = CompressibleEulerEquations3D(1.4)

initial_condition = initial_condition_convergence_test

solver = DGSEM(polydeg=3, surface_flux=flux_lax_friedrichs)


# function cubed_sphere_mapping(xi, eta, zeta, inner_radius, thickness, offset_lambda, offset_theta)
#   alpha = xi * pi/4
#   beta = eta * pi/4

#   a = sqrt(2)/2 * inner_radius
#   x = a * tan(alpha)
#   y = a * tan(beta)

#   r = sqrt(a^2 + x^2 + y^2)

#   lambda = alpha + offset_lambda
#   theta = asin(y/r) + offset_theta
#   # sin_theta = y/r
#   # cos_theta = sqrt(1 - (y/r)^2)
#   sin_theta = sin(theta)
#   cos_theta = cos(theta)
#   radius = inner_radius + thickness * (0.5 * (zeta + 1))

#   radius * SVector(-sin_theta, sin(lambda) * cos_theta, cos(lambda) * cos_theta)
# end

function cubed_sphere_mapping(xi, eta, zeta, inner_radius, thickness, direction)
  alpha = xi * pi/4
  beta = eta * pi/4

  x = tan(alpha)
  y = tan(beta)

  r = sqrt(1 + x^2 + y^2)

  R = inner_radius + thickness * (0.5 * (zeta + 1))

  # Cube coordinates per direction
  cube_coordinates = [SVector(-1, x, y),
                      SVector( 1, x, y),
                      SVector(x, -1, y),
                      SVector(x,  1, y),
                      SVector(x, y, -1),
                      SVector(x, y,  1)]

  R / r * cube_coordinates[direction]
end

function cubed_sphere_mapping(inner_radius, thickness, direction)
  mapping(xi, eta, zeta) = cubed_sphere_mapping(xi, eta, zeta, inner_radius, thickness, direction)
end

mapping_as_string_(inner_radius, thickness, direction) = """
function cubed_sphere_mapping(xi, eta, zeta, inner_radius, thickness, direction)
  alpha = xi * pi/4
  beta = eta * pi/4

  a = sqrt(2)/2 * inner_radius
  x = a * tan(alpha)
  y = a * tan(beta)

  r = sqrt(a^2 + x^2 + y^2)

  R = inner_radius + thickness * (0.5 * (zeta + 1))

  vectors = [SVector(-a, x, y),
             SVector( a, x, y),
             SVector(x, -a, y),
             SVector(x,  a, y),
             SVector(x, y, -a),
             SVector(x, y,  a)]

  R / r * vectors[direction]
end; function cubed_sphere_mapping(inner_radius, thickness, direction)
  mapping(xi, eta, zeta) = cubed_sphere_mapping(xi, eta, zeta, inner_radius, thickness, direction)
end; mapping = cubed_sphere_mapping($inner_radius, $thickness, $direction)
"""

cells_per_dimension = (8, 8, 2)

inner_radius = 1
thickness = 0.1

mesh1 = CurvedMesh(cells_per_dimension, cubed_sphere_mapping(inner_radius, thickness, 1), periodicity=false,
                   mapping_as_string=mapping_as_string_(inner_radius, thickness, 1))

semi1 = SemidiscretizationHyperbolic(mesh1, equations, initial_condition, solver,
                                     source_terms=source_terms_convergence_test,
                                     boundary_conditions=(
                                       x_neg=Trixi.BoundaryConditionCoupled(3, 1, (1, :i, :j), Float64),
                                       x_pos=Trixi.BoundaryConditionCoupled(4, 1, (1, :i, :j), Float64),
                                       y_neg=Trixi.BoundaryConditionCoupled(5, 1, (1, :i, :j), Float64),
                                       y_pos=Trixi.BoundaryConditionCoupled(6, 1, (1, :i, :j), Float64),
                                       z_neg=boundary_condition_convergence_test,
                                       z_pos=boundary_condition_convergence_test,
                                     ))

mesh2 = CurvedMesh(cells_per_dimension, cubed_sphere_mapping(inner_radius, thickness, 2), periodicity=false, 
                   mapping_as_string=mapping_as_string_(inner_radius, thickness, 2))

semi2 = SemidiscretizationHyperbolic(mesh2, equations, initial_condition, solver,
                                     source_terms=source_terms_convergence_test,
                                     boundary_conditions=(
                                       x_neg=Trixi.BoundaryConditionCoupled(3, 1, (:end, :i, :j), Float64),
                                       x_pos=Trixi.BoundaryConditionCoupled(4, 1, (:end, :i, :j), Float64),
                                       y_neg=Trixi.BoundaryConditionCoupled(5, 1, (:end, :i, :j), Float64),
                                       y_pos=Trixi.BoundaryConditionCoupled(6, 1, (:end, :i, :j), Float64),
                                       z_neg=boundary_condition_convergence_test,
                                       z_pos=boundary_condition_convergence_test,
                                     ))

mesh3 = CurvedMesh(cells_per_dimension, cubed_sphere_mapping(inner_radius, thickness, 3), periodicity=false, 
                   mapping_as_string=mapping_as_string_(inner_radius, thickness, 3))

semi3 = SemidiscretizationHyperbolic(mesh3, equations, initial_condition, solver,
                                     source_terms=source_terms_convergence_test,
                                     boundary_conditions=(
                                       x_neg=Trixi.BoundaryConditionCoupled(1, 1, (1, :i, :j), Float64),
                                       x_pos=Trixi.BoundaryConditionCoupled(2, 1, (1, :i, :j), Float64),
                                       y_neg=Trixi.BoundaryConditionCoupled(5, 2, (:i, 1, :j), Float64),
                                       y_pos=Trixi.BoundaryConditionCoupled(6, 2, (:i, 1, :j), Float64),
                                       z_neg=boundary_condition_convergence_test,
                                       z_pos=boundary_condition_convergence_test,
                                     ))

mesh4 = CurvedMesh(cells_per_dimension, cubed_sphere_mapping(inner_radius, thickness, 4), periodicity=false, 
                   mapping_as_string=mapping_as_string_(inner_radius, thickness, 4))

semi4 = SemidiscretizationHyperbolic(mesh4, equations, initial_condition, solver,
                                     source_terms=source_terms_convergence_test,
                                     boundary_conditions=(
                                       x_neg=Trixi.BoundaryConditionCoupled(1, 1, (:end, :i, :j), Float64),
                                       x_pos=Trixi.BoundaryConditionCoupled(2, 1, (:end, :i, :j), Float64),
                                       y_neg=Trixi.BoundaryConditionCoupled(5, 2, (:i, :end, :j), Float64),
                                       y_pos=Trixi.BoundaryConditionCoupled(6, 2, (:i, :end, :j), Float64),
                                       z_neg=boundary_condition_convergence_test,
                                       z_pos=boundary_condition_convergence_test,
                                     ))

mesh5 = CurvedMesh(cells_per_dimension, cubed_sphere_mapping(inner_radius, thickness, 5), periodicity=false, 
                   mapping_as_string=mapping_as_string_(inner_radius, thickness, 5))

semi5 = SemidiscretizationHyperbolic(mesh5, equations, initial_condition, solver,
                                     source_terms=source_terms_convergence_test,
                                     boundary_conditions=(
                                       x_neg=Trixi.BoundaryConditionCoupled(1, 2, (:i, 1, :j), Float64),
                                       x_pos=Trixi.BoundaryConditionCoupled(2, 2, (:i, 1, :j), Float64),
                                       y_neg=Trixi.BoundaryConditionCoupled(3, 2, (:i, 1, :j), Float64),
                                       y_pos=Trixi.BoundaryConditionCoupled(4, 2, (:i, 1, :j), Float64),
                                       z_neg=boundary_condition_convergence_test,
                                       z_pos=boundary_condition_convergence_test,
                                     ))

mesh6 = CurvedMesh(cells_per_dimension, cubed_sphere_mapping(inner_radius, thickness, 6), periodicity=false, 
                   mapping_as_string=mapping_as_string_(inner_radius, thickness, 6))

semi6 = SemidiscretizationHyperbolic(mesh6, equations, initial_condition, solver,
                                     source_terms=source_terms_convergence_test,
                                     boundary_conditions=(
                                       x_neg=Trixi.BoundaryConditionCoupled(1, 2, (:i, :end, :j), Float64),
                                       x_pos=Trixi.BoundaryConditionCoupled(2, 2, (:i, :end, :j), Float64),
                                       y_neg=Trixi.BoundaryConditionCoupled(3, 2, (:i, :end, :j), Float64),
                                       y_pos=Trixi.BoundaryConditionCoupled(4, 2, (:i, :end, :j), Float64),
                                       z_neg=boundary_condition_convergence_test,
                                       z_pos=boundary_condition_convergence_test,
                                     ))


semi = SemidiscretizationHyperbolicCoupled((semi1, semi2, semi3, semi4, semi5, semi6))


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

stepsize_callback = StepsizeCallback(cfl=1.2)

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
