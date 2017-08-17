// Generates a swing-up trajectory for acrobot and displays the trajectory
// in DrakeVisualizer. Trajectory generation code is based on
// pendulum_swing_up.cc.

#include <iostream>
#include <memory>

#include <gflags/gflags.h>

#include "drake/common/find_resource.h"
#include "drake/examples/acrobot/acrobot_plant.h"
#include "drake/lcm/drake_lcm.h"
#include "drake/multibody/joints/floating_base_types.h"
#include "drake/multibody/parsers/urdf_parser.h"
#include "drake/multibody/rigid_body_plant/drake_visualizer.h"
#include "drake/systems/analysis/simulator.h"
#include "drake/systems/framework/diagram.h"
#include "drake/systems/framework/diagram_builder.h"
#include "drake/systems/primitives/trajectory_source.h"
#include "drake/systems/trajectory_optimization/direct_collocation.h"

using drake::solvers::SolutionResult;

typedef PiecewisePolynomial<double> PiecewisePolynomialType;

namespace drake {
namespace examples {
namespace acrobot {
namespace {
DEFINE_double(realtime_factor, 1.0,
              "Playback speed.  See documentation for "
              "Simulator::set_target_realtime_rate() for details.");

int do_main() {
  systems::DiagramBuilder<double> builder;

  AcrobotPlant<double> acrobot;

  const int kNumTimeSamples = 21;
  const double kTrajectoryTimeLowerBound = 2;
  const double kTrajectoryTimeUpperBound = 10;

  const Eigen::Vector4d x0(0, 0, 0, 0);
  const Eigen::Vector4d xG(M_PI, 0, 0, 0);

  auto context = acrobot.CreateDefaultContext();

  systems::DircolTrajectoryOptimization dircol(
      &acrobot, *context, kNumTimeSamples, kTrajectoryTimeLowerBound,
      kTrajectoryTimeUpperBound);

  // Current limit for MIT's acrobot is 7-9 Amps, according to Michael Posa.
  const double kTorqueLimit = 8;

  auto u = dircol.input();
  dircol.AddConstraintToAllKnotPoints(-kTorqueLimit <= u(0));
  dircol.AddConstraintToAllKnotPoints(u(0) <= kTorqueLimit);

  dircol.AddLinearConstraint(dircol.initial_state() == x0);
  dircol.AddLinearConstraint(dircol.final_state() == xG);

  const double R = 10;  // Cost on input "effort".
  dircol.AddRunningCost((R * u) * u);

  const double timespan_init = 4;
  auto traj_init_x =
      PiecewisePolynomialType::FirstOrderHold({0, timespan_init}, {x0, xG});
  dircol.SetInitialTrajectory(PiecewisePolynomialType(), traj_init_x);
  SolutionResult result = dircol.Solve();
  if (result != SolutionResult::kSolutionFound) {
    std::cerr << "No solution found.\n";
    return 1;
  }

  const PiecewisePolynomialTrajectory pp_xtraj =
      dircol.ReconstructStateTrajectory();
  auto state_source = builder.AddSystem<systems::TrajectorySource>(pp_xtraj);

  if (pp_xtraj.get_end_time() - pp_xtraj.get_start_time() >
      kTrajectoryTimeUpperBound) {
    std::cerr << "Trajectory time exceeds above the upper bound.\n";
    return 1;
  }
  if (pp_xtraj.get_end_time() - pp_xtraj.get_start_time() <
      kTrajectoryTimeLowerBound) {
    std::cerr << "Trajectory time exceeds below the lower bound.\n";
    return 1;
  }

  lcm::DrakeLcm lcm;
  auto tree = std::make_unique<RigidBodyTree<double>>();
  parsers::urdf::AddModelInstanceFromUrdfFileToWorld(
      FindResourceOrThrow("drake/examples/acrobot/Acrobot.urdf"),
      multibody::joints::kFixed, tree.get());

  auto publisher = builder.AddSystem<systems::DrakeVisualizer>(*tree, &lcm);

  // By default, the simulator triggers a publish event at the end of each time
  // step of the integrator. However, since this system is only meant for
  // playback, there is no continuous state and the integrator does not even get
  // called. Therefore, we explicitly set the publish frequency for the
  // visualizer.
  publisher->set_publish_period(1.0 / 60.0);

  builder.Connect(state_source->get_output_port(),
                  publisher->get_input_port(0));

  auto diagram = builder.Build();

  systems::Simulator<double> simulator(*diagram);

  simulator.set_target_realtime_rate(FLAGS_realtime_factor);
  simulator.Initialize();
  simulator.StepTo(kTrajectoryTimeUpperBound);
  return 0;
}

}  // namespace
}  // namespace acrobot
}  // namespace examples
}  // namespace drake

int main(int argc, char* argv[]) {
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  return drake::examples::acrobot::do_main();
}
