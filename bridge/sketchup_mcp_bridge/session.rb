# One bridge session = a listening Server plus the bridge.json file that tells
# the MCP process which port and token to use. The file is removed on stop,
# but only if this process wrote it (two SketchUp versions can be open).
require "json"
require "fileutils"
require "securerandom"
require_relative "server"

module SketchupMcpBridge
  class Session
    DEFAULT_PORT = 9876

    def self.default_config_path
      base = ENV["SKETCHUP_MCP_HOME"] || File.join(ENV["APPDATA"] || Dir.home, "sketchup_mcp")
      File.join(base, "bridge.json")
    end

    attr_reader :config_path

    def initialize(dispatcher:, config_path: self.class.default_config_path, port: DEFAULT_PORT,
                   port_attempts: 10, info: {})
      @dispatcher = dispatcher
      @config_path = config_path
      @port = port
      @port_attempts = port_attempts
      @info = info
      @server = nil
    end

    def start
      token = SecureRandom.hex(16)
      @server = bind(token)
      write_config(token)
      self
    end

    def port
      @server && @server.port
    end

    def running?
      !@server.nil? && @server.running?
    end

    def on_request=(hook)
      @on_request = hook
      @server.on_request = hook if @server
    end

    def tick
      @server ? @server.tick : 0
    end

    def stop
      @server.stop if @server
      @server = nil
      remove_config
    end

    private

    def bind(token)
      last = nil
      @port_attempts.times do |i|
        candidate = @port.zero? ? 0 : @port + i
        begin
          server = Server.new(port: candidate, token: token, dispatcher: @dispatcher)
          server.on_request = @on_request
          return server.start
        rescue Errno::EADDRINUSE, Errno::EACCES => e
          last = e
        end
      end
      raise last || "no port"
    end

    def write_config(token)
      FileUtils.mkdir_p(File.dirname(@config_path))
      cfg = @info.merge("port" => port, "token" => token, "pid" => Process.pid,
                        "started_at" => Time.now.strftime("%Y-%m-%dT%H:%M:%S"))
      File.write(@config_path, JSON.pretty_generate(cfg))
    end

    def remove_config
      return unless File.exist?(@config_path)

      owner = (JSON.parse(File.read(@config_path))["pid"] rescue nil)
      File.delete(@config_path) if owner.nil? || owner == Process.pid
    rescue SystemCallError
      nil
    end
  end
end
