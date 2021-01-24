# frozen_string_literal: true
# shareable_constant_value: literal

require_relative 'server'

class Ractor
  module Server
    class Client
      include Debugging
      attr_reader :server

      def initialize(server)
        raise ArgumentError, "Expected a Ractor, got #{server.inspect}" unless server.is_a?(::Ractor)

        @nest_request_key = :"Ractor::Server::Client#{object_id}"
        @server = server
        freeze
      end

      CONFIG = {
        share_args: Set[].freeze,
        tell_methods: Set[].freeze,
      }

      def inspect
        "<##{self.class} server: #{call_server(:inspect)}>"
      end

      alias_method :to_s, :inspect

      NOT_IMPLICITLY_DEFINED = (Object.instance_methods | Ractor::Server.instance_methods).freeze
      private_constant :NOT_IMPLICITLY_DEFINED

      class << self
        include Debugging

        def start(*args, **options)
          ractor = self.class::Server.start_ractor(*args, **options)
          new(ractor)
        end

        def refresh_server_call_layer
          layer = self::ServerCallLayer
          server_klass = self::Server
          are_defined = layer.instance_methods
          should_be_defined = server_klass.instance_methods - NOT_IMPLICITLY_DEFINED
          (are_defined - should_be_defined).each { layer.remove_method _1 }
          interface_with_server(*config(:tell_methods) | should_be_defined - are_defined)
        end

        def interface_with_server(*methods)
          methods.flatten!(1)
          self::ServerCallLayer.class_eval do
            methods.each do |method|
              public alias_method(method, :call_server_alias)
            end
          end
          debug(:interface) { "Defined methods #{methods.join(', ')}" }

          methods
        end

        def tells(*methods)
          methods.flatten!(1)
          config(:tell_methods) { |set| set + methods }
          interface_with_server(*methods)
        end

        def config(key)
          cur = self::CONFIG
          cur_value = cur.fetch(key)
          if block_given?
            cur_value = yield cur_value
            remove_const(:CONFIG) if const_defined?(:CONFIG, false)
            const_set(:CONFIG, Ractor.make_shareable(cur.merge(key => cur_value)))
          end
          cur_value
        end

        def sync_kind(method, block_given)
          case
          when setter?(method) || config(:tell_methods).include?(method)
            :tell
          when block_given
            :converse
          else
            :ask
          end
        end

        def share_args(*methods)
          methods.flatten!(1)
          config(:share_args) { |val| val + methods }

          methods
        end

        private def inherited(base)
          mod = Module.new do
            private def call_server_alias(*args, **options, &block)
              call_server(__callee__, *args, **options, &block)
            end
          end

          base.const_set(:ServerCallLayer, mod)
          base.include mod

          super
        end

        NON_SETTERS = Set[*%i[<= == === != >=]].freeze
        private_constant :NON_SETTERS

        private def setter?(method)
          method.end_with?('=') && !NON_SETTERS.include?(method)
        end
      end

      private def respond_to_missing?(method, priv = false)
        !priv && implemented_by_server?(method) || super
      end

      private def method_missing(method, *args, **options, &block)
        if implemented_by_server?(method)
          refresh_server_call_layer
          # sanity check
          unless self.class::ServerCallLayer.method_defined?(method)
            raise "`refresh_server_call_layer` failed for #{method}"
          end

          return __send__(method, *args, **options, &block)
        end

        super
      end

      private def implemented_by_server?(method)
        self.class::Server.method_defined?(method)
      end

      private def refresh_server_call_layer
        self.class.refresh_server_call_layer
      end

      # @returns [Request] if method should be called as `:tell`,
      # otherwise returns the result of the concluded method call.
      private def call_server(method, *args, **options, &block)
        Ractor.make_shareable([args, options]) if share_inputs?(method)

        info = format_call(method, *args, **options, &block) if $DEBUG
        rq = Request.send(
          @server, method, args, options,
          response_to: Thread.current[@nest_request_key],
          sync: self.class.sync_kind(method, !!block),
          info: info,
        )
        return rq if rq.tell?

        await_response(rq, method, &block)
      end

      private def await_response(rq, method)
        debug(:await) { "Awaiting response to #{rq}" }

        loop do
          response, result = rq.receive
          case response.sync
          in :converse then handle_yield(method, response) { yield result }
          in :conclude then return result
          end
        end
      ensure
        debug(:await) { "Finished waiting for #{rq}" }
      end

      private def handle_yield(method, response)
        block_result = with_requests_nested(response) do
          yield
        rescue Exception => e
          response.send_exception(e)
          return
        end
        Ractor.make_shareable(block_result) if share_inputs?(method)
        response.conclude block_result
      end

      private def with_requests_nested(context)
        store = Thread.current
        prev = store[@nest_request_key]
        store[@nest_request_key] = context
        yield
      ensure
        store[@nest_request_key] = prev
      end

      private def share_inputs?(method_name)
        self.class.config(:share_args).include?(method_name)
      end

      private def format_call(method, *args, **options, &block)
        args = args.map(&:inspect) + options.map { _1.map(&:inspect).join(': ') }
        arg_list = "(#{args.join(', ')})" unless args.empty?
        block_sig = ' {...}' if block
        "#{method}#{arg_list}#{block_sig}"
      end
    end
  end
end
