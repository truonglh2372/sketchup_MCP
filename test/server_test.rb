require "minitest/autorun"
require "json"
require "socket"
require_relative "../bridge/sketchup_mcp_bridge/server"

# The bridge server runs single-threaded: SketchUp calls #tick from the dialog's
# JS interval, so these tests drive it the same way — a real localhost socket,
# and tick in a loop until the response shows up.
class ServerTest < Minitest::Test
  TOKEN = "t0k"

  def setup
    @calls = []
    dispatcher = lambda do |method, params|
      @calls << [method, params]
      raise ArgumentError, "bad" if method == "explode"
      { "echo" => params }
    end
    @server = SketchupMcpBridge::Server.new(port: 0, token: TOKEN, dispatcher: dispatcher)
    @server.start
  end

  def teardown
    @server.stop
  end

  def request(sock, h)
    sock.write(JSON.generate(h) + "\n")
  end

  def read_response(sock)
    buf = +""
    200.times do
      @server.tick
      begin
        buf << sock.read_nonblock(65_536)
      rescue IO::WaitReadable
        nil
      end
      return JSON.parse(buf.lines.first) if buf.include?("\n")
      sleep 0.005
    end
    flunk "no response"
  end

  def test_listens_on_localhost_only_with_real_port
    assert_operator @server.port, :>, 0
    assert_equal "127.0.0.1", @server.host
  end

  def test_dispatches_request_and_replies
    sock = TCPSocket.new("127.0.0.1", @server.port)
    request(sock, token: TOKEN, id: 1, method: "ping", params: { "x" => 2 })
    resp = read_response(sock)
    assert_equal 1, resp["id"]
    assert resp["ok"]
    assert_equal({ "echo" => { "x" => 2 } }, resp["result"])
    assert_equal [["ping", { "x" => 2 }]], @calls
  ensure
    sock&.close
  end

  def test_handler_exception_becomes_error_response
    sock = TCPSocket.new("127.0.0.1", @server.port)
    request(sock, token: TOKEN, id: 9, method: "explode")
    resp = read_response(sock)
    refute resp["ok"]
    assert_equal "ArgumentError: bad", resp["error"]["message"]
  ensure
    sock&.close
  end

  def test_bad_token_never_reaches_dispatcher
    sock = TCPSocket.new("127.0.0.1", @server.port)
    request(sock, token: "wrong", id: 2, method: "ping")
    resp = read_response(sock)
    refute resp["ok"]
    assert_empty @calls
  ensure
    sock&.close
  end

  def test_request_split_across_packets
    sock = TCPSocket.new("127.0.0.1", @server.port)
    raw = JSON.generate(token: TOKEN, id: 3, method: "ping") + "\n"
    sock.write(raw[0, 10])
    3.times { @server.tick }
    sock.write(raw[10..-1])
    assert_equal 3, read_response(sock)["id"]
  ensure
    sock&.close
  end

  def test_two_requests_on_one_connection
    sock = TCPSocket.new("127.0.0.1", @server.port)
    request(sock, token: TOKEN, id: 1, method: "a")
    assert_equal 1, read_response(sock)["id"]
    request(sock, token: TOKEN, id: 2, method: "b")
    assert_equal 2, read_response(sock)["id"]
  ensure
    sock&.close
  end

  def test_tick_without_clients_is_harmless
    5.times { assert_equal 0, @server.tick }
  end

  def test_on_request_hook_sees_method_and_status
    seen = []
    @server.on_request = ->(method, ok, ms) { seen << [method, ok, ms.is_a?(Numeric)] }
    sock = TCPSocket.new("127.0.0.1", @server.port)
    request(sock, token: TOKEN, id: 1, method: "explode")
    read_response(sock)
    assert_equal [["explode", false, true]], seen
  ensure
    sock&.close
  end
end
