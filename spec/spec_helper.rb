begin
  require 'spec'
rescue LoadError
  require 'rubygems'
  gem 'rspec'
  require 'spec'
end

require 'drb'
require 'digest/sha1'

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), "..", "lib")
$LOAD_PATH.unshift File.dirname(__FILE__)

require 'rubyrep'
require 'connection_extender_interface_spec'


  # Used to temporary mock out the given +method+ (a symbol) of the provided +klass+.
  # After calling the given +blck+ reverts the method mock.
  # This is for cases where a method call has to be mocked of an object that is 
  # not yet created. 
  # (Couldn't find out how to do that using existing rspec mocking features.)
  def mock_method(klass, method, &blck)
    tmp_method = "original_before_mocking_#{method}".to_sym
    logger_key = "#{klass.name}_#{method}"
    $mock_method_marker ||= {}
    $mock_method_marker[logger_key] = mock("#{logger_key}")
    $mock_method_marker[logger_key].should_receive(:notify).at_least(:once)
    klass.send :alias_method, tmp_method, method
    klass.class_eval "def #{method}(*args); $mock_method_marker['#{logger_key}'].notify; end"
    blck.call
  ensure
    klass.send :alias_method, method, tmp_method
  end
  
# If number_of_calls is :once, mock ActiveRecord for 1 call.
# If number_of_calls is :twice, mock ActiveRecord for 2 calls.
def mock_active_record(number_of_calls)
  ConnectionExtenders::DummyActiveRecord.should_receive(:establish_connection).send(number_of_calls) \
    .and_return {|config| $used_config = config}
    
  dummy_connection = Object.new
  # We have a spec testing behaviour for non-existing extenders.
  # So extend might not be called in all cases
  dummy_connection.should_receive(:extend).any_number_of_times
    
  ConnectionExtenders::DummyActiveRecord.should_receive(:connection).send(number_of_calls) \
    .and_return {dummy_connection}
end

# Creates a mock ProxySession with the given
#   * mock_table: name of the mock table
#   * primary_key_names: array of mock primary column names
#   * column_names: array of mock column names, if nil: doesn't mock this function
def create_mock_session(mock_table, primary_key_names, column_names = nil)
  session = mock("ProxySession")
  if primary_key_names
    session.should_receive(:primary_key_names) \
      .with(mock_table) \
      .and_return(primary_key_names)
  end
  if column_names
    session.should_receive(:column_names) \
      .with(mock_table) \
      .and_return(column_names)
  end
  session.should_receive(:quote_value) \
    .any_number_of_times \
    .with(an_instance_of(String), an_instance_of(String), anything) \
    .and_return {| value, column, value| value}
      
  session
end
 
# Returns a deep copy of the provided object.
def deep_copy(object)
  Marshal.restore(Marshal.dump(object))
end

# Allows the temporary faking of RUBY_PLATFORM to the given value
# Needs to be called with a block. While the block is executed, RUBY_PLATFORM
# is set to the given fake value
def fake_ruby_platform(fake_ruby_platform)
  old_ruby_platform = RUBY_PLATFORM
  old_verbose, $VERBOSE = $VERBOSE, nil
  Object.const_set 'RUBY_PLATFORM', fake_ruby_platform
  $VERBOSE = old_verbose
  yield
ensure
  $VERBOSE = nil
  Object.const_set 'RUBY_PLATFORM', old_ruby_platform
  $VERBOSE = old_verbose
end

# Reads the database configuration from the config folder for the specified config key
# E.g. if config is :postgres, tries to read the config from 'postgres_config.rb'
def read_config(config)
  $config_cache ||= {}
  unless $config_cache[config]
    # load the proxied config but ensure that the original configuration is restored
    old_config = RR::Initializer.configuration
    RR::Initializer.reset
    begin
      load File.dirname(__FILE__) + "/../config/#{config}_config.rb"
      $config_cache[config] = RR::Initializer.configuration
    ensure
      RR::Initializer.configuration = old_config
    end
  end
  $config_cache[config]
end

# Removes all cached database configurations
def clear_config_cache
  $config_cache = {}
end

# Retrieves the proxied database config as specified in config/proxied_test_config.rb
def proxied_config
  read_config :proxied_test
end

# Retrieves the standard (non-proxied) database config as specified in config/test_config.rb
def standard_config
  read_config :test
end

# If true, start proxy as external process (more realistic test but also slower).
# Otherwise start in the current process as thread.
$start_proxy_as_external_process ||= false

# Starts a proxy under the given host and post
def start_proxy(host, port)
  if $start_proxy_as_external_process
    rrproxy_path = File.join(File.dirname(__FILE__), "..", "bin", "rrproxy.rb")
    ruby = RUBY_PLATFORM =~ /java/ ? 'jruby' : 'ruby'
    cmd = "#{ruby} #{rrproxy_path} -h #{host} -p #{port}"
    Thread.new {system cmd}    
  else
    url = "druby://#{host}:#{port}"
    DRb.start_service(url, DatabaseProxy.new)    
  end
end

# Set to true if the proxy as per SPEC_PROXY_CONFIG is running 
$proxy_confirmed_running = false

# Starts a proxy as per left proxy settings defined in config/proxied_test_config.rb.
# Only starts the proxy though if none is running yet at the according host / port.
# If it starts a proxy child process, it also prepares automatic termination
# after the spec run is finished.
def ensure_proxy
  # only execute the network verification once per spec run
  unless $proxy_confirmed_running
    drb_url = "druby://#{proxied_config.left[:proxy_host]}:#{proxied_config.left[:proxy_port]}"
    # try to connect to the proxy
    begin
      proxy = DRbObject.new nil, drb_url
      proxy.ping
      $proxy_confirmed_running = true
    rescue DRb::DRbConnError => e
      # Proxy not yet running ==> start it
      start_proxy proxied_config.left[:proxy_host], proxied_config.left[:proxy_port]
      
      maximum_startup_time = 5 # maximum time in seconds for the proxy to start
      waiting_time = 0.1 # time to wait between connection attempts
      
      time = 0.0
      ping_response = ''
      # wait for the proxy to start up and become operational
      while ping_response != 'pong' and time < maximum_startup_time
        begin
          proxy = DRbObject.new nil, drb_url
          ping_response = proxy.ping
          break
        rescue DRb::DRbConnError => e
          # do nothing (just try again)
        end
        sleep waiting_time
        time += waiting_time
      end
      if ping_response == 'pong'
        #puts "Proxy started (took #{time} seconds)"
        # Ensure that the started proxy is terminated with the completion of the spec run.
        at_exit do
          proxy = DRbObject.new nil, drb_url
          proxy.terminate! rescue DRb::DRbConnError
        end if $start_proxy_as_external_process
      else
        raise "Could not start proxy"
      end
    end
    
    # if we got till here, then a proxy is running or was successfully started
    $proxy_confirmed_running = true
  end
end