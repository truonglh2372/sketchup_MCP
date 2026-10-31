require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require_relative "../mcp/server"

class McpServerTest < Minitest::Test
  # Records calls and returns canned results instead of talking to SketchUp.
  class FakeBridge
    attr_reader :calls
    attr_accessor :result, :error

    def initialize
      @calls = []
      @result = { "ok" => 1 }
    end

    def call(method, params, timeout: nil)
      @calls << [method, params, timeout]
      raise SketchupMcp::BridgeError, @error if @error
      @result
    end
  end

  def setup
    @bridge = FakeBridge.new
    @srv = SketchupMcp::Server.new(bridge: @bridge)
  end

  def rpc(method, params = nil, id = 1)
    msg = { "jsonrpc" => "2.0", "id" => id, "method" => method }
    msg["params"] = params if params
    @srv.handle(msg)
  end

  def test_initialize_echoes_protocol_and_advertises_tools
    r = rpc("initialize", { "protocolVersion" => "2025-06-18", "capabilities" => {} })
    assert_equal "2.0", r["jsonrpc"]
    assert_equal 1, r["id"]
    assert_equal "2025-06-18", r["result"]["protocolVersion"]
    assert r["result"]["capabilities"].key?("tools")
    assert_equal "sketchup", r["result"]["serverInfo"]["name"]
  end

  def test_notifications_get_no_reply
    assert_nil @srv.handle("jsonrpc" => "2.0", "method" => "notifications/initialized")
  end

  def test_unknown_method_is_jsonrpc_error
    r = rpc("nope/nope")
    assert_equal(-32_601, r["error"]["code"])
  end

  def test_ping
    assert_equal({}, rpc("ping")["result"])
  end

  def test_tools_list_has_schemas
    tools = rpc("tools/list")["result"]["tools"]
    names = tools.map { |t| t["name"] }
    %w[sketchup_status eval_ruby get_selection list_entities dump_entity screenshot undo].each do |n|
      assert_includes names, n
    end
    tools.each do |t|
      assert_equal "object", t["inputSchema"]["type"], t["name"]
      refute_empty t["description"].to_s, t["name"]
    end
    eval_tool = tools.find { |t| t["name"] == "eval_ruby" }
    assert_equal ["code"], eval_tool["inputSchema"]["required"]
  end

  def test_tool_call_forwards_to_bridge_as_json_text
    @bridge.result = { "result" => "3", "stdout" => "" }
    r = rpc("tools/call", { "name" => "eval_ruby", "arguments" => { "code" => "1+2" } })
    assert_equal "eval_ruby", @bridge.calls[0][0]
    assert_equal({ "code" => "1+2" }, @bridge.calls[0][1])
    content = r["result"]["content"]
    assert_equal "text", content[0]["type"]
    assert_equal({ "result" => "3", "stdout" => "" }, JSON.parse(content[0]["text"]))
    refute r["result"]["isError"]
  end

  def test_status_maps_to_bridge_ping
    rpc("tools/call", { "name" => "sketchup_status", "arguments" => {} })
    assert_equal "ping", @bridge.calls[0][0]
  end

  def test_eval_uses_long_timeout
    rpc("tools/call", { "name" => "eval_ruby", "arguments" => { "code" => "1", "timeout_s" => 30 } })
    assert_equal 30, @bridge.calls[0][2]
  end

  def test_bridge_error_is_tool_error_not_protocol_error
    @bridge.error = "SketchUp chưa mở cửa sổ MCP Bridge"
    r = rpc("tools/call", { "name" => "get_selection", "arguments" => {} })
    assert r["result"]["isError"]
    assert_match(/MCP Bridge/, r["result"]["content"][0]["text"])
  end

  def test_unknown_tool_is_tool_error
    r = rpc("tools/call", { "name" => "fly", "arguments" => {} })
    assert r["result"]["isError"]
    assert_empty @bridge.calls
  end

  def test_screenshot_returns_image_content
    Dir.mktmpdir do |dir|
      png = File.join(dir, "shot.png")
      File.binwrite(png, "\x89PNG fake".b)
      @bridge.result = { "path" => png, "width" => 800, "height" => 600 }
      r = rpc("tools/call", { "name" => "screenshot", "arguments" => { "width" => 800 } })
      img = r["result"]["content"].find { |c| c["type"] == "image" }
      assert_equal "image/png", img["mimeType"]
      assert_equal "\x89PNG fake".b, img["data"].unpack1("m0")
      refute File.exist?(png), "temp screenshot should be deleted after reading"
    end
  end

  def test_run_loop_reads_lines_and_writes_replies
    input = StringIO.new([
      JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "ping"),
      JSON.generate("jsonrpc" => "2.0", "method" => "notifications/initialized"),
      "garbage",
      JSON.generate("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list")
    ].join("\n") + "\n")
    output = StringIO.new
    @srv.run(input, output)
    replies = output.string.lines.map { |l| JSON.parse(l) }
    assert_equal [1, nil, 2], replies.map { |x| x["id"] }
    assert_equal(-32_700, replies[1]["error"]["code"])
  end
end

class BridgeClientTest < Minitest::Test
  def test_missing_config_explains_how_to_start_bridge
    client = SketchupMcp::BridgeClient.new(config_path: File.join(Dir.tmpdir, "nope_#{rand(1e9)}.json"))
    err = assert_raises(SketchupMcp::BridgeError) { client.call("ping", {}) }
    assert_match(/MCP Bridge/, err.message)
  end

  def test_round_trip_against_real_socket
    require "socket"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    th = Thread.new do
      c = server.accept
      req = JSON.parse(c.gets)
      c.write(JSON.generate("id" => req["id"], "ok" => req["token"] == "tk", "result" => req["method"]) + "\n")
      c.close
    end
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "bridge.json")
      File.write(cfg, JSON.generate("port" => port, "token" => "tk"))
      assert_equal "ping", SketchupMcp::BridgeClient.new(config_path: cfg).call("ping", {})
    end
  ensure
    th&.join(2)
    server&.close
  end

  def test_error_response_raises_bridge_error_with_message
    require "socket"
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    th = Thread.new do
      c = server.accept
      req = JSON.parse(c.gets)
      c.write(JSON.generate("id" => req["id"], "ok" => false,
                            "error" => { "message" => "NameError: x", "stdout" => "p\n", "backtrace" => ["(eval):1"] }) + "\n")
      c.close
    end
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "bridge.json")
      File.write(cfg, JSON.generate("port" => port, "token" => "tk"))
      err = assert_raises(SketchupMcp::BridgeError) { SketchupMcp::BridgeClient.new(config_path: cfg).call("eval_ruby", {}) }
      assert_match(/NameError: x/, err.message)
      assert_match(/\(eval\):1/, err.message)
      assert_match(/p/, err.message)
    end
  ensure
    th&.join(2)
    server&.close
  end
end
