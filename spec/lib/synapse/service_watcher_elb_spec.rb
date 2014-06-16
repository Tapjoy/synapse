require 'spec_helper'
require 'net/http'

# reopen so we can get access to some internal attributes
class Synapse::ElbWatcher
  attr_reader :watcher, :check_interval
end


describe ServiceWatcher::ElbWatcher do
  let(:mocksynapse) { double() }
  let(:mock_elb) { double(AWS::ELB) }
  let(:mock_ec2) { double(AWS::EC2) }
  subject { Synapse::ElbWatcher.new(args, mocksynapse) }
  let(:testargs) { {'name' => 'foo', 'discovery' => {'method' => 'elb', 'elb-name' => 'foo'}, 'haproxy' => {'port' => 8082, 'server_port_override' => 9898}} }

  before :each do
    Net::HTTP.stub(:get).with(URI('http://169.254.169.254/latest/meta-data/placement/availability-zone')).and_return("us-east-1b")
  end

  def remove_arg(name)
    args = testargs.clone
    args.delete name
    args
  end

  def remove_discovery_arg(name)
    args = testargs.clone
    args['discovery'].delete name
    args
  end

  context "#initialize" do
    let(:args) { testargs }
    it 'creates a new ElbWatcher instance' do
      expect { subject }.not_to raise_error
    end

    ['name', 'discovery', 'haproxy'].each do |to_remove|
      context "without #{to_remove} argument" do
        let(:args) { remove_arg to_remove }
        it 'raises error on missing argument' do
          expect { subject }.to raise_error(ArgumentError, "missing required option #{to_remove}")
        end
      end
    end

    context "discovery options" do
      context "method is missing" do
        let(:args) { remove_discovery_arg 'method' }

        it 'raises an error' do
          expect { subject }.to raise_error(ArgumentError, "discovery method must be set to 'elb'")
        end
      end

      context "method is not 'elb'" do
        let(:args) do
          args = testargs.clone
          args['discovery']['method'] = 'foo'
          args
        end

        it 'raises an error' do
          expect { subject }.to raise_error(ArgumentError, "discovery method must be set to 'elb'")
        end
      end
    end
  end

  context "#start" do
    let(:args) { testargs }

    it 'sets default check interval' do
      expect(Thread).to receive(:new).and_return(double)
      subject.start
      expect(subject.check_interval).to eq(30.0)
    end

    it 'starts a watcher thread' do
      watcher_mock = double()
      expect(Thread).to receive(:new).and_return(watcher_mock)
      subject.start
      expect(subject.watcher).to equal(watcher_mock)
    end
  end

  context "ELB integration" do
    let(:args) { testargs }
    let(:load_balancer_collection) { double(AWS::ELB::LoadBalancerCollection) }
    let(:ec2_us_east_1b) { double(AWS::EC2::Instance) }
    let(:ec2_us_east_1e) { double(AWS::EC2::Instance) }
    let(:ec2_instances) { [ec2_us_east_1b, ec2_us_east_1e] }

    before(:each) do
      ec2_us_east_1b.stub(:id).and_return("i-d2e638f9")
      ec2_us_east_1b.stub(:availability_zone).and_return("us-east-1b")
      ec2_us_east_1b.stub(:public_dns_name).and_return("ec2-1-2-3-4.compute-1.amazonaws.com")
      ec2_us_east_1b.stub(:private_ip_address).and_return("1.2.3.4")
      ec2_us_east_1e.stub(:id).and_return("i-d3e638f8")
      ec2_us_east_1e.stub(:availability_zone).and_return("us-east-1e")
      ec2_us_east_1e.stub(:public_dns_name).and_return("ec2-5-6-7-8.compute-1.amazonaws.com")
      ec2_us_east_1e.stub(:private_ip_address).and_return("5.6.7.8")
      mock_elb.stub(:load_balancers).and_return(load_balancer_collection)
      mock_elb.stub(:instances).and_return(ec2_instances)
      AWS::ELB.stub(:new).and_return(mock_elb)
      AWS::EC2.stub(:new).and_return(mock_ec2)
    end

    context "elb not found" do
      before(:each) do
        load_balancer_collection.stub(:[]).with('foo').and_return(nil)
      end

      it "raises a RuntimeError if elb not found" do
        expect {subject.send(:instances)}.to raise_error(RuntimeError, "No active ELB 'foo' found!")
      end
    end

    context "elb not active" do
      before(:each) do
        load_balancer_collection.stub(:[]).with('foo').and_return(mock_elb)
        mock_elb.stub(:exists?).and_return(false)
      end

      it "raises a RuntimeError if elb not found" do
        expect {subject.send(:instances)}.to raise_error(RuntimeError, "No active ELB 'foo' found!")
      end
    end

    context "elb exists" do
      before(:each) do
        load_balancer_collection.stub(:[]).with('foo').and_return(mock_elb)
        mock_elb.stub(:exists?).and_return(true)
        ec2_instances.stub(:health).and_return([{:instance => ec2_us_east_1b, :state => 'InService'}, {:instance => ec2_us_east_1e, :state => 'InService'}])
      end

      it 'configures backends when they change' do
        expect(subject).to receive(:sleep_until_next_check) do |arg|
          subject.instance_variable_set('@should_exit', true)
        end
        expect(subject).to receive(:'reconfigure!').once
        expect(subject).to receive(:instances).once.and_call_original
        expect(subject).to receive(:configure_backends).once.with([{"name"=>"ec2-1-2-3-4.compute-1.amazonaws.com", "host"=>"1.2.3.4", "port"=>9898}, {"name"=>"ec2-5-6-7-8.compute-1.amazonaws.com", "host"=>"5.6.7.8", "port"=>9898, "backup"=>true}]).and_call_original
        subject.send(:watch)
      end

      it 'only configures healthy instances as backends' do
        ec2_instances.stub(:health).and_return([{:instance => ec2_us_east_1b, :state => 'InService'}, {:instance => ec2_us_east_1e, :state => 'OutOfService'}])
        expect(subject).to receive(:sleep_until_next_check) do |arg|
          subject.instance_variable_set('@should_exit', true)
        end
        expect(subject).to receive(:'reconfigure!').once
        expect(subject).to receive(:instances).once.and_call_original
        expect(subject).to receive(:configure_backends).once.with([{"name"=>"ec2-1-2-3-4.compute-1.amazonaws.com", "host"=>"1.2.3.4", "port"=>9898}]).and_call_original
        subject.send(:watch)
      end

      it "doesn't configures backends if they don't change" do
        expect(subject).to receive(:sleep_until_next_check) do |arg|
          subject.instance_variable_set('@should_exit', true)
        end
        expect(subject).to_not receive(:'reconfigure!')
        expect(subject).to receive(:instances).and_return([])
        expect(subject).to_not receive(:configure_backends)
        subject.send(:watch)
      end
    end
  end
end
