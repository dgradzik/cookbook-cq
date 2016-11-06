#
# Cookbook Name:: cq
# Provider:: package
#
# Copyright (C) 2016 Jakub Wadolowski
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

class Chef
  class Provider
    class CqPackage < Chef::Provider
      include Cq::HttpHelper
      include Cq::OsgiBundleHelper
      include Cq::PackageHelper

      provides :cq_package if Chef::Provider.respond_to?(:provides)

      def whyrun_supported?
        false
      end

      def load_current_resource
        # Download package and get info out of it
        # ---------------------------------------------------------------------
        @new_resource.local_path = local_path
        Chef::Log.debug("Local path: #{new_resource.local_path}")

        package_download(
          new_resource.source,
          new_resource.local_path,
          new_resource.http_user,
          new_resource.http_pass
        )

        @new_resource.healthcheck_params = healthcheck_params(
          new_resource.rescue_mode,
          new_resource.same_state_barrier,
          new_resource.error_state_barrier,
          new_resource.max_attempts,
          new_resource.sleep_time
        )

        populate_xml_properties

        # Get information from CRX Package Manager
        # ---------------------------------------------------------------------
        refresh_package_manager_data

        @new_resource.uploaded = uploaded?
        Chef::Log.debug("Uploaded? #{new_resource.uploaded}")

        # If package is not uploaded there's no need to look for information in
        # CRX Package Manager
        return unless new_resource.uploaded

        @new_resource.installed = installed?
        Chef::Log.debug("Installed? #{new_resource.installed}")

        populate_crx_properties
      end

      def populate_xml_properties
        xml = properties_xml_file(new_resource.local_path)
        Chef::Log.debug("properties.xml: #{xml}")

        @new_resource.xml_name = xml_property(xml, 'name')
        @new_resource.xml_group = xml_property(xml, 'group')
        @new_resource.xml_version = xml_property(xml, 'version')

        Chef::Log.debug("Name (XML): #{new_resource.xml_name}")
        Chef::Log.debug("Group (XML): #{new_resource.xml_group}")
        Chef::Log.debug("Version (XML): #{new_resource.xml_version}")
      end

      def refresh_package_manager_data
        # All packages
        all_pkgs = package_list(
          new_resource.instance,
          new_resource.username,
          new_resource.password
        )

        # Uploaded packages
        @uploaded_packages = uploaded_packages(all_pkgs)
        Chef::Log.debug("Found #{@uploaded_packages.size} uploaded package(s)")

        # Package info
        @package_info = package_info(@uploaded_packages)
        Chef::Log.debug("Package info: #{@package_info}")
      end

      def populate_crx_properties
        @current_resource ||= Chef::Resource::CqPackage.new(new_resource.name)

        @current_resource.crx_name = crx_property(@package_info, 'name')
        @current_resource.crx_group = crx_property(@package_info, 'group')
        @current_resource.crx_version = crx_property(@package_info, 'version')
        @current_resource.crx_download_name = crx_property(
          @package_info, 'downloadName'
        )

        Chef::Log.debug("Name (CRX): #{current_resource.crx_name}")
        Chef::Log.debug("Group (CRX): #{current_resource.crx_group}")
        Chef::Log.debug("Version (CRX): #{current_resource.crx_version}")
        Chef::Log.debug(
          "Download name (CRX): #{current_resource.crx_download_name}"
        )
      end

      def uploaded?
        if @package_info.nil?
          false
        else
          true
        end
      end

      def installed?
        pkgs = installed_packages

        # 0 installed packages
        return false if pkgs.empty?

        # It's possible that given package was upgraded/downgraded previously,
        # so we need to look for the one that's the most fresh
        #
        # The assumption is that lastUnpacked is always in a parsable format.
        # Since that's generated by CRX itself it's very unlikely that it might
        # be invalid.
        require 'date'

        newest_pkg = installed_packages.first

        pkgs.each_cons(2) do |p1, p2|
          newest_pkg = p1
          newest_pkg = p2 if DateTime.parse(crx_property(p1, 'lastUnpacked')) <
                             DateTime.parse(crx_property(p2, 'lastUnpacked'))
        end

        # Verify whether the newest package is in the same version as the one
        # defined in the resource itself
        return true if crx_property(newest_pkg, 'version') ==
                       new_resource.xml_version

        # Run out of options
        false
      end

      def package_info(pkg_list)
        pkg_list.each do |p|
          return p if crx_property(p, 'version') == new_resource.xml_version
        end

        # Return nil if 0 packages meet name/group/version requirements
        nil
      end

      def uploaded_packages(pkg_list)
        pkgs = []

        pkg_list.elements.each('package') do |p|
          pkgs.push(p) if crx_property(p, 'name') == new_resource.xml_name &&
                          crx_property(p, 'group') == new_resource.xml_group
        end

        pkgs
      end

      # Extract elements with not empty lastUnpacked property out of the list
      # of uploaded packages
      def installed_packages
        pkgs = []

        @uploaded_packages.each do |p|
          last_unpacked = crx_property(p, 'lastUnpacked')
          pkgs.push(p) if !last_unpacked.nil? && !last_unpacked.empty?
        end

        Chef::Log.debug("Found #{pkgs.size} ever installed package(s)")

        pkgs
      end

      def local_path
        ::File.join(
         Chef::Config[:file_cache_path],
          uri_basename(new_resource.source)
        )
      end

      # Actions
      # -----------------------------------------------------------------------
      def trigger_upload
        Chef::Log.debug("Uploading #{new_resource.name} package")

        package_upload(
          new_resource.instance,
          new_resource.username,
          new_resource.password,
          new_resource.local_path
        )
      end

      def trigger_install
        Chef::Log.debug("Installing #{new_resource.name} package")

        package_install(
          new_resource.instance,
          new_resource.username,
          new_resource.password,
          crx_path(
            current_resource.crx_group,
            current_resource.crx_download_name
          ),
          new_resource.recursive_install
        )

        osgi_bundle_stability(
          new_resource.instance,
          new_resource.username,
          new_resource.password,
          new_resource.healthcheck_params
        )
      end

      def action_upload
        if new_resource.uploaded
          Chef::Log.info("Package #{new_resource.name} is already uploaded")
        else
          converge_by("Upload #{new_resource}") do
            trigger_upload
          end
        end
      end

      def action_install
        if new_resource.uploaded
          if new_resource.installed
            Chef::Log.info("Package #{new_resource.name} is already installed")
          else
            converge_by("Install #{new_resource.name}") do
              trigger_install
            end
          end
        else
          Chef::Log.error("Can't install not uploaded package!")
        end
      end

      def action_deploy
        if new_resource.uploaded
          if new_resource.installed
            Chef::Log.info(
              "Package #{new_resource.name} is already uploaded and installed"
            )
          else
            converge_by("Install #{new_resource.name}") do
              trigger_install
            end
          end
        else
          converge_by("Upload and install #{new_resource.name}") do
            trigger_upload

            # After package upload all CRX metadata needs to be populated
            refresh_package_manager_data
            populate_crx_properties

            trigger_install
          end
        end
      end

      def action_uninstall
        if new_resource.installed
          converge_by("Uninstall #{new_resource.name}") do
            package_uninstall(
              new_resource.instance,
              new_resource.username,
              new_resource.password,
              crx_path(
                current_resource.crx_group,
                current_resource.crx_download_name
              )
            )

            osgi_bundle_stability(
              new_resource.instance,
              new_resource.username,
              new_resource.password,
              new_resource.healthcheck_params
            )
          end
        elsif new_resource.uploaded
          Chef::Log.warn(
            "Package #{new_resource.name} is already uninstalled"
          )
        else
          Chef::Log.warn("Can't uninstall not existing package!")
        end
      end

      def action_delete
        if new_resource.uploaded
          converge_by("Delete #{new_resource.name}") do
            package_delete(
              new_resource.instance,
              new_resource.username,
              new_resource.password,
              crx_path(
                current_resource.crx_group,
                current_resource.crx_download_name
              )
            )
          end
        else
          Chef::Log.warn("Package #{new_resource.name} is already deleted")
        end
      end
    end
  end
end
