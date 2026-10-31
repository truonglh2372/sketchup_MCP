require "minitest/autorun"
require_relative "../bridge/sketchup_mcp_bridge/dispatcher"

# The dispatcher only routes; the SketchUp-touching work lives in Handlers and
# is checked live. Routing must expose exactly the bridge methods the MCP side
# calls, and nothing else (no send-anything-to-Handlers).
class DispatcherTest < Minitest::Test
  class FakeHandlers
    attr_reader :calls

    def initialize
      @calls = []
    end

    SketchupMcpBridge::Dispatcher::METHODS.each do |m|
      define_method(m) { |params| @calls << [m, params]; "did #{m}" }
    end

    def secret(_params)
      "leaked"
    end
  end

  def setup
    @h = FakeHandlers.new
    @d = SketchupMcpBridge::Dispatcher.new(@h)
  end

  def test_routes_known_methods
    assert_equal "did eval_ruby", @d.call("eval_ruby", { "code" => "1" })
    assert_equal [["eval_ruby", { "code" => "1" }]], @h.calls
  end

  def test_exposes_every_mcp_method
    %w[ping eval_ruby get_selection list_entities dump_entity screenshot undo].each do |m|
      assert_includes SketchupMcpBridge::Dispatcher::METHODS, m
    end
  end

  def test_unknown_method_raises_without_calling_handlers
    err = assert_raises(ArgumentError) { @d.call("secret", {}) }
    assert_match(/Unknown method/, err.message)
    assert_empty @h.calls
  end
end
