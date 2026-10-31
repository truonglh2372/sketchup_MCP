require "minitest/autorun"
require_relative "../bridge/sketchup_mcp_bridge/evaluator"

class EvaluatorTest < Minitest::Test
  def setup
    @wraps = []
    # Stands in for model.start_operation/commit/abort.
    wrap = lambda do |name, &blk|
      @wraps << name
      blk.call
    end
    @ev = SketchupMcpBridge::Evaluator.new(wrap: wrap)
  end

  def test_returns_inspected_value
    r = @ev.run("1 + 2")
    assert_equal "3", r[:result]
    assert_equal "", r[:stdout]
  end

  def test_captures_puts_without_leaking_to_real_stdout
    out, = capture_io { @r = @ev.run('puts "hi"; :done') }
    assert_equal "", out
    assert_equal "hi\n", @r[:stdout]
    assert_equal ":done", @r[:result]
  end

  def test_restores_stdout_after_exception
    before = $stdout
    assert_raises(SketchupMcpBridge::Evaluator::EvalError) { @ev.run('puts "x"; raise "boom"') }
    assert_same before, $stdout
  end

  def test_exception_carries_stdout_and_message
    err = assert_raises(SketchupMcpBridge::Evaluator::EvalError) { @ev.run('puts "partial"; raise "boom"') }
    assert_match(/RuntimeError: boom/, err.message)
    assert_equal "partial\n", err.stdout
  end

  def test_locals_persist_between_calls
    @ev.run("a = 41")
    assert_equal "42", @ev.run("a + 1")[:result]
  end

  def test_runs_inside_named_wrap
    @ev.run("1", operation: "Draw box")
    assert_equal ["Draw box"], @wraps
  end

  def test_default_operation_name
    @ev.run("1")
    assert_equal ["MCP eval"], @wraps
  end

  def test_long_result_is_truncated
    r = @ev.run('"x" * 100_000')
    assert_operator r[:result].length, :<, 21_000
    assert r[:truncated]
  end

  def test_syntax_error_is_reported
    err = assert_raises(SketchupMcpBridge::Evaluator::EvalError) { @ev.run("def (") }
    assert_match(/SyntaxError/, err.message)
  end
end
