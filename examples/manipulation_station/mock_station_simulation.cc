#include <limits>

#include <gflags/gflags.h>

#include "drake/common/eigen_types.h"
#include "drake/common/find_resource.h"
#include "drake/common/is_approx_equal_abstol.h"
#include "drake/examples/kuka_iiwa_arm/iiwa_lcm.h"
#include "drake/examples/manipulation_station/manipulation_station.h"
#include "drake/geometry/geometry_visualization.h"
#include "drake/lcm/drake_lcm.h"
#include "drake/lcmt_iiwa_command.hpp"
#include "drake/lcmt_iiwa_status.hpp"
#include "drake/lcmt_schunk_wsg_command.hpp"
#include "drake/lcmt_schunk_wsg_status.hpp"
#include "drake/manipulation/schunk_wsg/schunk_wsg_lcm.h"
#include "drake/multibody/parsing/parser.h"
#include "drake/systems/analysis/simulator.h"
#include "drake/systems/framework/diagram.h"
#include "drake/systems/framework/diagram_builder.h"
#include "drake/systems/lcm/lcm_publisher_system.h"
#include "drake/systems/lcm/lcm_subscriber_system.h"
#include "drake/systems/primitives/demultiplexer.h"
#include "drake/systems/primitives/matrix_gain.h"

namespace drake {
namespace examples {
namespace manipulation_station {
namespace {

// Runs a simulation of the manipulation station plant as a stand-alone
// simulation which mocks the network inputs and outputs of the real robot
// station.  This is a useful test in the transition from a single-process
// simulation to operating on the real robot hardware.

using Eigen::VectorXd;

DEFINE_double(target_realtime_rate, 1.0,
              "Playback speed.  See documentation for "
              "Simulator::set_target_realtime_rate() for details.");
DEFINE_double(duration, std::numeric_limits<double>::infinity(),
              "Simulation duration.");

int do_main(int argc, char* argv[]) {
  gflags::ParseCommandLineFlags(&argc, &argv, true);

  systems::DiagramBuilder<double> builder;

  // Create the "manipulation station".
  auto station = builder.AddSystem<ManipulationStation>();
  station->SetupDefaultStation();
  multibody::parsing::Parser parser(&station->get_mutable_multibody_plant(),
                                    &station->get_mutable_scene_graph());
  // TODO(russt): Load sdf objects specified at the command line.  Requires
  // #9747.
  auto object = parser.AddModelFromFile(
      FindResourceOrThrow(
          "drake/examples/manipulation_station/models/061_foam_brick.sdf"),
      "brick");
  station->Finalize();

  geometry::ConnectDrakeVisualizer(&builder, station->get_scene_graph(),
                                   station->GetOutputPort("pose_bundle"));

  lcm::DrakeLcm lcm;
  lcm.StartReceiveThread();

  // TODO(russt): IiwaCommandReceiver should output positions, not
  // state.  (We are adding delay twice in this current implementation).
  auto iiwa_command_subscriber = builder.AddSystem(
      systems::lcm::LcmSubscriberSystem::Make<drake::lcmt_iiwa_command>(
          "IIWA_COMMAND", &lcm));
  auto iiwa_command = builder.AddSystem<kuka_iiwa_arm::IiwaCommandReceiver>();
  builder.Connect(iiwa_command_subscriber->get_output_port(),
                  iiwa_command->get_input_port(0));

  // Pull the positions out of the state.
  auto demux = builder.AddSystem<systems::Demultiplexer>(14, 7);
  builder.Connect(iiwa_command->get_commanded_state_output_port(),
                  demux->get_input_port(0));
  builder.Connect(demux->get_output_port(0),
                  station->GetInputPort("iiwa_position"));
  builder.Connect(iiwa_command->get_commanded_torque_output_port(),
                  station->GetInputPort("iiwa_feedforward_torque"));

  auto iiwa_status = builder.AddSystem<kuka_iiwa_arm::IiwaStatusSender>();
  // The IiwaStatusSender input port wants size 14, but only uses the first 7.
  // TODO(russt): Consider cleaning up the IiwaStatusSender.
  auto zero_padding =
      builder.AddSystem<systems::MatrixGain>(Eigen::MatrixXd::Identity(14, 7));
  builder.Connect(station->GetOutputPort("iiwa_position_commanded"),
                  zero_padding->get_input_port());
  builder.Connect(zero_padding->get_output_port(),
                  iiwa_status->get_command_input_port());
  builder.Connect(station->GetOutputPort("iiwa_state_estimated"),
                  iiwa_status->get_state_input_port());
  builder.Connect(station->GetOutputPort("iiwa_torque_commanded"),
                  iiwa_status->get_commanded_torque_input_port());
  builder.Connect(station->GetOutputPort("iiwa_torque_measured"),
                  iiwa_status->get_measured_torque_input_port());
  builder.Connect(station->GetOutputPort("iiwa_torque_external"),
                  iiwa_status->get_external_torque_input_port());
  auto iiwa_status_publisher = builder.AddSystem(
      systems::lcm::LcmPublisherSystem::Make<drake::lcmt_iiwa_status>(
          "IIWA_STATUS", &lcm));
  iiwa_status_publisher->set_publish_period(0.005);
  builder.Connect(iiwa_status->get_output_port(0),
                  iiwa_status_publisher->get_input_port());

  // Receive the WSG commands.
  auto wsg_command_subscriber = builder.AddSystem(
      systems::lcm::LcmSubscriberSystem::Make<drake::lcmt_schunk_wsg_command>(
          "SCHUNK_WSG_COMMAND", &lcm));
  auto wsg_command =
      builder.AddSystem<manipulation::schunk_wsg::SchunkWsgCommandReceiver>();
  builder.Connect(wsg_command_subscriber->get_output_port(),
                  wsg_command->get_input_port(0));
  builder.Connect(wsg_command->get_position_output_port(),
                  station->GetInputPort("wsg_position"));
  builder.Connect(wsg_command->get_force_limit_output_port(),
                  station->GetInputPort("wsg_force_limit"));

  // Publish the WSG status.
  auto wsg_status =
      builder.AddSystem<manipulation::schunk_wsg::SchunkWsgStatusSender>();
  builder.Connect(station->GetOutputPort("wsg_state_measured"),
                  wsg_status->get_state_input_port());
  builder.Connect(station->GetOutputPort("wsg_force_measured"),
                  wsg_status->get_force_input_port());
  auto wsg_status_publisher = builder.AddSystem(
      systems::lcm::LcmPublisherSystem::Make<drake::lcmt_schunk_wsg_status>(
          "SCHUNK_WSG_STATUS", &lcm));
  wsg_status_publisher->set_publish_period(0.05);
  builder.Connect(wsg_status->get_output_port(0),
                  wsg_status_publisher->get_input_port());

  // TODO(russt): Publish the camera outputs.

  auto diagram = builder.Build();

  systems::Simulator<double> simulator(*diagram);
  auto& context = simulator.get_mutable_context();
  auto& station_context =
      diagram->GetMutableSubsystemContext(*station, &context);

  // Set initial conditions for the IIWA:
  VectorXd q0(7);
  // A comfortable pose inside the workspace of the workcell.
  q0 << 0, 0.6, 0, -1.75, 0, 1.0, 0;
  iiwa_command->set_initial_position(
      &diagram->GetMutableSubsystemContext(*iiwa_command, &context), q0);
  station->SetIiwaPosition(q0, &station_context);
  const VectorXd qdot0 = VectorXd::Zero(7);
  station->SetIiwaVelocity(qdot0, &station_context);

  // Place the object in the center of the table in front of the robot.
  Eigen::Isometry3d pose = Eigen::Isometry3d::Identity();
  pose.translation() = Eigen::Vector3d(.6, 0, 0);
  station->get_multibody_plant().tree().SetFreeBodyPoseOrThrow(
      station->get_multibody_plant().GetBodyByName("base_link",
                                                           object),
      pose, &station->GetMutableSubsystemContext(
                station->get_multibody_plant(), &station_context));

  simulator.set_publish_every_time_step(false);
  simulator.set_target_realtime_rate(FLAGS_target_realtime_rate);
  simulator.StepTo(FLAGS_duration);

  return 0;
}

}  // namespace
}  // namespace manipulation_station
}  // namespace examples
}  // namespace drake

int main(int argc, char* argv[]) {
  return drake::examples::manipulation_station::do_main(argc, argv);
}
