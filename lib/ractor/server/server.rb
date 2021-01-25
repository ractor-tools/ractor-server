# frozen_string_literal: true
# shareable_constant_value: literal

class Ractor
  module Server
    include Debugging
    include Talk

    private def main_loop
      debug(:server) { "Running #{inspect}" }

      loop do
        process(*receive_request)
      end

      debug(:server) { "Terminated #{inspect}" }
      :done
    end

    INTERRUPT = Object.new.freeze
    private_constant :INTERRUPT

    private def process(rq, method_name, args, options, block = nil)
      catch(INTERRUPT) do
        if rq.converse?
          public_send(method_name, *args, **options) do |yield_arg|
            yield_client(rq, yield_arg)
          end
        else
          public_send(method_name, *args, **options, &block)
        end => result
      rescue Exception => e
        rq.send_exception(e) unless rq.tell?
      else
        rq.conclude(result) unless rq.tell?
      end
    end

    private def yield_client(rq, arg)
      yield_request = rq.converse(arg)
      loop do
        rq, *data = yield_request.receive
        case rq.sync
        when :conclude then return data.first
        when :interrupt then throw INTERRUPT
        else # Reentrant request
          process(rq, *data)
        end
      end
    end

    module ClassMethods
      def tells(*methods)
        self::Client.tells(*methods)
      end

      def share_args(*methods)
        self::Client.share_args(*methods)
      end

      def start(*args, **options)
        ractor = start_ractor(*args, **options)
        self::Client.new(ractor)
      end

      # @returns [Ractor] running an instance of the Server
      def start_ractor(*args, **options)
        ::Ractor.new(self, args.freeze, options.freeze) do |klass, args, options|
          server = klass.new(*args, **options)
          server.__send__ :main_loop
        end
      end
    end

    class << self
      private def included(base)
        base.const_set(:Client, ::Class.new(Client) { const_set(:Server, base) })
        base.extend ClassMethods
      end
    end
  end
end
