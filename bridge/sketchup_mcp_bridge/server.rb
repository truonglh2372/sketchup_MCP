# Localhost line-JSON server driven by #tick. NO threads: Ruby threads inside
# SketchUp starve while the app is idle, and the SketchUp API must only be
# touched on the main thread. The dialog's JS setInterval calls tick, which
# accepts, reads and answers with non-blocking IO right on the main thread.
require "socket"
require_relative "protocol"

module SketchupMcpBridge
  class Server
    HOST = "127.0.0.1".freeze
    MAX_LINE_BYTES = 16 * 1024 * 1024

    attr_reader :host, :port
    attr_accessor :on_request

    def initialize(port:, token:, dispatcher:, host: HOST)
      @host = host
      @requested_port = port
      @token = token
      @dispatcher = dispatcher
      @clients = {} # socket => buffer
      @on_request = nil
    end

    def start
      @listener = TCPServer.new(@host, @requested_port)
      @port = @listener.addr[1]
      self
    end

    def running?
      !@listener.nil?
    end

    def stop
      @clients.each_key { |c| c.close rescue nil }
      @clients.clear
      @listener.close if @listener
      @listener = nil
    end

    # Returns the number of requests answered during this tick.
    def tick
      return 0 unless @listener

      accept_pending
      handled = 0
      @clients.keys.each { |c| handled += service(c) }
      handled
    end

    private

    def accept_pending
      loop do
        sock = @listener.accept_nonblock
        @clients[sock] = +""
      end
    rescue IO::WaitReadable, Errno::EINTR
      nil
    end

    def service(sock)
      buf = @clients[sock]
      begin
        loop { buf << sock.read_nonblock(65_536) }
      rescue IO::WaitReadable
        nil
      rescue EOFError, IOError, SystemCallError
        drop(sock)
        return 0
      end
      if buf.bytesize > MAX_LINE_BYTES
        drop(sock)
        return 0
      end

      handled = 0
      while (nl = buf.index("\n"))
        line = buf.slice!(0..nl).strip
        next if line.empty?
        write(sock, respond(line))
        handled += 1
      end
      handled
    end

    def respond(line)
      status, req = Protocol.parse_request(line, @token)
      return req if status == :error

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resp = begin
        Protocol.success(req["id"], @dispatcher.call(req["method"], req["params"]))
      rescue ScriptError, StandardError => e
        Protocol.failure(req["id"], e)
      end
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      @on_request.call(req["method"], resp[:ok], ms) if @on_request
      resp
    end

    def write(sock, resp)
      sock.write(Protocol.encode(resp))
    rescue IOError, SystemCallError
      drop(sock)
    end

    def drop(sock)
      @clients.delete(sock)
      sock.close rescue nil
    end
  end
end
