#!/usr/bin/ruby1.9.1

$:.push 'test/lib'
require 'standalone_env'

class MasterEnv < StandAloneEnv
  def test_root
    super + "_master"
  end

  def config
    super + <<EOD
wal_feeder_bind_addr = ":33034"
#{$io_compat}
object_space[0].enabled = 1
object_space[0].index[0].type = "HASH"
object_space[0].index[0].unique = 1
object_space[0].index[0].key_field[0].fieldno = 0
object_space[0].index[0].key_field[0].type = "STR"

object_space[1].enabled = 1
object_space[1].index[0].type = "HASH"
object_space[1].index[0].unique = 1
object_space[1].index[0].key_field[0].fieldno = 0
object_space[1].index[0].key_field[0].type = "STR"
EOD
  end

  task :setup => ["feeder_init.lua"]
  file "feeder_init.lua" do
    f = open("feeder_init.lua", "w")
    f.write <<-EOD
local ffi = require('ffi')
local box_old_nop = "\1\0\0\0\0\0"
local box_nop = "\0\0\0\0"
ffi.cdef 'void *malloc(int)'
local buf = ffi.C.malloc(1024)
function replication_filter.id_xlog(row)
    print(row)

    if row.scn == 3296 or row.scn == 3297 or row.scn == 3298 then
	local new = ffi.new('struct row_v12 *', buf)
	ffi.copy(new, row, ffi.sizeof('struct row_v12'))
	if row.tag == 0x8003 then
            new.len = #box_old_nop
            ffi.copy(new.data, box_old_nop, #box_old_nop)
        else
            new.tag = 0x8033 -- NOP|TAG_WAL
	    new.len = #box_nop
	    ffi.copy(new.data, box_nop, #box_nop)
        end
	return new
    end
    return true
end
    EOD
    f.close
  end
end

class SlaveEnv < StandAloneEnv
  def initialize
    super
    @primary_port = 33023
  end

  def test_root
    super + "_slave"
  end

  def config
    super + <<EOD
wal_feeder_addr = "127.0.0.1:33034"
wal_feeder_filter = "id_xlog"
#{$io_compat}
object_space[0].enabled = 1
object_space[0].index[0].type = "HASH"
object_space[0].index[0].unique = 1
object_space[0].index[0].key_field[0].fieldno = 0
object_space[0].index[0].key_field[0].type = "NUM"

object_space[1].enabled = 1
object_space[1].index[0].type = "HASH"
object_space[1].index[0].unique = 1
object_space[1].index[0].key_field[0].fieldno = 0
object_space[1].index[0].key_field[0].type = "STR"
EOD
  end
end

def wait_for(n=100)
  n.times do
    return if yield
    sleep 0.05
  end
  raise "wait_for failed"
end

MasterEnv.clean do
  start
  master = connect
  master.ping

  100.times do |i|
    master.insert [i, i + 1, "abc", "def"]
    master.insert [i, i + 1, "abc", "def"]
    master.insert [i, i + 1, "abc", "def"], :object_space => 1
    if i == 50 then
      Process.kill('USR1', pid)
      wait_for { FileTest.readable?("00000000000000000154.snap") }
    end
  end

  SlaveEnv.clean do
    start
    slave = connect
    wait_for { FileTest.readable?("00000000000000000154.snap") }
    slave.select [99]
    slave.select [99], :object_space => 1

    Process.kill("STOP", pid)
    1000.times do |i|
      master.insert [i, i + 1, "ABC", "DEF"]
      master.insert [i, i + 1, "ABC", "DEF"]
      master.insert [i, i + 1, "ABC", "DEF"], :object_space => 1
    end
    Process.kill("CONT", pid)

    wait_for { slave.select_nolog([999]).length > 0 }
    slave.select [998]
    slave.select [999]
    slave.select [998], :object_space => 1
    slave.select [999], :object_space => 1

    # verify that replica is able to read it's own xlog's
    stop
    start

    slave = connect
    wait_for { slave.select_nolog([999]) }
    slave.select [998]
    slave.select [999]
    slave.select [998], :object_space => 1
    slave.select [999], :object_space => 1
  end
end

