require "minitest/autorun"
require "json"
require_relative "../bridge/sketchup_mcp_bridge/protocol"

class ProtocolTest < Minitest::Test
  P = SketchupMcpBridge::Protocol
  TOKEN = "secret"

  def line(h)
    JSON.generate(h)
  end

  def test_valid_request_is_parsed
    status, req = P.parse_request(line(token: TOKEN, id: 7, method: "ping", params: { a: 1 }), TOKEN)
    assert_equal :ok, status
    assert_equal 7, req["id"]
    assert_equal "ping", req["method"]
    assert_equal({ "a" => 1 }, req["params"])
  end

  def test_missing_params_defaults_to_empty_hash
    _status, req = P.parse_request(line(token: TOKEN, id: 1, method: "ping"), TOKEN)
    assert_equal({}, req["params"])
  end

  def test_wrong_token_is_rejected
    status, resp = P.parse_request(line(token: "nope", id: 3, method: "ping"), TOKEN)
    assert_equal :error, status
    assert_equal 3, resp[:id]
    refute resp[:ok]
    assert_match(/token/i, resp[:error][:message])
  end

  def test_invalid_json_is_rejected
    status, resp = P.parse_request("{not json", TOKEN)
    assert_equal :error, status
    assert_nil resp[:id]
    assert_match(/json/i, resp[:error][:message])
  end

  def test_missing_method_is_rejected
    status, resp = P.parse_request(line(token: TOKEN, id: 4), TOKEN)
    assert_equal :error, status
    assert_match(/method/i, resp[:error][:message])
  end

  def test_encode_is_one_json_line
    s = P.encode(id: 1, ok: true, result: "a\nb")
    assert s.end_with?("\n")
    assert_equal 1, s.count("\n")
    assert_equal "a\nb", JSON.parse(s)["result"]
  end

  def test_success_and_error_responses
    assert_equal({ id: 2, ok: true, result: 5 }, P.success(2, 5))
    err = P.failure(2, RuntimeError.new("boom"))
    refute err[:ok]
    assert_equal "RuntimeError: boom", err[:error][:message]
    assert_kind_of Array, err[:error][:backtrace]
  end
end
