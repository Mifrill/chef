#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/provider/package'
require 'chef/mixin/command'
require 'chef/resource/package'
require 'singleton'

class Chef
  class Provider
    class Package
      class Yum < Chef::Provider::Package

        class RPMUtils
          class << self

            # RPM::Version version_parse equivalent
            def version_parse(evr)
              return if evr.nil?

              epoch = nil
              # assume this is a version
              version = evr
              release = nil

              lead = 0
              tail = evr.size

              if evr =~ %r{^([\d]+):}
                epoch = $1.to_i
                lead = $1.length + 1
              elsif evr[0].ord == ":".ord
                epoch = 0
                lead = 1
              end

              if evr =~ %r{:?.*-(.*)$}
                release = $1
                tail = evr.length - release.length - lead - 1

                if release.empty?
                  release = nil
                end
              end

              version = evr[lead,tail]

              [ epoch, version, release ]
            end

            # verify 
            def isalnum(x)
              isalpha(x) or isdigit(x)
            end

            def isalpha(x)
              v = x.ord
              (v >= 65 and v <= 90) or (v >= 97 and v <= 122)
            end

            def isdigit(x)
              v = x.ord
              v >= 48 and v <= 57
            end

            # based on the reference spec in lib/rpmvercmp.c in rpm 4.9.0
            def rpmvercmp(x, y)
              # easy! :)
              return 0 if x == y

              if x.nil?
                x = ""
              end
              
              if y.nil?
                y = ""
              end

              # not so easy :(
              #
              # takes 2 strings like
              # 
              # x = "1.20.b18.el5"
              # y = "1.20.b17.el5"
              #
              # breaks into purely alpha and numeric segments and compares them using
              # some rules
              # 
              # * 10 > 1 
              # * 1 > a
              # * z > a
              # * Z > A
              # * z > Z
              # * leading zeros are ignored
              # * separators (periods, commas) are ignored
              # * "1.20.b18.el5.extrastuff" > "1.20.b18.el5"

              x_pos = 0                # overall string element reference position
              x_pos_max = x.length - 1 # number of elements in string, starting from 0
              x_seg_pos = 0            # segment string element reference position
              x_comp = nil             # segment to compare

              y_pos = 0
              y_seg_pos = 0
              y_pos_max = y.length - 1
              y_comp = nil

              while (x_pos <= x_pos_max and y_pos <= y_pos_max)
                # first we skip over anything non alphanumeric
                while (x_pos <= x_pos_max) and (isalnum(x[x_pos]) == false)
                  x_pos += 1 # +1 over pos_max if end of string
                end
                while (y_pos <= y_pos_max) and (isalnum(y[y_pos]) == false)
                  y_pos += 1
                end

                # if we hit the end of either we are done matching segments
                if (x_pos == x_pos_max + 1) or (y_pos == y_pos_max + 1)
                  break
                end

                # we are now at the start of a alpha or numeric segment
                x_seg_pos = x_pos
                y_seg_pos = y_pos

                # grab segment so we can compare them
                if isdigit(x[x_seg_pos].ord)
                  x_seg_is_num = true

                  # already know it's a digit
                  x_seg_pos += 1

                  # gather up our digits
                  while (x_seg_pos <= x_pos_max) and isdigit(x[x_seg_pos])
                    x_seg_pos += 1
                  end
                  # copy the segment but not the unmatched character that x_seg_pos will
                  # refer to
                  x_comp = x[x_pos,x_seg_pos - x_pos]

                  while (y_seg_pos <= y_pos_max) and isdigit(y[y_seg_pos])
                    y_seg_pos += 1
                  end
                  y_comp = y[y_pos,y_seg_pos - y_pos]
                else
                  # we are comparing strings
                  x_seg_is_num = false

                  while (x_seg_pos <= x_pos_max) and isalpha(x[x_seg_pos])
                    x_seg_pos += 1
                  end
                  x_comp = x[x_pos,x_seg_pos - x_pos]

                  while (y_seg_pos <= y_pos_max) and isalpha(y[y_seg_pos])
                    y_seg_pos += 1
                  end
                  y_comp = y[y_pos,y_seg_pos - y_pos]
                end

                # if y_seg_pos didn't advance in the above loop it means the segments are
                # different types
                if y_pos == y_seg_pos
                  # numbers always win over letters
                  return x_seg_is_num ? 1 : -1
                end

                # move the ball forward before we mess with the segments 
                x_pos += x_comp.length # +1 over pos_max if end of string
                y_pos += y_comp.length

                # we are comparing numbers - simply convert them
                if x_seg_is_num
                  x_comp = x_comp.to_i
                  y_comp = y_comp.to_i
                end

                # compares ints or strings
                # don't return if equal - try the next segment
                if x_comp > y_comp
                  return 1
                elsif x_comp < y_comp
                  return -1
                end

                # if we've reached here than the segments are the same - try again
              end

              # we must have reached the end of one or both of the strings and they
              # matched up until this point

              # segments matched completely but the segment separators were different -
              # rpm reference code treats these as equal.
              if (x_pos == x_pos_max + 1) and (y_pos == y_pos_max + 1)
                return 0
              end

              # the most unprocessed characters left wins 
              if (x_pos_max - x_pos) > (y_pos_max - y_pos)
                return 1
              else
                return -1
              end
            end

          end # self
        end # RPMUtils

        class RPMPackage
          include Comparable

          def initialize(*args)
            if args.size == 3
              @n = args[0]
              @e, @v, @r = RPMUtils.version_parse(args[1])
              @a = args[2]
            elsif args.size == 5
              @n = args[0]
              @e = args[1].to_i
              @v = args[2]
              @r = args[3]
              @a = args[4]
            else
              raise ArgumentError, "Expecting either 'name, epoch-version-" +
                "release, arch' or 'name, epoch, version, release, arch'"
            end
          end
          attr_reader :n, :e, :v, :r, :a
          alias :name :n
          alias :epoch :e
          alias :version :v
          alias :release :r
          alias :arch :a

          # rough RPM::Version rpm_version_cmp equivalent - except much slower :)
          def <=>(y)
            x = self

            # compare name
            if x.n.nil? == false and y.n.nil?
              return 1
            elsif x.n.nil? and y.n.nil? == false
              return -1
            elsif x.n.nil? == false and y.n.nil? == false
              if x.n < y.n
                return -1
              elsif x.n > y.n
                return 1
              end
            end

            # compare epoch
            if (x.e.nil? == false and x.e > 0) and y.e.nil?
              return 1
            elsif x.e.nil? and (y.e.nil? == false and y.e > 0)
              return -1
            elsif x.e.nil? == false and y.e.nil? == false
              if x.e < y.e
                return -1
              elsif x.e > y.e
                return 1
              end
            end

            # compare version
            if x.v.nil? == false and y.v.nil?
              return 1
            elsif x.v.nil? and y.v.nil? == false
              return -1
            elsif x.v.nil? == false and y.v.nil? == false
              cmp = RPMUtils.rpmvercmp(x.v, y.v)
              return cmp if cmp != 0
            end

            # compare release 
            if x.r.nil? == false and y.r.nil?
              return 1
            elsif x.r.nil? and y.r.nil? == false
              return -1
            elsif x.r.nil? == false and y.r.nil? == false
              cmp = RPMUtils.rpmvercmp(x.r, y.r)
              return cmp if cmp != 0
            end

            # compare arch
            if x.a.nil? == false and y.a.nil?
              return 1
            elsif x.a.nil? and y.a.nil? == false
              return -1
            elsif x.a.nil? == false and y.a.nil? == false
              if x.a < y.a
                return -1
              elsif x.a > y.a
                return 1
              end
            end

            return 0
          end

          # RPM::Version rpm_version_to_s equivalent
          def to_s 
            if @r.nil?
              @v
            else
              "#{@v}-#{@r}"
            end
          end

          def nevra
            "#{@n}-#{@e}:#{@v}-#{@r}.#{@a}"
          end

        end
        
        class RPMDbPackage < RPMPackage
          # <rpm parts>, installed, available
          def initialize(*args)
            # state
            @available = args.pop
            @installed = args.pop
            super(*args)
          end
          attr_reader :available, :installed
        end

        # Simple storage for RPMPackage objects - keeps them unique and sorted 
        class RPMDb
          def initialize
            @rpms = Hash.new
            @available = Set.new
            @installed = Set.new
          end
          
          def [](package_name)
            self.lookup(package_name) 
          end

          def lookup(package_name)
            @rpms[package_name]
          end
          
          # Using the package name as a key keep a unique, descending list of packages.
          # The available/installed state can be overwritten for existing packages.
          def push(*args)
            args.flatten.each do |new_rpm|
              unless new_rpm.kind_of?(RPMDbPackage)
                raise ArgumentError, "Expecting an RPMDbPackage object"
              end

              @rpms[new_rpm.n] ||= Array.new

              # new_rpm may be a different object but it will be compared using RPMPackages <=>
              idx = @rpms[new_rpm.n].index(new_rpm)
              if idx
                # grab the existing package if it's not
                curr_rpm = @rpms[new_rpm.n][idx]
              else
                @rpms[new_rpm.n] << new_rpm
                @rpms[new_rpm.n].sort!
                @rpms[new_rpm.n].reverse!

                curr_rpm = new_rpm
              end

              # these are overwritten for existing packages
              if new_rpm.available
                @available << curr_rpm
              end
              if new_rpm.installed
                @installed << curr_rpm
              end
            end
          end

          def <<(*args)
            self.push(args)
          end

          def clear
            @rpms.clear
            clear_available
            clear_installed
          end

          def clear_available
            @available.clear
          end

          def clear_installed
            @installed.clear
          end

          def size
            @rpms.size
          end
          alias :length :size

          def available_size 
            @available.size
          end

          def installed_size
            @installed.size
          end
  
          def available?(package)
            @available.include?(package)
          end

          def installed?(package)
            @installed.include?(package)
          end
        end

        # Cache for our installed and available packages, pulled in from yum-dump.py
        class YumCache
          include Chef::Mixin::Command
          include Singleton

          def initialize
            @rpmdb = RPMDb.new

            # Next time installed/available is accessed:
            #  :all       - Trigger a run of "yum-dump.py --options", updates yum's cache and 
            #               parses options from /etc/yum.conf
            #  :installed - Trigger a run of "yum-dump.py --installed", only reads the local rpm db
            #  :none      - Do nothing, a call to reload or reload_installed is required
            @next_refresh = :all

            @allow_multi_install = []

            # these are for subsequent runs if we are on an interval
            Chef::Client.when_run_starts do
              YumCache.instance.reload
            end
          end

          # Cache management
          #
  
          def refresh
            return if @next_refresh == :none 

            if @next_refresh == :installed
              reset_installed
              opts=" --installed"
            elsif @next_refresh == :all
              reset
              opts=" --options"
            end

            one_line = false
            error = nil

            helper = ::File.join(::File.dirname(__FILE__), 'yum-dump.py')

            status = popen4("/usr/bin/python #{helper}#{opts}", :waitlast => true) do |pid, stdin, stdout, stderr|
              stdout.each do |line|
                one_line = true

                line.chomp!

                if line =~ %r{\[option (.*)\] (.*)}
                  if $1 == "installonlypkgs"
                    @allow_multi_install = $2.split
                  else
                    raise Chef::Exceptions::Package, "Strange, unknown option line '#{line}' from yum-dump.py"
                  end
                  next
                end

                parts = line.split
                unless parts.size == 6
                  Chef::Log.warn("Problem parsing line '#{line}' from yum-dump.py! " +
                                 "Please check your yum configuration.")
                  next
                end

                type = parts.pop
                if type == "i"
                  # if yum-dump was called with --installed this may not be true, but it's okay
                  # since we don't touch the @available Set in reload_installed
                  available = false
                  installed = true
                elsif type == "a"
                  available = true
                  installed = false
                elsif type == "r"
                  available = true
                  installed = true
                else
                  Chef::Log.warn("Can't parse type from output of yum-dump.py! Skipping line")
                end

                pkg = RPMDbPackage.new(*(parts + [installed, available]))
                @rpmdb << pkg
              end

              error = stderr.readlines
            end

            if status.exitstatus != 0
              raise Chef::Exceptions::Package, "Yum failed - #{status.inspect} - returns: #{error}"
            else
              unless one_line
                Chef::Log.warn("Odd, no output from yum-dump.py. Please check " +
                               "your yum configuration.")
              end
            end

            # A reload method must be called before the cache is altered
            @next_refresh = :none
          end

          def reload
            @next_refresh = :all
          end

          def reload_installed
            @next_refresh = :installed
          end

          def reset
            @rpmdb.clear
          end

          def reset_installed
            @rpmdb.clear_installed
          end

          # Querying the cache
          # 

          def version_available?(package_name, desired_version, arch=nil)
             version(package_name, arch, true, false) do |v|
               return true if desired_version == v
             end

            return false
          end

          def available_version(package_name, arch=nil)
            version(package_name, arch, true, false)
          end
          alias :candidate_version :available_version

          def installed_version(package_name, arch=nil)
            version(package_name, arch, false, true)
          end

          def allow_multi_install
            refresh
            @allow_multi_install
          end

          private

          def version(package_name, arch=nil, is_available=false, is_installed=false)
            refresh
            packages = @rpmdb[package_name]
            if packages
              packages.each do |pkg|
                if is_available
                  next unless @rpmdb.available?(pkg)
                end
                if is_installed
                  next unless @rpmdb.installed?(pkg)
                end
                if arch
                  next unless pkg.arch == arch
                end

                if block_given?
                  yield pkg.to_s
                else
                  # first match is latest version
                  return pkg.to_s
                end
              end
            end

            if block_given?
              return self
            else
              return nil
            end
          end
        end # YumCache

        def initialize(new_resource, run_context)
          super

          @yum = YumCache.instance
        end

        def arch
          if @new_resource.respond_to?("arch")
            @new_resource.arch 
          else
            nil
          end
        end

        def yum_arch
          arch ? ".#{arch}" : nil
        end

        def load_current_resource
          # Allow for foo.x86_64 style package_name like yum uses in it's output
          #
          # Don't overwrite an existing arch 
          if @new_resource.respond_to?("arch") and @new_resource.arch.nil?
            if @new_resource.package_name =~ %r{^(.*)\.(.*)$}
              new_package_name = $1
              new_arch = $2
              # foo.i386 and foo.beta1 are both valid package names or expressions of an arch.
              # Ensure we don't have an existing package matching package_name, then ensure we at
              # least have a match for the new_package+new_arch before we overwrite. If neither
              # then fall through to standard package handling.
              if (@yum.installed_version(@new_resource.package_name).nil? and @yum.candidate_version(@new_resource.package_name).nil?) and 
                   (@yum.installed_version(new_package_name, new_arch) or @yum.candidate_version(new_package_name, new_arch))
                 @new_resource.package_name(new_package_name)
                 @new_resource.arch(new_arch)
              end
            end
          end

          @current_resource = Chef::Resource::Package.new(@new_resource.name)
          @current_resource.package_name(@new_resource.package_name)

          if @new_resource.source
            unless ::File.exists?(@new_resource.source)
              raise Chef::Exceptions::Package, "Package #{@new_resource.name} not found: #{@new_resource.source}"
            end

            Chef::Log.debug("#{@new_resource} checking rpm status")
            status = popen4("rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE}\n' #{@new_resource.source}") do |pid, stdin, stdout, stderr|
              stdout.each do |line|
                case line
                when /([\w\d_.-]+)\s([\w\d_.-]+)/
                  @current_resource.package_name($1)
                  @new_resource.version($2)
                end
              end
            end
          end

          if @new_resource.version
            new_resource = "#{@new_resource.package_name}-#{@new_resource.version}#{yum_arch}"
          else
            new_resource = "#{@new_resource.package_name}#{yum_arch}"
          end

          Chef::Log.debug("#{@new_resource} checking yum info for #{new_resource}") 

          installed_version = @yum.installed_version(@new_resource.package_name, arch)
          @current_resource.version(installed_version)

          @candidate_version = @yum.candidate_version(@new_resource.package_name, arch)

          if @candidate_version.nil?
            raise Chef::Exceptions::Package, "Yum installed and available lists don't have a version of package #{@new_resource.package_name}"
          end

          Chef::Log.debug("#{@new_resource} installed version: #{installed_version || "(none)"} candidate version: #{@candidate_version}")

          @current_resource
        end

        def install_package(name, version)
          if @new_resource.source 
            run_command_with_systems_locale(
              :command => "yum -d0 -e0 -y#{expand_options(@new_resource.options)} localinstall #{@new_resource.source}"
            )
          else
            # Work around yum not exiting with an error if a package doesn't exist for CHEF-2062
            if @yum.version_available?(name, version, arch)

              # More Yum fun:
              #
              # yum install of an old name+version will exit(1)
              # yum install of an old name+version+arch will exit(0) for some reason
              #
              # Some packages can be installed multiple times like the kernel
              unless @yum.allow_multi_install.include?(name)
                # If not we bail like yum when the package is older
                if RPMUtils.rpmvercmp(@current_resource.version, version) == 1 # >
                  raise Chef::Exceptions::Package, "Installed package #{name}-#{@current_resource.version} is newer than candidate package #{name}-#{version}"
                end
              end
           
              run_command_with_systems_locale(
                :command => "yum -d0 -e0 -y#{expand_options(@new_resource.options)} install #{name}-#{version}#{yum_arch}"
              )
            else
              raise Chef::Exceptions::Package, "Version #{version} of #{name} not found. Did you specify both version and release? (version-release, e.g. 1.84-10.fc6)"
            end
          end
          @yum.reload_installed
        end

        # Keep upgrades from trying to install an older candidate version
        # Can be done in upgrade_package but an upgraded from->to log message slips out
        #
        # Hacky - better overall solution? Custom compare in Package provider?
        def action_upgrade
          # Don't restrict the attempts of someone passing a version
          if @new_resource.version.nil? == false 
            super
          # If there's no custom version ensure the candidate is newer
          elsif RPMUtils.rpmvercmp(candidate_version, @current_resource.version) == 1 # >
            super
          # No specific version passed and candidate is older
          else
            Chef::Log.debug("#{@new_resource} is at the latest version - nothing to do")
          end
        end

        def upgrade_package(name, version)
          install_package(name, version) 
        end

        def remove_package(name, version)
          if version
            run_command_with_systems_locale(
             :command => "yum -d0 -e0 -y#{expand_options(@new_resource.options)} remove #{name}-#{version}#{yum_arch}"
            )
          else
            run_command_with_systems_locale(
             :command => "yum -d0 -e0 -y#{expand_options(@new_resource.options)} remove #{name}#{yum_arch}"
            )
          end
          @yum.reload_installed
        end

        def purge_package(name, version)
          remove_package(name, version)
        end

      end
    end
  end
end
