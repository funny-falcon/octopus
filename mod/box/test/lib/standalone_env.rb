require 'run_env'
require 'erb'

class StandAloneEnv < RunEnv
  ConfigFile = "octopus.cfg"
  PidFile = "octopus.pid"
  LogFile = "octopus.log"
  Binary = Root + "/../../octopus"
  Suppressions = Root + "../../scripts/valgrind.supp"

  def initialize
    super
    @config_template = File.read(Root + "/test/basic.cfg")
    @primary_port = 33013
  end

  def connect_string
    "0:#@primary_port"
  end

  def config
    body = ERB.new(@config_template).result(binding)
    if not $options[:valgrind] then
      body += %Q{logger = "exec cat - >> octopus.log"\n}
    end
    body
  end

  task :config => [ConfigFile]
  file ConfigFile => [:test_root] do
    cd_test_root do
      io = File.open(ConfigFile, "w+")
      io.write(config)
      io.close
    end
  end

  task :test_root do
    cd Root do
      mkdir test_root
    end
  end

  task :clean do
    cd Root do
      rm_rf test_root
    end
  end

  task :setup => [:test_root, :config] do
    cd_test_root do
      ln_s Binary, "octopus"
      ln_s Root + "/../../.gdbinit", ".gdbinit"
      ln_s Root + "/../../.gdb_history", ".gdb_history"

      waitpid(octopus ['--init-storage'], :out => "/dev/null", :err => "/dev/null")
    end
  end

  def test_root
    @test_dir + "/var"
  end

  def gdb_if_core
    if FileTest.readable?("core")
      STDERR.puts "\nLast 20 lines from log\n-------\n"
      system *%w[tail -n20 octopus.log]
      STDERR.puts "\n-------\n"
      STDERR.puts "\n\nCore found. starting gdb."
      exec *%w[gdb --quiet octopus core]
    end
  end

  def octopus(args, param = {})
    invoke :config
    pid = fork
    if pid
      return pid
    else
      Process.setpgid($$, 0)
      argv = ['./octopus', '-c', ConfigFile, *args]
      if $options[:valgrind]
        argv.unshift('valgrind', '-q',
                     "--suppressions=#{Root + '/scripts/valgrind.supp'}",
                     "--suppressions=#{Root + '/third_party/luajit/src/lj.supp'}")
      end
      exec *argv, param
    end
  end

  def start
    invoke :start
    i = 0
    while true do
      if readable? "#{LogFile}.#{i}" then
        i += 1
        next
      end
      mv LogFile, "#{LogFile}.#{i}" if readable? LogFile
      break
    end

    @pid = octopus [], :out => "/dev/null"

    50.times do
      delay
      next unless readable? LogFile
      return if File.read(LogFile).match(/entering event loop/)
    end
    @pid = nil

    gdb_if_core
    raise "Unable to start server"
  end

  def stop
    invoke :stop
    return unless @pid
    if not waitpid @pid, WNOHANG then
      kill("INT", @pid)
      20.times do
        break unless readable? PidFile
        delay
      end

      if readable? PidFile
        STDERR.puts "killing hang server"
        kill("KILL", @pid)
      end

      waitpid @pid
    else
      STDERR.puts "server prematurely exit"
    end

    @pid = nil
    gdb_if_core
    if $?.signaled? and $?.termsig != Signal.list['INT'] then
      raise "#{File.basename Binary} exited on uncaught signal #{$?.termsig}"
    end
  end

  alias :start_server :start
  alias :stop_server :stop
end
