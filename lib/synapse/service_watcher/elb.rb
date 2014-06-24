require 'synapse/service_watcher/base'
require 'net/http'
require 'aws/elb'

module Synapse
  class ElbWatcher < BaseWatcher

    def initialize(opts={}, synapse)
      super
      @elb_client = AWS::ELB.new
      @my_zone = Net::HTTP.get(URI('http://169.254.169.254/latest/meta-data/placement/availability-zone'))
      log.info "running in AWS zone #{@my_zone}"
    end

    def start
      @check_interval = @discovery['check_interval'] || 30.0
      @watcher = Thread.new { watch }
    end


    private

    def validate_discovery_opts
      raise ArgumentError, "discovery method must be set to 'elb'" unless @discovery['method'] && @discovery['method'] == 'elb'
      raise ArgumentError, "elb-name is required" if @discovery['elb-name'].nil? || @discovery['elb-name'].empty?
    end

    def sleep_until_next_check(start_time)
      sleep_time = @check_interval - (Time.now - start_time)
      if sleep_time > 0.0
        sleep(sleep_time)
      end
    end

    def watch
      last_instances = []
      until @should_exit
        begin
          start = Time.now
          current_instances = instances
          if last_instances != current_instances
            last_instances = current_instances
            configure_backends(last_instances)
          else
            log.info "No changes found to healthy instances"
          end

          sleep_until_next_check(start)
        rescue Exception => e
          log.error "Error in watcher thread!"
          log.error e.inspect
          log.error e.backtrace.join("\n")
        end
      end

      log.info "ElbWatcher exited successfully"
    end

    def instances
      elb = @elb_client.load_balancers[@discovery['elb-name']]
      raise RuntimeError, "No active ELB '#{@discovery['elb-name']}' found!" if elb.nil? || !elb.exists?
      log.info "Found active ELB '#{@discovery['elb-name']}'"

      all_instances = elb.instances
      healthy_instances_by_zone = {}
      total_healthy_instances = 0
      all_instances.health.each do |instance_health|
        if instance_health[:state] == 'InService'
          total_healthy_instances += 1
          instance = all_instances.find {|i| i.id == instance_health[:instance].id}
          if healthy_instances_by_zone.has_key?(instance.availability_zone)
            healthy_instances_by_zone[instance.availability_zone] << instance
          else
            healthy_instances_by_zone[instance.availability_zone] = [instance]
          end
        end
      end

      log.info "Found #{total_healthy_instances} healthy instances:"
      healthy_instances_by_zone.each_pair do |key, value|
        log.info "  #{key}: #{value.map(&:id)}"
      end

      all_zones = healthy_instances_by_zone.keys
      if all_zones.include?(@my_zone)
        all_zones.delete(@my_zone)
        all_zones = all_zones.unshift(@my_zone)
      end

      healthy_instances = []
      all_zones.each do |zone|
        healthy_instances_by_zone[zone].each do |instance|
          server_hash = {'name' => instance.public_dns_name,
                         'host' => instance.private_ip_address,
                         'port' => @haproxy['server_port_override']}
          if @discovery['prefer-same-zone'] && @discovery['prefer-same-zone'] == true
            # any server not in my zone is marked as a backup
            server_hash['backup'] = true if zone != @my_zone
          end
          healthy_instances << server_hash
        end
      end

      healthy_instances
    end

    def configure_backends(new_backends)
      if new_backends.empty?
        if @default_servers.empty?
          log.warn "No backends and no default servers configured for service #{@name};" \
            " using previous backends: #{@backends.inspect}"
        else
          log.warn "No backends for service #{@name};" \
            " using default servers: #{@default_servers.inspect}"
          @backends = @default_servers
        end
      else
        log.info "Discovered #{new_backends.length} backends for service #{@name}"
        set_backends(new_backends)
      end
      reconfigure!
    end
  end
end
