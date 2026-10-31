# One JSON object per line, both directions.
#   request:  {"token": "...", "id": 1, "method": "eval_ruby", "params": {...}}
#   response: {"id": 1, "ok": true, "result": ...}
#             {"id": 1, "ok": false, "error": {"message": "...", "backtrace": [...]}}
# Pure Ruby (no SketchUp API) so it is unit-testable and Ruby 2.7-safe.
require "json"

module SketchupMcpBridge
  module Protocol
    module_function

    def parse_request(line, token)
      req = JSON.parse(line)
      return [:error, error_response(nil, "Request must be a JSON object")] unless req.is_a?(Hash)

      id = req["id"]
      return [:error, error_response(id, "Invalid token")] unless req["token"] == token

      method = req["method"]
      return [:error, error_response(id, "Missing method")] unless method.is_a?(String) && !method.empty?

      params = req["params"].is_a?(Hash) ? req["params"] : {}
      [:ok, { "id" => id, "method" => method, "params" => params }]
    rescue JSON::ParserError => e
      [:error, error_response(nil, "Invalid JSON: #{e.message[0, 200]}")]
    end

    def success(id, result)
      { id: id, ok: true, result: result }
    end

    def failure(id, exception)
      error = { message: "#{exception.class}: #{exception.message}", backtrace: Array(exception.backtrace).first(15) }
      error[:stdout] = exception.stdout if exception.respond_to?(:stdout)
      { id: id, ok: false, error: error }
    end

    def error_response(id, message)
      { id: id, ok: false, error: { message: message, backtrace: [] } }
    end

    # JSON.generate escapes newlines inside strings, so the payload is one line.
    def encode(hash)
      JSON.generate(hash) + "\n"
    end
  end
end
