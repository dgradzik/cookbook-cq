#
# Cookbook Name:: cq
# Provider:: osgi_config
#
# Copyright (C) 2015 Jakub Wadolowski
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

def whyrun_supported?
  true
end

# Get a list of all OSGi configurations
#
# @return [String] list of all OSGi configurations
def osgi_config_list
  cmd_str = "#{node['cq-unix-toolkit']['install_dir']}/cqcfgls "\
            "-i #{new_resource.instance} "\
            "-u #{new_resource.username} "\
            "-p #{new_resource.password} "

  cmd = Mixlib::ShellOut.new(cmd_str)
  cmd.run_command

  Chef::Log.debug("Executing #{cmd_str}")

  begin
    cmd.error!
    cmd.stdout
  rescue => e
    Chef::Application.fatal!("Can't get a list of OSGi configurations!\n"\
                             "Error description: #{e}")
  end
end

# Returns all OSGi configs created from a specific factory
#
# @return [Array of Strings] all factory configs that matches factory pid
def factory_config_list
  # Convert factory pid to a regex form and add a suffix to match just
  # instances and not the factory pid itself
  regex = new_resource.factory_pid.gsub(/\./, '\.') + '\..+'

  osgi_config_list.scan(/#{regex}/)
end

# Checks presence of OSGi config
#
# @return [Boolean] true if OSGi config exists, false otherwise
def osgi_config_presence
  osgi_config_list.include? new_resource.pid
end

# Get properties of existing OSGi configuration
#
# @return [JSON] properties of given OSGi configuration
def osgi_config_properties
  cmd_str = "#{node['cq-unix-toolkit']['install_dir']}/cqcfg "\
            "-i #{new_resource.instance} "\
            "-u #{new_resource.username} "\
            "-p #{new_resource.password} "\
            '-j ' +
            new_resource.pid

  cmd = Mixlib::ShellOut.new(cmd_str)
  cmd.run_command

  begin
    cmd.error!
    JSON.parse(cmd.stdout)['properties']
  rescue => e
    Chef::Application.fatal!("Can't get #{new_resource.pid} properties!\n"\
                             "Error description: #{e}")
  end
end

# Parse OSGi config properties to get a simple hash (key-value) from all items.
# Additionally sort and get rid of duplicated entries (if any)
#
# @return [Hash] key value pairs
def current_properties_hash
  kv = {}

  osgi_config_properties.each_pair do |key, val|
    kv[key] = val['value']
    kv[key] = val['values'].sort.uniq if kv[key].nil?
  end

  kv
end

# Returns merged properties from new and current resources
#
# @return [Hash] merged properties
def merged_properties
  current_resource.properties.merge(
    new_resource.properties) do |key, oldval, newval|
      if oldval.is_a?(Array)
        (oldval + newval).sort.uniq
      else
        newval
      end
  end
end

# Compares properties of new and current resources
#
# @return [Boolean] true if properties match, false otherwise
def validate_properties
  # W/o append flag simple comparison is all we need
  if !new_resource.append
    sanitized_new_properties.to_a.sort.uniq ==
      current_resource.properties.to_a.sort.uniq
  else
    # If append flag is present, more sophisticated comparison is required
    merged_properties.to_a.sort.uniq ==
      current_resource.properties.to_a.sort.uniq
  end
end

# Sanitize new resource properties (sort and get rid of duplicates). Takes
# 'append' attribute into account and returns merged properties (new +
# current) if it's set to true.
#
# @return [Hash] sanitized hash of new resource properties
def sanitized_new_properties
  if new_resource.append
    local_properties = merged_properties
  else
    local_properties = @new_resource.properties
  end

  local_properties.each do |k, v|
    local_properties[k] = v.sort.uniq if v.is_a?(Array)
  end

  local_properties
end

def load_current_resource
  @current_resource = Chef::Resource::CqOsgiConfig.new(new_resource.pid)

  # Set attribute accessors
  @current_resource.exists = osgi_config_presence

  # Load OSGi properties for existing configuration and check validity
  @current_resource.properties(current_properties_hash) if
    current_resource.exists
  @current_resource.valid = validate_properties if current_resource.exists

  # Chef::Log.error(">>> NEW: #{new_resource.properties}")
  # if current_resource.exists
  #   Chef::Log.error(">>> CURRENT: #{current_resource.properties}")
  #   Chef::Log.error(">>> VALID: #{current_resource.valid}")
  #   Chef::Log.error(">>> MERGED: #{merged_properties}") if new_resource.append
  # end
end

# Converts properties hash to -s KEY -v VALUE string for cqcfg execution
#
# @return [String] key/value string for cqcfg exec
def cqcfg_params
  param_str = ''

  sanitized_new_properties.each do |k, v|
    if v.is_a?(Array)
      v.each do |v1|
        param_str += "-s \"#{k}\" -v \"#{v1}\" "
      end
    else
      param_str += "-s \"#{k}\" -v \"#{v}\" "
    end
  end

  param_str
end

# Create OSGi config with given attributes. If OSGi config already exists (but
# does not match), it will update that OSGi config to match.
def create_osgi_config
  cmd_str = "#{node['cq-unix-toolkit']['install_dir']}/cqcfg "\
            "-i #{new_resource.instance} "\
            "-u #{new_resource.username} "\
            "-p #{new_resource.password} " +
            cqcfg_params + new_resource.pid

  cmd = Mixlib::ShellOut.new(cmd_str)
  cmd.run_command

  begin
    cmd.error!
  rescue => e
    Chef::Application.fatal!("Can't update #{new_resource.pid} properties!\n"\
                             "Error description: #{e}")
  end
end

# Delete OSGi config.
def delete_osgi_config
  # TODO
end

# Modify an existing config. It will raise an exception if item does not exist.
def modify_osgi_config
  # TODO
end

# Modify an existing config. It will not raise an exception if item does not
# exist.
def manage_osgi_config
  # TODO
end

action :create do
  if !@current_resource.exists
    Chef::Log.error("OSGi config #{new_resource.pid} does NOT exists!")
  elsif @current_resource.exists && @current_resource.valid
    Chef::Log.info("OSGi config #{new_resource.pid} is already in valid "\
                   'state - nothing to do')
  else
    converge_by("Create #{ new_resource }") do
      create_osgi_config
    end
  end
end
