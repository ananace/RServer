#!/usr/bin/env ruby

require 'optparse'
require 'yaml'
require 'pty'

Struct.new("ProgramInfo", :ProgramPID, :Status, :Data)

class ProgramHost
    attr_reader :exitstatus, :info
    attr_accessor :executable, :path, :name, :arguments

    def initialize
        @exitstatus = -1
        @info = Struct::ProgramInfo.new(-1, "Invalid", nil)

        @executable = nil
        @path = nil
        @name = nil
        @arguments = []
    end

    def start(inject = true)
        return false if isRunning

        @pid_file = File.expand_path "~/.local/share/rserv/#{@name.downcase}.pid"

        dir = Dir.getwd
        Dir.chdir @path

        if inject then
            pid = -1
            @PTYThread = Thread.new {
                PTY.spawn(@executable, *@arguments) do |read, write, ptypid|
                    begin
                        pid = ptypid
                        @readIO = read
                        @writeIO = write

                        read.each_line do |line|
                            temp = on_output(line)
                            line = temp if temp.is_a? String

                            puts line
                        end
                    rescue Errno::EIO
                    end
                end

                @info.ProgramPID = -1
                @readIO = nil
                @writeIO = nil
            }

            @info.ProgramPID = pid
        else
            if (RUBY_VERSION.to_f > 1.8) then
                pid = Process.Spawn(@executable, *@arguments)
            else
                pid = fork {
                    exec @executable, *@arguments
                }
            end

            @info.ProgramPID = pid
        end

        Dir.chdir dir
        @info.Status = "Running"
        @info.Data = { :Path => @path, :Executable => @executable, :Arguments => @arguments }

        write!
    end

    def write(data)
        if @PTYThread then
            @writeIO.write(data)
        else
            raise "Application launched without injection"
        end
    end

    def isRunning
        return false unless @info.ProgramPID > 0

        if @PTYThread then
            return PTY.check(@info.ProgramPID) == nil
        else
            begin
                Process.getpgid(@info.ProgramPID)
                true
            rescue Errno::ESRCH
                false
            end
        end
    end

    def stop
        if @PTYThread then
            @PTYThread.terminate
        else
            `screen -S #{@ScreenPID} -X quit`
        end
    end

    def wait
        if @PTYThread then
            @PTYThread.join
        else
            while isRunning do
                sleep 1
            end
        end
    end

    private

    def on_output(line)

    end

    def on_input(line)
        write(line + "\n")
    end

    def write!
        File.open(@pid_file, "w") do |file|
            YAML.dump(@info, file)
        end
    end
end

class UpdaterHost < ProgramHost

    def initialize(steam_path)
        super

        full_path = File.expand_path steam_path

        @executable = File.basename full_path
        @path = File.dirname full_path

        @status = :not_running
        @progress = 0
    end

    def progress?
        @progress
    end

    def status?
        @status.to_s.upcase
    end
    
end

class HLDSUpdateToolHost < UpdaterHost

    def initialize(steam_path, app_path, app_id, auth = nil)
        super steam_path

        @name = "HLDSUpdateTool"

        if auth then
            @arguments += [ "-username", auth[:username], "-password", auth[:password] ]
        end

        @arguments += [ "-command", "update", "-game", app_id, "-dir", app_path, "-verify_all" ]
    end

    def on_output(line)

    end

end

class SteamCMDHost < UpdaterHost

    def initialize(steam_path, app_path, app_id, auth = nil)
        super steam_path

        @name = "SteamCMD"

        if auth then
            @arguments += [ "+login", auth[:username], auth[:password] ]
        else
            @arguments += [ "+login", "anonymous" ]
        end 

        @arguments += [ "+force_install_dir", app_path, "+app_update", app_id, "validate", "+quit" ]
    end

    def on_output(line)
        
    end
    
end

class SRCDSHost < ProgramHost

end


Struct.new("Server", :path, :name, :autostart, :timeout, :debug, :log, :pid_file)

class ServerRunner

    attr_reader :clean_exit, :autostart, :pid_file, :pid, :info
    attr_reader :executable, :path, :name, :autostart, :timeout, :debug, :arguments

    def initialize
        options = Struct::Server.new(nil, nil, true, 10, false, nil, nil)

        OptionParser.new do |opt|
            opt.banner = "Usage:\n#{$PROGRAM_NAME} [OPTIONS] COMMAND [ARGUMENTS]"
            opt.separator ""
            opt.separator "Required arguments:"

            opt.on(:REQUIRED, '-p', '--path', '=PATH', 'The path the executable should run from') do |p|
                options.path = p
            end

            opt.on(:REQUIRED, '-n', '--name', '=NAME', 'The name of the running instance') do |name|
                options.name = name
            end

            opt.separator ""
            opt.separator "Optional arguments:"

            opt.on('--pid', '=[FILE]', 'Store the PID in a file.') do |pid|
                options.pid_file = "~/.local/share/RServ/#{options.name}.pid" if pid.is_a? TrueClass
                options.pid_file = pid if pid.is_a? String
            end

            opt.on('-l', '--log', '=[FILE]', 'Log when the application goes up or down') do |log|
                options.log = "~/.local/share/RServ/#{options.name}.log" if log.is_a? TrueClass
                options.log = log if log.is_a? String
            end

            opt.on('-a', '--[no-]autostart', 'Automatically restarts the process if it exits') do |a|
                options.autostart = a
            end

            opt.on('-t', '--timeout', '=TIMEOUT', Float, 'Sets the timeout (in seconds) to wait before restarting','defaults to 10 seconds.') do |t|
                options.timeout = t
            end

            opt.on('-d', '--[no-]debug', 'Will generate a debug.log using gdb upon crashing.') do |d|
                options.debug = d
            end

            opt.on_tail('-h', '--help', 'Prints this text and exits') do
                puts opt
                exit
            end
        end.order!

        if ARGV.empty? or not options.path then
            puts "You need to specify an executable." if ARGV.empty?
            puts "You need to specify a path." unless options.path
            puts "Run '#{$PROGRAM_NAME} --help' to get more information."
            exit
        end

        @executable = ARGV.shift
        @arguments = ARGV

        @info = {:PID=>0, :Status=>"invalid"}
        @path = File.expand_path options.path
        @name = options.name
        @autostart = options.autostart
        @timeout = options.timeout
        @debug = options.debug
        @log = File.expand_path options.log if options.log
        @pid_file = File.expand_path options.pid_file if options.pid_file
    end

    def prepare
        Dir.chdir(@path)
    end

    def start
        prepare

        if RUBY_VERSION.to_f > 1.8 then
            @pid = Process.spawn("#{@executable} #{@arguments.join ' ' if @arguments}")
        else
            @pid = fork { exec @executable, *@arguments }
        end

        @info[:pid] = @pid
        @info[:status] = "running"

        if @pid_file then
            File.open(@pid_file, "w") do |file|
                YAML.dump(@info, file)
            end
        end

        File.open(@log, "a") do |file|
            file.write "[#{Time.now}] #{@name} started as pid #{@pid}\n"
        end if @log

        begin
            Process.wait(@pid)

            @clean_exit = $?.exitstatus == 0

            @info[:pid] = 0
            @info[:status] = @clean_exit ? "stopped" : "crashed"

            if @pid_file then
                File.open(@pid_file, "w") do |file|
                    YAML.dump(@info, file)
                end
            end

            File.open(@log, "a") do |file|
                file.write "[#{Time.now}] #{@name} crashed!\n" unless @clean_exit
                file.write "[#{Time.now}] #{@name} exited cleanly.\n" if @clean_exit
            end if @log
        rescue Interrupt
            puts "[#{Time.now}] Ctrl-C received, killing #{@name}."

            if RUBY_VERSION.to_f > 1.8 then

            else
                Process.kill("INT", @pid)
            end

            File.open(@log, "a") do |file|
                file.write "[#{Time.now}] #{@name} killed with ctrl-c!\n"
            end if @log

            @clean_exit = true
        end
    end

    def dump_debug
        File.open("debug.cmds", "wt") do |file|
            file.write """bt
info locals
info registers
info sharedlibrary
disassemble
info frame"""
        end

        File.open("debug.log", "w") do |file|
            file.write """----------------------------------------------
CRASH: #{Time.now}
Start Line: #{@executable} #{@arguments.join ' '}"""
            file.flush

            possible_cores = ["core", "core.#{@pid}", "#{@executable}.core"]
            possible_cores.each do |core|
                if File.file? core then
                    system("gdb #{@executable} #{core} -x debug.cmds -batch >> debug.log")
                    break
                end
            end

            file.write """End of crash report
----------------------------------------------"""
        end

        File.delete "debug.cmds"
    end

    def cleanup
        @pid = nil
    end

    def remove_pid
        File.delete @pid_file if @pid_file and File.file? @pid_file
    end
end

if __FILE__ == $PROGRAM_NAME
    serv = ServerRunner.new

    if serv.pid_file and File.file? serv.pid_file then
        puts "[#{Time.now}] PID file exists, possible crash?"

        puts "[#{Time.now}] Please remove #{serv.pid_file} and try again"

        exit 1
    end

    begin
        puts "[#{Time.now}] Starting #{serv.name}."

        serv.start

        if serv.clean_exit then
            puts "[#{Time.now}] #{serv.name} stopped."
        else
            puts "[#{Time.now}] #{serv.name} crashed!"
            if serv.debug then
                puts "[#{Time.now}] Dumping debug data..."

                serv.dump_debug
                puts "[#{Time.now}] Debug log generated, do whatever with it."
            end
        end

        puts "[#{Time.now}] Cleaning up."

        serv.cleanup

        begin
            puts "[#{Time.now}] Restarting #{serv.name} in #{serv.timeout} seconds" if serv.autostart and not serv.clean_exit
            sleep(serv.timeout) if serv.autostart and not serv.clean_exit
        rescue Interrupt
            puts "[#{Time.now}] Caught ctrl-c, aborting timeout."
            break
        end
    rescue Exception => e
        puts "[#{Time.now}] Caught unhandled exception, exiting"
        puts e.inspect

        File.open(@log, "a") do |file|
            file.write "[#{Time.now}] Runner caught unhandled exception:\n"
            file.write e.inspect + "\n"
        end if @log

        raise
    end while serv.autostart and not serv.clean_exit

    serv.remove_pid

    puts "[#{Time.now}] Shutting down."
end