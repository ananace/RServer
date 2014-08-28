

Struct.new("Content", :clean_name, :nice_name, :path, :up_to_date, :issues, :link_issues, :case_issues, :timestamps)

def get_counts(keys)
     counts = Hash.new(0)
     keys.each {|k| counts[k] += 1 }
     counts
end

def non_uniq(elements)
     counts = get_counts(elements)
     counts.delete_if {|k, v| v < 2 }
     elements.select {|e| counts.key?(e) }
end

class Struct::Content
    def cleanup!
        
    end

    def +(other)
        return self unless other.is_a? Struct::Content
        self.up_to_date = other.up_to_date
        self.timestamps = other.timestamps
        self.issues = other.issues
        self.link_issues = other.link_issues
        self.case_issues = other.case_issues

        self
    end

    def downcase
        return @clean_name
    end

    def to_str
        return @nice_name
    end
end

class Content

    attr_reader :content, :path, :scan_level, :scan_time

    def initialize(data)
        if data.is_a? String then
            @path = File.expand_path data
            @content = {}
            @scan_level = :NONE
            @scan_time = Time.at 0
        end
    end

    def +(other)
        scan(:QUICK) do |entry|
            entry += other.content[entry.clean_name] if other.content.member? entry.clean_name

            entry
        end

        @scan_level = other.scan_level
        @scan_time = other.scan_time
    end

    def cleanup!
        rm = Proc.new {|var| remove_instance_variable(var) if instance_variable_defined? var }

        rm.call :@path
    end

    def thorough_scan(data)
        #puts "Thorough"
        dir = Dir.getwd
        Dir.chdir data.path

        do_update = true
        do_update = Time.now - data.timestamps[:update] > UPDATE_INTERVAL if data.timestamps.member? :update
        do_update = true if RS.options.force

        if do_update then
            #puts "Update check"
            data.up_to_date = true
            if File.directory? data.path + "/.svn" then
                local = `svn info | grep -i "Last Changed Rev"`
                remote = `svn info -r HEAD | grep -i "Last Changed Rev"`

                data.up_to_date = false if local != remote
            elsif File.directory? data.path + "/.git" then
                `git remote update 2>&1 > /dev/null`
                info = `git status -uno`

                data.up_to_date = false if info["Your branch is"]
            elsif File.directory? File.join(data.path, "/.hg") then
                data.up_to_date = ["HG", "uses mercurial, can't check status"]
            else
                data.up_to_date = ["??", "has no source control information"]
            end

            data.timestamps[:update] = Time.now
        else
            puts "Up to date, skipping" if RS.options.verbose
        end

        do_update = true
        do_update = Time.now - data.timestamps[:issues] > UPDATE_INTERVAL if data.timestamps.member? :issues
        do_update = true if RS.options.force

        if do_update then
            links = `find . -type l -xtype l`
            data.link_issues = links.split('\n').map {|v| v.sub('./','').chomp} unless links.empty?

            scanned = []

            caseIter = Proc.new do |folder|
                problems = []

                unless File.basename(folder)[0,1] == '.'
                    #puts folder
                    scanned << folder
                    #puts "Iter: #{folder}"
                    
                    relative = File.join(data.path,"")

                    Dir.entries(folder).each do |entry|
                        next if entry[0] == '.'
                        absolute = File.join(folder, entry)
                        absoluteLower = File.join(folder, entry.downcase)

                        problems << [absolute.sub(relative,""), absoluteLower.sub(relative,"")] unless entry.downcase == entry or File.exists? absoluteLower
                        problems += caseIter.call(absolute) if File.directory? absolute and not scanned.member? File.expand_path absolute
                    end
                end

                problems
            end

            caseProb = caseIter.call(File.expand_path('.'))
            data.case_issues = caseProb unless caseProb.empty?

            data.link_issues = nil if not data.link_issues.is_a? Array or data.link_issues.empty?
            data.case_issues = nil if not data.case_issues.is_a? Array or data.case_issues.empty?

            data.issues = false
            data.issues = true if data.link_issues
            data.issues = true if data.case_issues

            data.timestamps[:issues] = Time.now
        end

        Dir.chdir dir

        return data
    end

    def scan(level, *mods)
        levels = {:RESCAN=>3,:FULL=>2,:QUICK=>1,:NONE=>0}
        return unless levels.member? level
        puts "#{@scan_level} => #{level}" if RS.options.verbose

        level = :RESCAN if level == :FULL and (RS.options.force or Time.now - @scan_time > UPDATE_INTERVAL)
        if level == :NONE then
            @content.sort.each do |entry|
                temp = yield entry if block_given?
                entry = temp if temp.is_a? Struct::Content
            end

            return
        end

        rescan = levels[level] > levels[@scan_level]
        
        mods = mods.map do |mod|
            if mod.is_a? Symbol then
                mod.to_s.downcase.to_sym
            elsif mod.is_a? String then
                mod.downcase.to_sym
            elsif mod.is_a? Struct::Content then
                mod.clean_name.to_sym
            end
        end

        code = Proc.new { |entry|
            name = entry.downcase.to_sym if entry.is_a? String
            name = entry.clean_name.to_sym if entry.is_a? Struct::Content
            name = entry[1].clean_name.to_sym if entry.is_a? Array
            next unless mods.empty? or mods.member?(name)

            data = Struct::Content.new(entry.downcase, entry, @path+"/"+entry, ["??", "has not been checked"], false, false, false, {}) if entry.is_a? String
            data = entry if entry.is_a? Struct::Content
            data = entry[1] if entry.is_a? Array

            puts "  #{data.nice_name}." if RS.options.verbose
            STDOUT.flush

            data = thorough_scan(data) if levels[level] > 1 and rescan

            if block_given? then
                temp = yield data
                data = temp if temp.is_a? Struct::Content
            end

            @content[data.clean_name] = data
        }

        if rescan then
            entries = Dir.entries(@path).sort_by { |v| v.downcase } 
            entries.each do |entry|
                if not File.directory? @path+"/"+entry or entry == '.' or entry == '..'
                    next
                end

                code.call entry
            end
        else
            @content.sort.each do |entry|
                code.call entry
            end
        end

        @scan_level = level if levels[level] > levels[@scan_level]
        @scan_time = Time.now if levels[level] > levels[:QUICK]
        @scan_level = :FULL if level == :RESCAN
    end

    def update(*mods)
        scan(:QUICK, *mods) do |mod|
            puts mod.inspect if RS.options.verbose
            next unless mod.up_to_date == false or RS.options.force

            print "Updating #{mod.nice_name}..."
            STDOUT.flush

            dir = Dir.getwd
            Dir.chdir mod.path

            if File.directory? File.join(mod.path, ".svn") then
                print " (svn up)"
                STDOUT.flush
                info = `svn up`

                mod.up_to_date = true if $?.exitstatus == 0
            elsif File.directory? File.join(mod.path, "/.git") then
                print " (git pull)"
                STDOUT.flush
                git = `git rev-parse --abbrev-ref --symbolic-full-name @{u}`.chomp.split('/')
                info = `git pull #{git[0]} #{git[1]} 2>/dev/null`
                
                mod.up_to_date = true if $?.exitstatus == 0
            elsif File.directory? File.join(mod.path, "/.hg") then
                mod.up_to_date = ["HG", "can't check mercurial status"]
            else
                mod.up_to_date = ["??", "no source control information"]
            end

            puts " Done."   if mod.up_to_date.is_a? TrueClass
            puts " Failed!" if mod.up_to_date.is_a? FalseClass
            puts " Done?"   if mod.up_to_date.is_a? Array

            Dir.chdir dir

            mod
        end
    end

    def rescue(*mods)
        scan(:FULL, *mods) do |mod|
            next unless mod.issues

            print "Rescuing #{mod.nice_name}..."
            STDOUT.flush

            mod.link_issues.each do |issue|
                puts "Link: #{File.join(mod.path, issue)}"

                File.unlink(File.join(mod.path, issue)) unless RS.options.pretend
            end if mod.link_issues
            mod.link_issues = nil

            mod.case_issues.each do |issue|
                puts "Linking #{File.join(mod.path, issue[1])} to #{File.join(mod.path, issue[0])}" if RS.options.verbose

                File.symlink(File.join(mod.path, issue[0]), File.join(mod.path, issue[1])) unless RS.options.pretend
            end if mod.case_issues
            mod.case_issues = nil

            mod.issues = mod.link_issues or mod.case_issues

            puts " Done." unless mod.issues
            puts " Failed!" if mod.issues

            mod
        end
    end

    def each(&block)
        scan :QUICK do |v|
            block.call v
        end
    end

    def empty?
        Dir.entries(@path).empty?
    end

end