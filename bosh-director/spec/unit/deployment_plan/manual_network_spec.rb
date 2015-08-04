require 'spec_helper'

describe Bosh::Director::DeploymentPlan::ManualNetwork do
  let(:manifest) do
   manifest = Bosh::Spec::Deployments.legacy_manifest
   manifest['networks'].first['subnets'].first['range'] = network_range
   manifest['networks'].first['subnets'].first['reserved'] << '192.168.1.3'
   manifest['networks'].first['subnets'].first['static'] = static_ips
   manifest
  end
  let(:network_range) { '192.168.1.0/24' }
  let(:static_ips) { [] }
  let(:network_spec) { manifest['networks'].first }
  let(:planner_factory) { BD::DeploymentPlan::PlannerFactory.create(BD::Config.event_log, BD::Config.logger) }
  let(:deployment_plan) { planner_factory.planner_without_vm_binding(manifest, nil, {}) }
  let(:global_network_resolver) { BD::DeploymentPlan::GlobalNetworkResolver.new(deployment_plan) }
  let(:ip_provider_factory) { BD::DeploymentPlan::IpProviderFactory.new(logger, {}) }
  let(:instance) { instance_double(BD::DeploymentPlan::Instance, model: BD::Models::Instance.make) }

  subject(:manual_network) do
     BD::DeploymentPlan::ManualNetwork.new(
       network_spec,
       global_network_resolver,
       ip_provider_factory,
       logger
     )
   end

  describe :initialize do
    it 'should parse subnets' do
      expect(manual_network.subnets.size).to eq(1)
      subnet = manual_network.subnets.first
      expect(subnet).to be_an_instance_of BD::DeploymentPlan::NetworkSubnet
      expect(subnet.network).to eq(manual_network)
      expect(subnet.range).to eq(NetAddr::CIDR.create('192.168.1.0/24'))
    end

    context 'when there are overlapping subnets' do
      let(:manifest) do
        manifest = Bosh::Spec::Deployments.legacy_manifest
        manifest['networks'].first['subnets'] << Bosh::Spec::Deployments.subnet({
            'range' => '192.168.1.0/28',
          })
        manifest
      end

      it 'should raise an error' do
        expect {
          manual_network
        }.to raise_error(Bosh::Director::NetworkOverlappingSubnets)
      end
    end
  end

  describe :reserve do
    let(:static_ips) { ['192.168.1.5'] }

    it 'should reserve an IP within the range' do
      reservation = BD::NetworkReservation.new_static(instance, manual_network, '192.168.1.5')

      manual_network.reserve(reservation)

      expect(reservation.reserved?).to eq(true)
      expect(reservation.ip).to eq(NetAddr::CIDR.create('192.168.1.5').to_i)
    end

    it 'should allocated dynamic IP' do
      reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)

      manual_network.reserve(reservation)

      expect(reservation.reserved?).to eq(true)
      expect(reservation.ip).to eq(NetAddr::CIDR.create('192.168.1.2').to_i)
    end

    it 'should not let you reserve an IP in the reserved range' do
      reservation = BD::NetworkReservation.new_static(instance, manual_network, '192.168.1.3')
      expect {
        manual_network.reserve(reservation)
      }.to raise_error BD::NetworkReservationAlreadyInUse
      expect(reservation.reserved?).to eq(false)
    end

    context 'when reserving IP from the wrong pool' do
      let(:static_ips) { ['192.168.1.10'] }

      it 'should not let you reserve an IP in the wrong pool' do
        reservation = BD::NetworkReservation.new_static(instance, manual_network, '192.168.1.11')

        expect {
          manual_network.reserve(reservation)
        }.to raise_error BD::NetworkReservationWrongType
      end
    end

    context 'when network is out of capacity' do
      let(:network_range) { '192.168.1.0/30' }
      let(:static_ips) { [] }

      before do
        reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)
        manual_network.reserve(reservation)
      end

      it "should raise an error when it's out of capacity" do
        reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)

        expect {
          manual_network.reserve(reservation)
        }.to raise_error BD::NetworkReservationNotEnoughCapacity
      end
    end
  end

  describe :release do
    let(:network_range) { '192.168.1.0/30' }

    it 'should release the IP from the subnet' do
      ip_reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)

      manual_network.reserve(ip_reservation)
      expect(ip_reservation.reserved?).to eq(true)
      expect(ip_reservation.ip).to eq(NetAddr::CIDR.create('192.168.1.2').to_i)

      dynamic_reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)

      expect {
        manual_network.reserve(dynamic_reservation)
      }.to raise_error BD::NetworkReservationNotEnoughCapacity

      manual_network.release(ip_reservation)

      manual_network.reserve(dynamic_reservation)
      expect(dynamic_reservation.ip).to eq(NetAddr::CIDR.create('192.168.1.2').to_i)
    end

    it 'should fail when there is no IP' do
      reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)

      expect {
        manual_network.release(reservation)
      }.to raise_error(/without an IP/)
    end
  end

  describe :network_settings do
    it 'should provide the network settings from the subnet' do
      reservation = BD::NetworkReservation.new_static(instance, manual_network, '192.168.1.2')

      expect(manual_network.network_settings(reservation, [])).to eq({
            'ip' => '192.168.1.2',
            'netmask' => '255.255.255.0',
            'cloud_properties' => {},
            'gateway' => '192.168.1.1',
            'dns' => ['192.168.1.1', '192.168.1.2'],
            'default' => []
          })
    end

    it 'should set the defaults' do
      reservation = BD::NetworkReservation.new_static(instance, manual_network, '192.168.1.2')

      expect(manual_network.network_settings(reservation)).to eq({
            'ip' => '192.168.1.2',
            'netmask' => '255.255.255.0',
            'cloud_properties' => {},
            'gateway' => '192.168.1.1',
            'dns' => ['192.168.1.1', '192.168.1.2'],
            'default' => ['dns', 'gateway']
          })
    end

    it 'should fail when there is no IP' do
      reservation = BD::NetworkReservation.new_dynamic(instance, manual_network)

      expect {
        manual_network.network_settings(reservation)
      }.to raise_error(/without an IP/)
    end
  end

  describe 'availability_zones' do
    let(:network_spec) do
      Bosh::Spec::Deployments.network.merge(
        'subnets' => [
          {
            'range' => '10.1.0.0/24',
            'gateway' => '10.1.0.1',
            'availability_zone' => 'zone_1',
          },
          {
            'range' => '10.2.0.0/24',
            'gateway' => '10.2.0.1',
            'availability_zone' => 'zone_2'
          },
          {
            'range' => '10.3.0.0/24',
            'gateway' => '10.3.0.1',
          },
          {
            'range' => '10.4.0.0/24',
            'gateway' => '10.4.0.1',
            'availability_zone' => 'zone_1'
          },
        ]
      )
    end

    it 'returns availability zones specified by subnets' do
      expect(manual_network.availability_zones).to eq (['zone_1', 'zone_2'])
    end
  end

  describe 'validate_has_job' do
    let(:network_spec) do
      Bosh::Spec::Deployments.network.merge(
        'subnets' => [
          {
            'range' => '10.1.0.0/24',
            'gateway' => '10.1.0.1',
            'availability_zone' => 'zone_1',
          },
          {
            'range' => '10.2.0.0/24',
            'gateway' => '10.2.0.1',
            'availability_zone' => 'zone_2'
          },
        ]
      )
    end

    it 'passes when all availability zone names are contained by subnets' do
      expect { manual_network.validate_has_job!([], 'foo-job') }.to_not raise_error
      expect { manual_network.validate_has_job!(['zone_1'], 'foo-job') }.to_not raise_error
      expect { manual_network.validate_has_job!(['zone_2'], 'foo-job') }.to_not raise_error
      expect { manual_network.validate_has_job!(['zone_1', 'zone_2'], 'foo-job') }.to_not raise_error
    end

    it 'raises when any availability zone are not contained by a subnet' do
      expect {
        manual_network.validate_has_job!(['zone_1', 'zone_3', 'zone_2', 'zone_4'], 'foo-job')
      }.to raise_error(
          Bosh::Director::JobNetworkMissingRequiredAvailabilityZone,
          "Job 'foo-job' refers to an availability zone(s) '[\"zone_3\", \"zone_4\"]' but 'a' has no matching subnet(s)."
        )
    end
  end
end
