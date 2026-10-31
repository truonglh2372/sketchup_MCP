# Whitelisted routing from a bridge method name to a Handlers method.
module SketchupMcpBridge
  class Dispatcher
    METHODS = %w[ping eval_ruby get_selection list_entities dump_entity screenshot undo].freeze

    def initialize(handlers)
      @handlers = handlers
    end

    def call(method, params)
      raise ArgumentError, "Unknown method: #{method}" unless METHODS.include?(method)

      @handlers.public_send(method, params || {})
    end

    def to_proc
      method(:call).to_proc
    end
  end
end
