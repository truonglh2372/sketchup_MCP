require "minitest/autorun"
require "json"
require "socket"
require "tmpdir"
require_relative "../bridge/sketchup_mcp_bridge/session"

class SessionTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @cfg = File.join(@dir, "sub", "bridge.json")
    @dispatch = ->(m, _p) { m == "boom" ? raise("x") : "r:#{m}" }
  end

  def teardown
    @session&.stop
    FileUtils.remove_entry(@dir)
  end

  def new_session(port: 0, ports: 1)
    @session = SketchupMcpBridge::Session.new(config_path: @cfg, dispatcher: @dispatch, port: port,
                                              port_attempts: ports, info: { "sketchup" => "test" })
  end

  def test_start_writes_config_with_port_and_random_token
    s = new_session.start
    cfg = JSON.parse(File.read(@cfg))
    assert_equal s.port, cfg["port"]
    assert_equal Process.pid, cfg["pid"]
    assert_equal "test", cfg["sketchup"]
    assert_match(/\A\h{32}\z/, cfg["token"])
  end

  def test_tokens_differ_between_sessions
    a = new_session.start
    t1 = JSON.parse(File.read(@cfg))["token"]
    a.stop
    new_session.start
    refute_equal t1, JSON.parse(File.read(@cfg))["token"]
  end

  def test_stop_removes_config
    new_session.start
    @session.stop
    refute File.exist?(@cfg)
  end

  def test_stop_keeps_config_owned_by_another_process
    new_session.start
    other = JSON.parse(File.read(@cfg)).merge("pid" => Process.pid + 1)
    File.write(@cfg, JSON.generate(other))
    @session.stop
    assert File.exist?(@cfg), "must not delete another SketchUp's bridge file"
  end

  def test_busy_port_falls_back_to_next
    blocker = TCPServer.new("127.0.0.1", 0)
    busy = blocker.addr[1]
    s = new_session(port: busy, ports: 5).start
    refute_equal busy, s.port
    assert_operator s.port, :>, busy
  ensure
    blocker&.close
  end

  def test_tick_serves_requests_with_written_token
    s = new_session.start
    cfg = JSON.parse(File.read(@cfg))
    sock = TCPSocket.new("127.0.0.1", s.port)
    sock.write(JSON.generate("token" => cfg["token"], "id" => 1, "method" => "ping") + "\n")
    line = nil
    100.times do
      s.tick
      line = (sock.read_nonblock(4096) rescue nil)
      break if line
      sleep 0.005
    end
    assert_equal "r:ping", JSON.parse(line)["result"]
  ensure
    sock&.close
  end

  def test_running_flag
    s = new_session
    refute s.running?
    s.start
    assert s.running?
    s.stop
    refute s.running?
  end
end
