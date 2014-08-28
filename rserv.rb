#!/usr/bin/env ruby

RSERV_VERSION = 1.338
UPDATE_INTERVAL = 60*60 #Seconds

require 'pathname'
APP_PATH = File.dirname(Pathname.new(__FILE__).realpath)
$:.push APP_PATH

require 'server.rb'
require 'content.rb'
require "optparse"
require 'rubygems'

gem 'json'
gem 'levenshtein'
require 'json'
require 'levenshtein'
require 'rubygems/package'
require 'zlib'

Struct.new("Options", :config, :pretend, :verbose, :force, :assume)

HOME_DIR = File.expand_path '~'
DEFAULT_CONFIG = "#{HOME_DIR}/.local/share/rserv/config"
VALID_COMMANDS = {
    :status=>[],
    :update=>[],
    :server=>[
        :list,
        :restart,
        :screen,
        :start,
        :status,
        :stop,
        :update,
        :zap
    ],
    :content=> [
        :list,
        :rescue,
        :status,
        :update
    ]
}

class Servers
    attr_reader :servers

    def initialize(path)
        @servers = {}
        Dir.entries(path).each do |serv|
            server = Server.parse(YAML::load_file(File.join(path, serv))) if File.extname(serv) == '.serv'
            next unless server

            @servers[server.name] = server
        end
    end

    def cleanup!
        @servers.each do |name, serv|
            serv.cleanup!
        end
    end

    def +(other)
        @servers.map do |name, server|
            server + other[name] if other.member? name

            [name, server]
        end
    end

    def [](other)
        @servers[other]
    end

    def member?(m)
        @servers.member? m
    end

    def each(&block)
        @servers.each do |k,v|
            block.call k,v
        end
    end

    def empty?
        @servers.empty?
    end
end

class RServ

    attr_accessor :options, :command, :subcommand, :arguments
    attr_reader :config, :content, :servers
    attr_writer :opt_parser

    def self.parse(args)
        options = Struct::Options.new(DEFAULT_CONFIG, false, false, false, true)

        opt_parser = OptionParser.new do |opt|
            opt.banner = "Ruby Server v#{RSERV_VERSION}\n\nUsage:\n#{$0} COMMAND [SUBCOMMAND] [OPTIONS]"
            opt.separator ""
            opt.separator "Commands:"
            opt.separator "  status - Checks and reports basic status of all servers and content"
            opt.separator "  update - Updates RServ to a later version"
            opt.separator ""
            opt.separator "  server SUBCOMMAND"
            opt.separator "   *list                - Lists all of the servers"
            opt.separator "    restart server ...  - Restarts the server/servers"
            opt.separator "    screen server       - Connects to the screen session of server"
            opt.separator "    start server ...    - Starts the server/servers"
            opt.separator "    status [server ...] - Checks the status of the server/servers"
            opt.separator "    stop server ...     - Stops the server/servers"
            opt.separator "    update [server ...] - Updates the server/servers"
            opt.separator "    zap server ...      - Zaps the specified server/servers, killing it instantly"
            opt.separator ""
            opt.separator "  content SUBCOMMAND"
            opt.separator "   *list            - Lists all of the content sources"
            opt.separator "    rescue source   - Fixes inconsistencies in the source"
            opt.separator "    status [source] - Checks the status of the content in the source"
            opt.separator "    update [source] - Updates the content in the source"
            opt.separator ""
            opt.separator "  * - Default subcommand"
            opt.separator ""
            opt.separator "Options:"

            opt.on("-c", "--config [FILE]", "Load configuration from FILE, default #{DEFAULT_CONFIG}") do |file|
                options.config = file
            end

            opt.on("-f", "--force", "Force the command to rerun, even if there is already cached data") do |force|
                options.force = force
            end

            opt.on("-a", "--[no-]assume", "Should #{$0} assume the closest match to a given name when the exact name can't be found?") do |assume|
                options.assume = assume
            end

            opt.on("-p", "--pretend", "Only print what would be done, don't execute any commands") do
                options.pretend = true
            end

            opt.on("-h", "--help", "Print this text") do
                puts opt
                exit 0
            end

            opt.on("-v", "--verbose", "Run verbosely") do |v|
                options.verbose = v
            end
        end

        opt_parser.parse! args

        ret = self.new

        ret.opt_parser = opt_parser
        ret.options = options
        ret.command = args.shift.downcase.to_sym if not args.empty?
        ret.subcommand = args.shift.downcase.to_sym if not args.empty?
        ret.arguments = []
        until args.empty? do ret.arguments << args.shift end

        return ret
    end

    def initialize()
        @content = nil
        @servers = nil
        @options = nil
        @command = nil
        @subcommand = nil
    end

    def find_data(array, names)
        return [] if names.empty? or array.empty?

        ret = {}
        names = [names] unless names.is_a? Array
        names.each do |n|
            ret[n] = []
        end

        array.each do |n, data|
            names.each do |name|
                serv = [data, n, Levenshtein.distance(name.downcase, n.downcase)]

                ret[name] << serv
            end
        end

        return [] if ret.empty?

        final_ret = []

        names.each do |name|
            ret[name] = ret[name].sort_by{|v|v[2]}#.map{|v|[v[0],v[1],v[2]]}

            if @options.assume and ret[name][0][2] <= ret[name][0][1].length/1.5
                puts "Could not find '#{name}', assuming '#{ret[name][0][1]}'" unless ret[name][0][1] == name
                final_ret << ret[name][0][0]
            else
                puts "Could not find '#{name}', did you mean '#{ret[name][0][1]}'?" unless ret[name][0][1] == name
                final_ret << ret[name][0][0] if ret[name][0][1] == name
            end
        end

        final_ret
    end

    def load_config()
        Dir.mkdir File.expand_path("#{HOME_DIR}/.local/share/rserv") if not File.directory? File.expand_path("#{HOME_DIR}/.local/share/rserv")

        config = File.expand_path(@options.config)
        if not File.file? config and @options.config == DEFAULT_CONFIG then
            File.open(config, "w") do |file|
                file.write <<EOF
{
    "ServerPath": "~/Servers",
    "ContentPath": "~/Content",
    "SteamPath": "~/.steam",
    "HLDSPath": "~/HLDS",
    "Workshop": "<Workshop API Key goes here>",
    "Autoupdate": false
}
EOF
            end
        elsif not File.file? config then
            puts "Configuration file #{@options.config} does not exist."
            exit 1
        end

        @config = JSON.parse(open(config).read, :symbolize_names=>true)

        @content = Content.new File.expand_path @config[:ContentPath]
        @servers = Servers.new File.expand_path @config[:ServerPath]
    end

    def load_cache
        YAML.load_documents(open(File.expand_path "~/.local/share/rserv/cache.yaml")) do |doc|
            @content + doc if doc.is_a? Content
            @servers + doc if doc.is_a? Servers
        end
    end

    def execute()
        if not VALID_COMMANDS.member? @command or (not VALID_COMMANDS[@command].empty? and not VALID_COMMANDS[@command].member? @subcommand) then
            puts "Not a valid command: #{@command} #{@subcommand}" if @command != nil

            puts @opt_parser
            exit 1
        end

        puts "Executing #{@command} #{@subcommand}..." if @options.verbose
        args = []
        args << (@command.to_s + "_cmd").to_sym
        args << @subcommand unless @subcommand == nil
        args += @arguments unless @arguments.empty?
        send(*args)
    end

    def cleanup
        @content.cleanup!
        @servers.cleanup!
    end

    def status_cmd()
        server_cmd(:status)
        content_cmd(:status)
    end

    def update_cmd()
        puts "Updating RServ..."

        unless File.writable? File.join(APP_PATH, "rserv.rb")
            puts "You are not allowed to update RServ."
            exit 1
        end

        begin
            #latest_version = open("http://ace.haxalot.com/projects/rserv/version").read.to_f
            latest_version = open("http://dl.dropboxusercontent.com/s/un54u9ptzrse4o3/version").read.to_f
        rescue
            puts "Unable to check the latest version, are you connected to the internet?"
            exit 1
        end

        if latest_version == 0
            puts "Unable to check the latest version, 404 error might've occured."
            exit 1
        end

        unless latest_version > RSERV_VERSION
            puts "RServ is already the latest version."
            exit 0
        end

        open('/tmp/rserv.tar.gz', 'w') do |local_file|
            #open('http://ace.haxalot.com/projects/rserv/latest.tar.gz') do |remote_file|
            open("http://dl.dropboxusercontent.com/s/148jgo1leipqao2/latest.tar.gz") do |remote_file|
                local_file.write(remote_file.read)
            end
        end

        puts "Downloaded latest"

        Gem::Package::TarReader.new(Zlib::GzipReader.open('/tmp/rserv.tar.gz')).each do |entry|
            open(File.join(APP_PATH, entry.full_name), 'w') do |file|
                puts "Writing #{file.path}."
                file.write(entry.read)
            end
        end

        puts "RServ updated to #{latest_version}"
    end

    def server_cmd(command, *args)
        restrict = find_data(@servers, args)

        if command == :list then
            puts "Servers: "

            @servers.each do |name, server|
                puts "  #{name}"
            end
        elsif command == :restart then
            if restrict.empty?
                puts "You need to specify one or more servers when using 'server restart'."
                exit 1
            end

            @servers.each do |name, server|
                next unless restrict.member? server

                server.stop
                server.start
            end
        elsif command == :screen then
            unless restrict.size == 1
                puts "You need to specify a single server when using 'server screen'."
                exit 1
            end

            @servers.each do |name, server|
                next unless restrict.member? server

                system("screen -x #{server.name}")
            end
        elsif command == :stop then
            if restrict.empty?
                puts "You need to specify one or more servers when using 'server stop'."
                exit 1
            end

            @servers.each do |name, server|
                next unless restrict.member? server

                server.stop
            end
        elsif command == :status then
            puts " Servers ".center(42, '#')
            puts "#"
            puts "# Name:            Server:  Content:  Status:"
            puts "#"

            format = "# %-16.16s %-7.7s  %-7.7s   %-7.7s"

            messages = []

            @servers.each do |name, server|
                next unless restrict.empty? or restrict.member? server

                server.check_update

                puts format % [server.name, (server.status=="invalid") ? ("[!!]") : ((server.update[:up_to_date]) ? ("[OK]") : ("[UP]")), "[??]", server.status.capitalize]

                if server.update then
                    messages << "#{server.name} has a required update" if server.update[:required_version] and server.update[:required_version] != server.version
                end
                messages << "#{server.name} is invalid" if (server.status == "invalid")
                messages << "Can't check content state for #{server.name}"
            end

            puts "#"

            messages.each do |msg|
                puts "# !! #{msg} !!"
            end
            puts "#" unless messages.empty?
        elsif command == :start then
            if restrict.empty?
                puts "You need to specify one or more servers when using 'server start'."
                exit 1
            end

            found = false
            @servers.each do |name, server|
                next unless restrict.member? server

                found = true
                server.start
            end

            puts "No server named #{args[0]}." unless found
        elsif command == :update then
            @servers.each do |name, server|
                next unless restrict.empty? or restrict.member? server

                puts "Upgrading #{name}..."

                unless server.upgrade
                    puts "Failed!"
                else
                    puts "Done."
                end

                puts "Checking links..."

                server.rescue

                puts "Checking addons and gamemodes..."

                server.link_content

                puts "Finished updating #{name}."
            end
        elsif command == :zap then
            if args.empty?
                puts "You need to specify at least one server to zap."
                exit 1
            end

            puts "... Zapping server(s), with DEATH! ..."
        end
    end

    def content_cmd(command, *args)
        unless @config[:ContentPath]
            puts "Your config file seems to lack a ContentPath entry, please add one."
            return
        end

        content_data = []
        @content.scan :QUICK do |c|
            content_data << [c.nice_name, c]
        end
        restrict = find_data(content_data, args)

        if command == :list then
            puts "Available content:"

            @content.scan :QUICK do |mod|
                puts "* #{mod.nice_name}"
            end
        elsif command == :rescue then
            puts "... Rescuing content ..."

            @content.rescue(*restrict)
        elsif command == :status then
            puts " Content ".center(42, '#')
            puts "#"
            puts "# Name:            Update:  Status:"
            puts "#"

            messages = []

            @content.scan(:FULL, *restrict) do |mod|
                upd = mod.up_to_date
                statusbox = (upd==true ? ("[OK]") : (upd==false ? "[UP]" : "[#{upd[0]}]"))

                puts "# %-16.16s %-7.7s  %-7.7s" % [mod.nice_name, statusbox, mod.issues ? "[!!]" : "[OK]"]

                messages << "#{mod.nice_name} #{mod.up_to_date[1]}" if mod.up_to_date.is_a? Array
                messages << "#{mod.nice_name} has link issues" if mod.link_issues
                #messages += mod.link_issues if mod.link_issues
                messages << "#{mod.nice_name} has case issues" if mod.case_issues
                #messages += mod.case_issues if mod.case_issues
            end

            puts "#"
            messages.each do |msg|
                puts "# !! #{msg} !!"
            end
            puts "#" unless messages.empty?
        elsif command == :update then
            puts "... Updating content ..."
            @content.update(*restrict)
        end
    end

end

if __FILE__ == $PROGRAM_NAME

    RS = RServ.parse(ARGV)

    RS.load_config
    RS.load_cache if File.exists? File.expand_path "~/.local/share/RServ/cache.yaml"
    RS.execute
    RS.cleanup

    #puts RS.inspect

    test = YAML::dump_stream(RS.content, RS.servers)

    File.open(File.expand_path("~/.local/share/RServ/cache.yaml"), "w") do |file|
        file.write test
    end

    #puts RS.inspect if (RS.options.verbose)

end
