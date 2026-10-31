# Extension entry: menu item + the bridge window. The window's JS interval is
# the heartbeat (see server.rb); closing the window stops the bridge.
require "sketchup.rb"
require "json"
require_relative "protocol"
require_relative "evaluator"
require_relative "server"
require_relative "session"
require_relative "dispatcher"
require_relative "handlers"

module SketchupMcpBridge
  DIR = File.dirname(__FILE__)
  FILES = %w[protocol evaluator server session dispatcher handlers].freeze

  class << self
    attr_reader :session, :dialog

    def open_window
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end
      @dialog = build_dialog
      @dialog.show
    end

    def start!
      return if @session && @session.running?

      @session = Session.new(dispatcher: Dispatcher.new(Handlers.new),
                             info: { "sketchup" => Sketchup.version, "model" => Sketchup.active_model.title })
      @session.start
      @session.on_request = lambda do |method, ok, ms|
        push("addLog", { "method" => method, "ok" => ok, "ms" => ms, "at" => Time.now.strftime("%H:%M:%S") })
      end
      push_status
      puts "[MCP Bridge] listening on 127.0.0.1:#{@session.port} (#{@session.config_path})"
    rescue StandardError => e
      puts "[MCP Bridge] start failed: #{e.class}: #{e.message}"
      push("setStatus", { "running" => false, "error" => e.message })
    end

    def stop!
      @session.stop if @session
      @session = nil
      push_status
    end

    # Dev convenience: re-read every bridge file without restarting SketchUp.
    def reload!
      running = @session && @session.running?
      stop!
      FILES.each { |f| load File.join(DIR, "#{f}.rb") }
      start! if running
      puts "[MCP Bridge] reloaded"
    end

    private

    def build_dialog
      dlg = UI::HtmlDialog.new(dialog_title: "MCP Bridge", preferences_key: "SketchupMcpBridge",
                               width: 380, height: 420, resizable: true, style: UI::HtmlDialog::STYLE_UTILITY)
      dlg.set_file(File.join(DIR, "dialog.html"))
      dlg.add_action_callback("tick") { |_ctx| @session.tick if @session }
      dlg.add_action_callback("ready") { |_ctx| start! unless @session; push_status }
      dlg.add_action_callback("start") { |_ctx| start! }
      dlg.add_action_callback("stop") { |_ctx| stop! }
      dlg.add_action_callback("reload") { |_ctx| reload! }
      dlg.set_on_closed { stop! }
      dlg
    end

    def push_status
      running = !@session.nil? && @session.running?
      push("setStatus", { "running" => running, "port" => running ? @session.port : nil })
    end

    def push(fn, payload)
      return unless @dialog && @dialog.visible?

      @dialog.execute_script("#{fn}(#{JSON.generate(payload)})")
    end
  end

  unless file_loaded?(__FILE__)
    UI.menu("Extensions").add_item("MCP Bridge") { SketchupMcpBridge.open_window }
    file_loaded(__FILE__)
  end
end
