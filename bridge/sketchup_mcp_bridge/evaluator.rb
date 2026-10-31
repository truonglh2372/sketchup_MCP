# Runs Ruby sent by the MCP client. Locals persist between calls (one binding
# per bridge session), puts output is captured, and each run goes through
# +wrap+ — in SketchUp that is one start_operation, so Ctrl+Z undoes one call.
require "stringio"

module SketchupMcpBridge
  class Evaluator
    MAX_RESULT_CHARS = 20_000
    DEFAULT_OPERATION = "MCP eval".freeze

    class EvalError < StandardError
      attr_reader :stdout, :original

      def initialize(original, stdout)
        @original = original
        @stdout = stdout
        super("#{original.class}: #{original.message}")
        set_backtrace(original.backtrace)
      end
    end

    # Plain object so evaluated code does not see the bridge's own ivars.
    class Sandbox
      def __binding
        binding
      end
    end

    def initialize(wrap:)
      @wrap = wrap
      @binding = Sandbox.new.__binding
    end

    def run(code, operation: nil)
      out = StringIO.new
      value = nil
      begin
        saved = $stdout
        $stdout = out
        @wrap.call(operation || DEFAULT_OPERATION) do
          value = eval(code.to_s, @binding, "(mcp)", 1) # rubocop:disable Security/Eval
        end
      rescue ScriptError, StandardError => e
        raise EvalError.new(e, out.string)
      ensure
        $stdout = saved
      end
      text = safe_inspect(value)
      truncated = text.length > MAX_RESULT_CHARS
      text = text[0, MAX_RESULT_CHARS] + "…" if truncated
      { result: text, stdout: out.string, truncated: truncated }
    end

    private

    def safe_inspect(value)
      value.inspect
    rescue StandardError => e
      "#<inspect failed: #{e.class}: #{e.message}>"
    end
  end
end
