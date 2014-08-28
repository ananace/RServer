require 'open-uri'

require 'rubygems'
gem 'inifile'
gem 'json'

require 'json'
require 'inifile'

VALID_GAMES = [ 'garrysmod' ]

class Server

    attr_accessor :game, :base_path, :path, :addons, :gamemodes, :arguments
    attr_accessor :pid, :running, :base_arguments, :status, :steampipe
    attr_reader :name, :appid, :version, :update, :update_check

    def self.parse(data)
        folder = File.expand_path("~/.local/share/rserv")

        name = data["Name"]

        extended_data = YAML.load(open("#{folder}/#{name}.pid").read) if File.file? "#{folder}/#{name}.pid"

        ret = self.new name

        ret.game = data["Game"] if VALID_GAMES.member? data["Game"]
        ret.base_path = File.expand_path data["Path"]
        ret.path = ret.base_path
        ret.addons = data["Addons"]
        ret.gamemodes = data["Gamemodes"]
        ret.steampipe = data["Steampipe"]
        ret.path = ret.base_path + "/orangebox" if ret.game == "garrysmod" and not ret.steampipe
        ret.base_arguments = [ "-game #{ret.game}" ]
        ret.base_arguments << "-authkey #{RS.config[:Workshop]}" if RS.config.member? :Workshop
        ret.arguments = data["Arguments"].split ' ' if data["Arguments"].is_a? String
        ret.arguments = data["Arguments"] if data["Arguments"].is_a? Array

        if extended_data == nil
            ret.running = false
        else
            puts "Server #{name} seems to be online" if RS.options.verbose
            ret.pid = extended_data[:PID]
            ret.status = extended_data[:Status]
            ret.running = true
        end

        unless ret.to_b
            puts "#{name} missing data 'Game' and/or 'Path', might not be useable." if RS.options.verbose
            #return nil
        end

        ret.load_inf

        return ret
    end 

    def initialize(name)
        @name = name
        @update_check = Time.at 0
    end

    def +(other)
        @update_check = other.update_check
        @update = other.update if other.respond_to? :update
    end

    def cleanup!
        rm = Proc.new {|var| remove_instance_variable(var) if instance_variable_defined? var }

        rm.call :@arguments
        rm.call :@addons
        rm.call :@game
        rm.call :@path
        rm.call :@base_path
        rm.call :@gamemodes
        rm.call :@base_arguments
        rm.call :@running
        rm.call :@pid
        rm.call :@appid
        rm.call :@version
        rm.call :@steampipe
    end

    def to_b()
        puts "#{@game}, #{@path}, #{File.directory? @path}" if RS.options.verbose
        return true if @pid
        return false unless @game and @path and File.directory? @path
        return true
    end

    def status()
        #return @status if @status and not @status.empty?
        return "invalid" unless to_b
        return "stopped" unless @pid
        return "running"
    end

    def upgrade()
        return false unless to_b
        if not RS.options.force and check_update == nil then
            puts "Unable to check for updates for this server, run with -f/--force to update anyhow."
            return false
        end

        return true if @update.member? :up_to_date and @update[:up_to_date] and not RS.options.force

        puts "Starting update of #{@name}" if RS.options.verbose

        #runner_command = "#{APP_PATH}/runner.rb -p '#{File.expand_path RS.config[:SteamPath]}' -n #{@name}-update --no-autostart"
        if @steampipe then
            update_command = "#{File.expand_path RS.config[:SteamPath]}/steamcmd.sh +login anonymous +force_install_dir #{@base_path} +app_update #{@appid} validate +quit"
        else
            update_command = "#{File.expand_path RS.config[:HLDSPath]}/steam -command update -game #{@game} -dir #{@base_path}"
        end
        command_string = update_command

        system(command_string) unless RS.options.pretend
        puts(command_string) if RS.options.pretend or RS.options.verbose

        return $?.exitstatus == 0 unless RS.options.pretend
        return true
    end

    def rescue
        dir = Dir.getwd
        Dir.chdir @path

        links = `find . -type l -xtype l`
        link_issues = links.split("\n").map {|v| v.sub('./','').chomp} unless links.empty?

        scanned = []
        caseIter = Proc.new do |folder|
            problems = []

            unless File.basename(folder)[0,1] == '.'
                scanned << folder
                
                relative = File.join(@path,"")

                Dir.entries(folder).each do |entry|
                    next if entry[0] == '.'
                    absolute = File.join(folder, entry)
                    absoluteLower = File.join(folder, entry.downcase)

                    problems << [absolute.sub(relative,""), absoluteLower.sub(relative,"")] unless entry.downcase == entry or File.exists? absoluteLower
                    problems += caseIter.call(absolute) if File.directory? absolute and not scanned.member? File.expand_path absolute
                end unless File.symlink? folder
            end

            problems
        end

        case_issues = caseIter.call(File.join(@path, @game))

        Dir.chdir dir

        link_issues.each do |issue|
            puts "Link: #{File.join(@path, issue)}" if RS.options.verbose

            File.unlink(File.join(@path, issue)) unless RS.options.pretend
        end if link_issues

        case_issues.each do |issue|
            puts "Linking #{File.join(@path, issue[1])} to #{File.join(@path, issue[0])}" if RS.options.verbose

            File.symlink(File.join(@path, issue[0]), File.join(@path, issue[1])) unless RS.options.pretend or File.exists? File.join(@path, issue[1])
        end if case_issues
    end

    def link_content()
        return false unless to_b and RS.config.member? :ContentPath

        mods  = @addons ? @addons.map {|i| i.to_s.downcase } : Hash.new
        modes = @gamemodes ? @gamemodes.map {|i| i.to_s.downcase } : Hash.new

        Dir.foreach "#{@path}/garrysmod/addons/" do |addon|
            path = "#{@path}/garrysmod/addons/#{addon}"
            next unless File.symlink? path
            File.delete path unless mods.member? addon.to_sym
        end
        Dir.foreach "#{@path}/garrysmod/gamemodes/" do |mode|
            path = "#{@path}/garrysmod/gamemodes/#{mode}"
            next unless File.symlink? path
            File.delete path unless modes.member? addon.to_sym
        end

        RS.content.scan :QUICK do |mod|
            if mods.member? mod.clean_name then
                File.symlink("#{mod.path}", "#{@path}/garrysmod/addons/#{mod.clean_name}") unless File.symlink? "#{@path}/garrysmod/addons/#{mod.clean_name}"
            elsif modes.member? mod.clean_name then
                File.symlink("#{mod.path}", "#{@path}/garrysmod/gamemodes/#{mod.clean_name}") unless File.symlink? "#{@path}/garrysmod/gamemodes/#{mod.clean_name}"
            end
        end
    end

    def start()
        return if @running
        screen_command = "screen -dmS #{@name}"
        runner_command = "#{APP_PATH}/runner.rb -p '#{@path}' -n #{@name} -l --pid"
        server_command = "./srcds_run -norestart"
        server_arguments = @base_arguments.join(' ') + " " + @arguments.join(' ')

        command_string = [screen_command, runner_command, server_command, server_arguments]

        puts "Starting #{@name}..."
        system(command_string.join ' ') unless RS.options.pretend
        puts(command_string.join ' ') if RS.options.pretend or RS.options.verbose

        @running = true
    end

    def stop()
        return unless @running

        screenpid = `screen -list | grep #{@name} | cut -f1 -d'.' | sed 's/\W//g'`.strip.to_i

        #puts "PID:", screenpid.inspect
        #puts "Sending Ctrl+C"
        #

        #command = "screen"
        #arguments = "-S #{@name} -p 0 -X 'stuff \\015quit\\015'"

        puts "Stopping #{@name}..."
        #system(command + " " + arguments) unless RS.options.pretend
        #print(command, " ", arguments, "\n") if RS.options.pretend or RS.options.verbose

        Process.kill("INT", screenpid)

        @running = false
    end

    def load_inf()
        return @version if @appid
        return false unless to_b

        puts "Loading ini-file #{@path}/#{@game}/steam.inf" if RS.options.verbose
        steaminf = IniFile.load("#{@path}/#{@game}/steam.inf", :default => 'global')
        puts steaminf.inspect if RS.options.verbose

        return false unless steaminf

        @appid   = steaminf['global']['appID']
        @version = steaminf['global']['PatchVersion']
    end

    def check_update()
        return @update[:up_to_date] unless RS.options.force or Time.now - @update_check > UPDATE_INTERVAL
        return nil unless to_b
        load_inf unless @appid

        puts "Checking version online" if RS.options.verbose
        info = JSON.parse(open("https://api.steampowered.com/ISteamApps/UpToDateCheck/v0001?appid=#{@appid}&version=#{@version}").read, :symbolize_names=>true) unless RS.options.pretend
        info = {:response=>{:success=>true,:up_to_date=>true,:version_is_listable=>true}} if RS.options.pretend
        puts "Pretending that it went well" if RS.options.pretend

        @update_check = Time.now

        @update = info[:response]
        puts @update.inspect if RS.options.verbose

        return nil unless @update[:success]
        return @update[:up_to_date]
    end

end