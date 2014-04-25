require "spec_helper"

describe Bosh::AwsCloud::InstanceManager do
  let(:registry) { double("registry", :endpoint => "http://...", :update_settings => nil) }
  let(:region) { mock_ec2 }

  describe "#has_instance?" do
    let(:instance_id) { "instance id" }
    let(:availability_zone_selector) { double(Bosh::AwsCloud::AvailabilityZoneSelector, common_availability_zone: "us-east-1a") }

    let(:fake_aws_instance) { double("aws_instance", id: instance_id) }
    let(:instance_manager) { described_class.new(region, registry, availability_zone_selector) }

    before do
      region.stub_chain(:instances, :[]).with(instance_id).and_return(fake_aws_instance)
    end

    it "returns false if instance does not exist" do
      fake_aws_instance.should_receive(:exists?).and_return(false)
      instance_manager.has_instance?(instance_id).should be(false)
    end

    it "returns true if instance does exist" do
      fake_aws_instance.should_receive(:exists?).and_return(true)
      fake_aws_instance.should_receive(:status).and_return(:running)
      instance_manager.has_instance?(instance_id).should be(true)
    end

    it "returns false if instance exists but is terminated" do
      fake_aws_instance.should_receive(:exists?).and_return(true)
      fake_aws_instance.should_receive(:status).and_return(:terminated)
      instance_manager.has_instance?(instance_id).should be(false)
    end
  end

  describe "#create" do
    let(:availability_zone_selector) { double(Bosh::AwsCloud::AvailabilityZoneSelector, common_availability_zone: "us-east-1a") }
    let(:fake_aws_subnet) { double(AWS::EC2::Subnet).as_null_object }
    let(:aws_instance_params) do
      {
          count: 1,
          image_id: "stemcell-id",
          instance_type: "m1.small",
          user_data: "{\"registry\":{\"endpoint\":\"http://...\"},\"dns\":{\"nameserver\":\"foo\"}}",
          key_name: "bar",
          security_groups: ["baz"],
          subnet: fake_aws_subnet,
          private_ip_address: "1.2.3.4",
          availability_zone: "us-east-1a"
      }
    end
    let(:aws_instances) { double(AWS::EC2::InstanceCollection) }
    let(:instance) { double(AWS::EC2::Instance, id: 'i-12345678') }
    let(:aws_client) { double(AWS::EC2::Client) }

    it "should ask AWS to create an instance in the given region, with parameters built up from the given arguments" do
      region.stub(:instances).and_return(aws_instances)
      region.stub(:subnets).and_return({"sub-123456" => fake_aws_subnet})

      aws_instances.should_receive(:create).with(aws_instance_params).and_return(instance)
      Bosh::AwsCloud::ResourceWait.stub(:for_instance).with(instance: instance, state: :running)

      instance_manager = described_class.new(region, registry, availability_zone_selector)

      agent_id = "agent-id"
      stemcell_id = "stemcell-id"
      resource_pool = {"instance_type" => "m1.small", "key_name" => "bar"}
      networks_spec = {
          "default" => {
              "type" => "dynamic",
              "dns" => "foo",
              "cloud_properties" => {"security_groups" => "baz"}
          },
          "other" => {
              "type" => "manual",
              "cloud_properties" => {"subnet" => "sub-123456"},
              "ip" => "1.2.3.4"
          }
      }
      disk_locality = nil
      environment = nil
      options = {"aws" => {"region" => "us-east-1"}}
      instance_manager.create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
    end

    it "should ask AWS to create a SPOT instance in the given region, when resource_pool includes spot_bid_price" do
      region.stub(:client).and_return(aws_client)
      region.stub(:subnets).and_return({"sub-123456" => fake_aws_subnet})
      region.stub(:instances).and_return( {'i-12345678' => instance } )

      #need to translate security group names to security group ids
      sg1 = double(AWS::EC2::SecurityGroup, security_group_id:"sg-baz-1234")
      sg1.stub(:name).and_return("baz")
      region.stub(:security_groups).and_return([sg1])

      agent_id = "agent-id"
      stemcell_id = "stemcell-id"
      networks_spec = {
          "default" => {
              "type" => "dynamic",
              "dns" => "foo",
              "cloud_properties" => {"security_groups" => "baz"}
          },
          "other" => {
              "type" => "manual",
              "cloud_properties" => {"subnet" => "sub-123456"},
              "ip" => "1.2.3.4"
          }
      }
      disk_locality = nil
      environment = nil
      options = {"aws" => {"region" => "us-east-1"}}

      #NB: The spot_bid_price param should trigger spot instance creation
      resource_pool = {"spot_bid_price"=>0.15, "instance_type" => "m1.small", "key_name" => "bar"}

      #Should not recieve an ondemand instance create call
      aws_instances.should_not_receive(:create).with(aws_instance_params)

      #Should rather recieve a spot instance request
      aws_client.should_receive(:request_spot_instances) do |spot_request|
        spot_request[:spot_price].should eq("0.15")
        spot_request[:instance_count].should eq(1)
        #spot_request[:valid_until].should  #TODO - not sure how to test this
        spot_request[:launch_specification].should eq({ 
          :image_id=>"stemcell-id", 
          :key_name=>"bar", 
          :instance_type=>"m1.small", 
          :user_data=>Base64.encode64("{\"registry\":{\"endpoint\":\"http://...\"},\"dns\":{\"nameserver\":\"foo\"}}"),
          :placement=> { :availability_zone=>"us-east-1a" }, 
          :network_interfaces=>[ { 
            :subnet_id=>fake_aws_subnet,
            :groups=>["sg-baz-1234"], 
            :device_index=>0, 
            :private_ip_address=>"1.2.3.4"
          }]
        })
        
        # return 
        {
          :spot_instance_request_set => [ { :spot_instance_request_id=>"sir-12345c", :other_params_here => "which aren't used" }], 
          :request_id => "request-id-12345"
        }
      end

      # Should poll the spot instance request until state is active
      aws_client.should_receive(:describe_spot_instance_requests) \
        .with({:spot_instance_request_ids=>["sir-12345c"]}) \
        .and_return({ :spot_instance_request_set => [ {:state => "active", :instance_id=>"i-12345678"} ] })
       
      # Should then wait for instance to be running, just like in the case of on deman
      Bosh::AwsCloud::ResourceWait.should_receive(:for_instance).with(instance: instance, state: :running)

      # Trigger spot instance request
      instance_manager = described_class.new(region, registry, availability_zone_selector)
      instance_manager.create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)

    end

    it "should retry creating the VM when AWS::EC2::Errors::InvalidIPAddress::InUse raised" do
      region.stub(:instances).and_return(aws_instances)
      region.stub(:subnets).and_return({"sub-123456" => fake_aws_subnet})

      aws_instances.should_receive(:create).with(aws_instance_params).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse)
      aws_instances.should_receive(:create).with(aws_instance_params).and_return(instance)
      Bosh::AwsCloud::ResourceWait.stub(:for_instance).with(instance: instance, state: :running)
      
      instance_manager = described_class.new(region, registry, availability_zone_selector)
      instance_manager.stub(instance_create_wait_time: 0)

      agent_id = "agent-id"
      stemcell_id = "stemcell-id"
      resource_pool = {"instance_type" => "m1.small", "key_name" => "bar"}
      networks_spec = {
          "default" => {
              "type" => "dynamic",
              "dns" => "foo",
              "cloud_properties" => {"security_groups" => "baz"}
          },
          "other" => {
              "type" => "manual",
              "cloud_properties" => {"subnet" => "sub-123456"},
              "ip" => "1.2.3.4"
          }
      }
      disk_locality = nil
      environment = nil
      options = {"aws" => {"region" => "us-east-1"}}
      instance_manager.create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
    end
  end

  describe "setting instance parameters" do
    describe "#set_key_name_parameter" do
      it "should set the key name instance parameter to the first non-null argument" do
        instance_manager = described_class.new(region, registry)

        instance_manager.set_key_name_parameter("foo", nil)
        instance_manager.instance_params[:key_name].should == "foo"

        instance_manager.set_key_name_parameter(nil, "bar")
        instance_manager.instance_params[:key_name].should == "bar"
      end

      it "should not have a key name instance parameter if it receives only null arguments" do
        instance_manager = described_class.new(region, registry)

        instance_manager.set_key_name_parameter(nil, nil)
        instance_manager.instance_params.keys.should_not include(:key_name)
      end
    end

    describe "#set_security_groups_parameter" do
      context "when the networks specs have security groups" do
        it "returns a unique list of the specified group names" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_security_groups_parameter(
              {
                  "network" => {"cloud_properties" => {"security_groups" => "yay"}},
                  "artwork" => {"cloud_properties" => {"security_groups" => ["yay", "aya"]}}
              },
              ["default_1", "default_2"]
          )

          instance_manager.instance_params[:security_groups].should =~ ["yay", "aya"]
        end
      end

      context "when the networks specs have no security groups specified" do
        it "returns the list of default AWS group names" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_security_groups_parameter(
              {"network" => {"cloud_properties" => {"foo" => "bar"}}},
              ["default_1", "default_2"]
          )

          instance_manager.instance_params[:security_groups].should =~ ["default_1", "default_2"]
        end
      end
    end

    describe "#set_vpc_parameters" do
      let(:fake_aws_subnet) { double("aws_subnet") }

      before do
        region.stub(:subnets).and_return({"sub-123456" => fake_aws_subnet})
      end

      context "when there is not a manual network in the specs" do
        it "should not set the private IP address parameters" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_vpc_parameters(
              {
                  "network" => {
                      "type" => "designed by robots",
                      "ip" => "1.2.3.4"
                  }
              }
          )

          instance_manager.instance_params.keys.should_not include(:private_ip_address)
        end
      end

      context "when there is a manual network in the specs" do
        it "should set the private IP address parameters" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_vpc_parameters(
              {
                  "network" => {
                      "type" => "manual",
                      "ip" => "1.2.3.4"
                  }
              }
          )

          instance_manager.instance_params[:private_ip_address].should == "1.2.3.4"
        end
      end

      context "when there is a network in the specs with unspecified type" do
        it "should set the private IP address parameters for that network (treat it as manual)" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_vpc_parameters(
              {
                  "network" => {
                      "ip" => "1.2.3.4",
                      "cloud_properties" => {"subnet" => "sub-123456"}
                  }
              }
          )

          instance_manager.instance_params[:private_ip_address].should == "1.2.3.4"
        end
      end
      
      context "when there is a subnet in the cloud_properties in the specs" do
        context "and network type is dynamic" do
          it "should set the subnet parameter" do
            instance_manager = described_class.new(region, registry)
            instance_manager.set_vpc_parameters(
              {
                "network" => {
                  "type" => "dynamic",
                  "cloud_properties" => {"subnet" => "sub-123456"}
                }
              }
            )

            instance_manager.instance_params.keys.should include(:subnet)
          end
        end

        context "and network type is manual" do
          it "should set the subnet parameter" do
            instance_manager = described_class.new(region, registry)
            instance_manager.set_vpc_parameters(
              {
                "network" => {
                  "type" => "manual",
                  "cloud_properties" => {"subnet" => "sub-123456"}
                }
              }
            )

            instance_manager.instance_params.keys.should include(:subnet)
          end
        end

        context "and network type is not set" do
          it "should set the subnet parameter" do
            instance_manager = described_class.new(region, registry)
            instance_manager.set_vpc_parameters(
              {
                "network" => {
                  "cloud_properties" => {"subnet" => "sub-123456"}
                }
              }
            )

            instance_manager.instance_params.keys.should include(:subnet)
          end
        end

        context "and network type is vip" do
          it "should not set the subnet parameter" do
            instance_manager = described_class.new(region, registry)
            instance_manager.set_vpc_parameters(
              {
                "network" => {
                  "type" => "vip",
                  "cloud_properties" => {"subnet" => "sub-123456"}
                }
              }
            )

            instance_manager.instance_params.keys.should_not include(:subnet)
          end
        end
      end      

      context "when there is no subnet in the cloud_properties in the specs" do
        it "should not set the subnet parameter" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_vpc_parameters(
              {
                  "network" => {
                      "type" => "dynamic"
                  }
              }
          )

          instance_manager.instance_params.keys.should_not include(:subnet)
        end
      end
      
    end

    describe "#set_availability_zone_parameter" do
      let(:availability_zone_selector) { double(Bosh::AwsCloud::AvailabilityZoneSelector) }

      context "if there is a common availability zone specified" do
        before do
          availability_zone_selector.stub(:common_availability_zone).and_return("danger zone")
        end

        it "sets the availability zone parameter appropriately" do
          instance_manager = described_class.new(region, registry, availability_zone_selector)
          instance_manager.set_availability_zone_parameter(["danger zone"], nil, "danger zone")
          instance_manager.instance_params[:availability_zone].should == "danger zone"
        end
      end

      context "if there is no common availability zone" do
        before do
          availability_zone_selector.stub(:common_availability_zone).and_return(nil)
        end

        it "does not set the availability zone parameter" do
          instance_manager = described_class.new(region, registry, availability_zone_selector)
          instance_manager.set_availability_zone_parameter([], nil, nil)
          instance_manager.instance_params.keys.should_not include(:availability_zone)
        end
      end
    end

    describe "#set_user_data_parameter" do
      context "when a dns configuration is provided" do
        it "populates the user data parameter with registry and dns data" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_user_data_parameter(
              {
                  "foo" => {"dns" => "bar"}
              }
          )

          instance_manager.instance_params[:user_data].should ==
              "{\"registry\":{\"endpoint\":\"http://...\"},\"dns\":{\"nameserver\":\"bar\"}}"
        end
      end

      context "when a dns configuration is not provided" do
        it "populates the user data parameter with only the registry data" do
          instance_manager = described_class.new(region, registry)
          instance_manager.set_user_data_parameter(
              {
                  "foo" => {"no_dns" => "bar"}
              }
          )

          instance_manager.instance_params[:user_data].should ==
              "{\"registry\":{\"endpoint\":\"http://...\"}}"
        end
      end
    end
  end

  describe "#terminate" do
    let(:instance_id) { "i-123456" }
    let(:fake_aws_instance) { double("aws_instance", id: instance_id) }
    let(:instance_manager) { described_class.new(region, registry) }

    it "should terminate an instance given the id" do
      instance_manager.stub(:remove_from_load_balancers)

      fake_aws_instance.should_receive(:terminate)
      registry.should_receive(:delete_settings).with(instance_id)

      region.stub(:instances).and_return({instance_id => fake_aws_instance})
      Bosh::AwsCloud::ResourceWait.stub(:for_instance).with(instance: fake_aws_instance, state: :terminated)

      instance_manager.terminate(instance_id)
    end

    context "when instance was deleted in AWS and no longer exists (showing in AWS console)" do
      before do
        # AWS SDK always returns an object even if instance no longer exists
        allow(region).to receive(:instances).with(no_args).and_return({instance_id => fake_aws_instance})

        # AWS returns NotFound error if instance no longer exists in AWS console
        # (This could happen when instance was deleted manually and BOSH is not aware of that)
        allow(fake_aws_instance).to receive(:terminate).
          with(no_args).and_raise(AWS::EC2::Errors::InvalidInstanceID::NotFound)
      end

      it "raises Bosh::Clouds::VMNotFound but still removes settings from registry and removes instance from the load balancers" do
        expect(instance_manager).to receive(:remove_from_load_balancers).with(no_args)

        expect(registry).to receive(:delete_settings).with(instance_id)

        expect {
          instance_manager.terminate(instance_id)
        }.to raise_error(Bosh::Clouds::VMNotFound, "VM `#{instance_id}' not found")
      end
    end

    describe "fast path deletion" do
      it "should do a fast path delete when requested" do
        instance_manager.stub(:remove_from_load_balancers)

        region.stub(:instances).and_return({instance_id => fake_aws_instance})
        fake_aws_instance.stub(:terminate)
        registry.stub(:delete_settings)

        Bosh::AwsCloud::ResourceWait.stub(:for_volume).with(instrance: fake_aws_instance, state: :terminated)
        Bosh::AwsCloud::TagManager.should_receive(:tag).with(fake_aws_instance, "Name", "to be deleted")

        instance_manager.terminate(instance_id, true)
      end
    end

end

  describe "#reboot" do
    let(:fake_aws_instance) { double("aws_instance") }
    let(:instance_id) { "i-123456" }
    let(:instance_manager) { described_class.new(region, registry) }

    it "should reboot the instance" do
      fake_aws_instance.should_receive(:reboot)

      region.stub(:instances).and_return({instance_id => fake_aws_instance})

      instance_manager.reboot(instance_id)
    end
  end

  context 'ELBs' do
    let(:instance_manager) { described_class.new(region, registry) }
    let(:instance) { double('instance', :id => 'i-xxxxxxxx', :exists? => true) }
    let(:instances) { double('instances', :[] => instance) }
    let(:lb) { double('lb', :instances => instances) }
    let(:load_balancers) do
      l = [lb]
      l.stub(:[] => lb)
      l
    end
    let(:elb) { double(AWS::ELB, :load_balancers => load_balancers) }

    before(:each) do
      AWS::ELB.stub(:new => elb)
      elb.stub(:[] => lb)
      instance_manager.stub(:instance => instance)
    end

    describe '#remove_from_load_balancers' do
      it 'should remove the instance from all load balancers' do
        instances.should_receive(:deregister).with(instance)

        instance_manager.remove_from_load_balancers
      end
    end

    describe '#attach_to_load_balancers' do
      it 'should attach the instance the list of load balancers in the resource pool' do
        instance_manager.stub(:elbs => %w[lb])
        instances.should_receive(:register).with(instance)

        instance_manager.attach_to_load_balancers
      end
    end
  end
end
