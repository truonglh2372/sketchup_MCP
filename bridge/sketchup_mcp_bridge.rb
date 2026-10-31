# SketchUp extension loader. Install by copying this file AND the
# sketchup_mcp_bridge/ folder into the Plugins folder, or (dev) put a one-line
# stub in Plugins:  load "C:/path/to/sketchup_mcp/bridge/sketchup_mcp_bridge.rb"
require "sketchup.rb"
require "extensions.rb"

module SketchupMcpBridge
  unless defined?(EXTENSION)
    EXTENSION = SketchupExtension.new("MCP Bridge", File.join(File.dirname(__FILE__), "sketchup_mcp_bridge", "main"))
    EXTENSION.description = "Lets an MCP client (Claude Code) drive this SketchUp session over localhost."
    EXTENSION.version = "0.1.0"
    EXTENSION.creator = "truonglh2372"
    Sketchup.register_extension(EXTENSION, true)
  end
end
