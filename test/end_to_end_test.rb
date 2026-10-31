require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require_relative "../bridge/sketchup_mcp_bridge/session"
require_relative "../bridge/sketchup_mcp_bridge/dispatcher"

# Real MCP process on stdio -> real TCP -> real Session/Server/Dispatcher.
# Only Handlers is faked (it needs the SketchUp API).
class EndToEndTest < Minitest::Test
  SERVER = File.expand_path("../mcp/server.rb", __dir__)

  class FakeHandlers
    SketchupMcpBridge::Dispatcher::METHODS.each do |m|
      define_method(m) { |params| { "handled" => m, "params" => params } }
    end

    def eval_ruby(params)
      raise NameError, "undefined local variable `nope'" if params["code"] == "nope"

      { "result" => params["code"].length.to_s, "stdout" => "" }
    end
  end

  def setup
    @home = Dir.mktmpdir
    @session = SketchupMcpBridge::Session.new(
      dispatcher: SketchupMcpBridge::Dispatcher.new(FakeHandlers.new),
      config_path: File.join(@home, "bridge.json"), port: 0
    ).start
    @stdin, @stdout, @wait = Open3.popen2({ "SKETCHUP_MCP_HOME" => @home }, "ruby", SERVER)
  end

  def teardown
    @stdin.close unless @stdin.closed?
    @wait.join(5)
    @session.stop
    FileUtils.remove_entry(@home)
  end

  # Ticks the bridge (as the SketchUp dialog would) until the MCP reply arrives.
  def rpc(id, method, params = {})
    @stdin.write(JSON.generate("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params) + "\n")
    @stdin.flush
    500.times do
      @session.tick
      ready = IO.select([@stdout], nil, nil, 0.01)
      return JSON.parse(@stdout.gets) if ready
    end
    flunk "no reply for #{method}"
  end

  def test_full_round_trip
    init = rpc(1, "initialize", "protocolVersion" => "2025-06-18", "capabilities" => {})
    assert_equal "sketchup", init["result"]["serverInfo"]["name"]

    status = rpc(2, "tools/call", "name" => "sketchup_status", "arguments" => {})
    refute status["result"]["isError"]
    assert_equal "ping", JSON.parse(status["result"]["content"][0]["text"])["handled"]

    ev = rpc(3, "tools/call", "name" => "eval_ruby", "arguments" => { "code" => "12345" })
    assert_equal "5", JSON.parse(ev["result"]["content"][0]["text"])["result"]
  end

  def test_ruby_error_reaches_claude_as_tool_error
    r = rpc(1, "tools/call", "name" => "eval_ruby", "arguments" => { "code" => "nope" })
    assert r["result"]["isError"]
    assert_match(/NameError/, r["result"]["content"][0]["text"])
  end

  def test_bridge_stopped_gives_actionable_message
    @session.stop
    r = rpc(1, "tools/call", "name" => "get_selection", "arguments" => {})
    assert r["result"]["isError"]
    assert_match(/MCP Bridge/, r["result"]["content"][0]["text"])
  end
end
