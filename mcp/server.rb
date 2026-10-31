# MCP server (stdio, newline-delimited JSON-RPC 2.0) that forwards tool calls
# to the SketchUp bridge over localhost TCP. No gems needed.
#
#   claude mcp add --scope user sketchup -- ruby C:/path/to/sketchup_mcp/mcp/server.rb
require "json"
require "socket"
require "timeout"

module SketchupMcp
  VERSION = "0.1.0".freeze
  DEFAULT_PROTOCOL = "2025-06-18".freeze

  class BridgeError < StandardError; end

  # Reads port + token from the file the bridge writes when its window opens,
  # re-read on every call so restarting SketchUp needs no MCP restart.
  class BridgeClient
    DEFAULT_TIMEOUT = 60
    START_HINT = "Open the bridge in SketchUp first: Extensions > MCP Bridge " \
                 "(the window must stay open while Claude works).".freeze

    def self.default_config_path
      base = ENV["SKETCHUP_MCP_HOME"] || File.join(ENV["APPDATA"] || Dir.home, "sketchup_mcp")
      File.join(base, "bridge.json")
    end

    def initialize(config_path: self.class.default_config_path)
      @config_path = config_path
      @next_id = 0
    end

    def call(method, params, timeout: nil)
      cfg = load_config
      @next_id += 1
      req = { "token" => cfg["token"], "id" => @next_id, "method" => method, "params" => params || {} }
      line = exchange(cfg["port"].to_i, JSON.generate(req) + "\n", timeout || DEFAULT_TIMEOUT)
      resp = JSON.parse(line)
      return resp["result"] if resp["ok"]

      raise BridgeError, format_error(resp["error"] || {})
    end

    private

    def load_config
      raise BridgeError, "Bridge not running (#{@config_path} missing). #{START_HINT}" unless File.exist?(@config_path)

      JSON.parse(File.read(@config_path))
    rescue JSON::ParserError
      raise BridgeError, "Bridge config #{@config_path} is corrupt. #{START_HINT}"
    end

    def exchange(port, payload, timeout_s)
      sock = Timeout.timeout(5) { TCPSocket.new("127.0.0.1", port) }
      sock.write(payload)
      line = Timeout.timeout(timeout_s) { sock.gets }
      raise BridgeError, "Bridge closed the connection without replying." unless line

      line
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      raise BridgeError, "Cannot reach the bridge on port #{port}. #{START_HINT}"
    rescue Timeout::Error
      raise BridgeError, "SketchUp did not answer within #{timeout_s}s (busy, or the bridge window was closed)."
    ensure
      sock.close if sock
    end

    def format_error(err)
      parts = [err["message"].to_s]
      parts << "stdout:\n#{err['stdout']}" unless err["stdout"].to_s.empty?
      bt = Array(err["backtrace"]).first(8)
      parts << "backtrace:\n#{bt.join("\n")}" unless bt.empty?
      parts.join("\n\n")
    end
  end

  class Server
    def self.tool(name, description, properties = {}, required = [])
      { "name" => name, "description" => description,
        "inputSchema" => { "type" => "object", "properties" => properties, "required" => required } }
    end

    TOOLS = [
      tool("sketchup_status",
           "Check the SketchUp connection: version, open model title/path, units, selection count."),
      tool("eval_ruby",
           "Run Ruby inside SketchUp (full SketchUp API: Sketchup.active_model, Geom, etc). " \
           "Each call is ONE undo step. Locals persist between calls. Returns the inspected value " \
           "and anything printed with puts. Lengths in the API are inches (use 100.mm).",
           { "code" => { "type" => "string", "description" => "Ruby source to evaluate" },
             "operation_name" => { "type" => "string", "description" => "Undo label (default 'MCP eval')" },
             "timeout_s" => { "type" => "integer", "description" => "Max seconds to wait (default 120)" } },
           ["code"]),
      tool("get_selection",
           "List the selected entities: class, entityID, name/definition, tag, bounds in mm."),
      tool("list_entities",
           "List entities in the active drawing context (top level, or the group being edited).",
           { "limit" => { "type" => "integer", "description" => "Max entities (default 200)" } }),
      tool("dump_entity",
           "Geometry of one group/component in mm: faces (outer loop vertices, normal, area), " \
           "edges, nested instances, transform. Defaults to the first selected entity.",
           { "entity_id" => { "type" => "integer", "description" => "entityID; omit for selection" },
             "max_faces" => { "type" => "integer", "description" => "Face cap (default 2000)" } }),
      tool("screenshot",
           "Capture the current SketchUp viewport as PNG so you can see the model.",
           { "width" => { "type" => "integer", "description" => "Pixels (default 1280)" },
             "height" => { "type" => "integer", "description" => "Pixels (default keeps view aspect)" } }),
      tool("undo", "Undo the last operation in SketchUp (same as Ctrl+Z).")
    ].freeze

    BRIDGE_METHOD = { "sketchup_status" => "ping" }.freeze
    EVAL_TIMEOUT = 120

    def initialize(bridge: BridgeClient.new)
      @bridge = bridge
    end

    def run(input = $stdin, output = $stdout)
      output.sync = true if output.respond_to?(:sync=)
      input.each_line do |line|
        line = line.strip
        next if line.empty?

        reply = begin
          handle(JSON.parse(line))
        rescue JSON::ParserError
          { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32_700, "message" => "Parse error" } }
        end
        output.write(JSON.generate(reply) + "\n") if reply
      end
    end

    def handle(msg)
      id = msg["id"]
      return nil if id.nil? && msg["method"].to_s.start_with?("notifications/")
      return nil unless msg.key?("id")

      result = case msg["method"]
      when "initialize" then initialize_result(msg["params"] || {})
      when "ping" then {}
      when "tools/list" then { "tools" => TOOLS }
      when "tools/call" then call_tool(msg["params"] || {})
      else
        return { "jsonrpc" => "2.0", "id" => id,
                 "error" => { "code" => -32_601, "message" => "Method not found: #{msg['method']}" } }
      end
      { "jsonrpc" => "2.0", "id" => id, "result" => result }
    end

    private

    def initialize_result(params)
      { "protocolVersion" => params["protocolVersion"] || DEFAULT_PROTOCOL,
        "capabilities" => { "tools" => {} },
        "serverInfo" => { "name" => "sketchup", "version" => VERSION },
        "instructions" => "Drive a live SketchUp session. Start with sketchup_status; " \
                          "use screenshot to check results; every eval_ruby call is one undo step." }
    end

    def call_tool(params)
      name = params["name"].to_s
      args = params["arguments"] || {}
      return tool_error("Unknown tool: #{name}") unless TOOLS.any? { |t| t["name"] == name }

      timeout = name == "eval_ruby" ? (args["timeout_s"] || EVAL_TIMEOUT).to_i : nil
      result = @bridge.call(BRIDGE_METHOD.fetch(name, name), args, timeout: timeout)
      return screenshot_content(result) if name == "screenshot"

      { "content" => [text(JSON.pretty_generate(result))], "isError" => false }
    rescue BridgeError => e
      tool_error(e.message)
    end

    def screenshot_content(result)
      path = result["path"].to_s
      data = File.binread(path)
      File.delete(path) rescue nil
      { "content" => [{ "type" => "image", "mimeType" => "image/png", "data" => [data].pack("m0") },
                      text("#{result['width']}x#{result['height']}")],
        "isError" => false }
    rescue SystemCallError => e
      tool_error("Screenshot file unreadable: #{e.message}")
    end

    def text(s)
      { "type" => "text", "text" => s }
    end

    def tool_error(message)
      { "content" => [text(message)], "isError" => true }
    end
  end
end

SketchupMcp::Server.new.run if $PROGRAM_NAME == __FILE__
