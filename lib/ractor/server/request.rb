# frozen_string_literal: true
# shareable_constant_value: literal

using Ractor::Server::Talk

class Ractor
  module Server
    class Request
      include Debugging
      attr_reader :response_to, :initiating_ractor, :sync, :info

      def initialize(response_to: nil, sync: nil, info: nil)
        @response_to = response_to
        @initiating_ractor = Ractor.current
        @sync = sync
        @info = info # for display only
        enforce_valid_sync!
        Ractor.make_shareable(self)
      end

      # Match any request that is a response to the receiver (or an array message starting with such)
      def ===(message)
        request, = message

        match = request.is_a?(Request) && self == request.response_to

        debug(:receive) { "Request #{request.inspect} does not match #{self}" } unless match

        match
      end

      def to_proc
        method(:===).to_proc
      end

      # @return [Request]
      def send(*args, **options)
        Request.send(initiating_ractor, *args, **options, response_to: self)
      end

      %i[tell ask converse conclude].each do |sync|
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{sync}(*args, **options)                # def tell(*args, **options)
            send(*args, **options, sync: :#{sync})     #   send(*args, **options, sync: :tell)
          end                                          # end

          def #{sync}?                                 # def tell?
            sync == :#{sync}                           #   sync == :tell
          end                                          # end
        RUBY
      end

      class WrappedException
        # Use Marshal to circumvent https://bugs.ruby-lang.org/issues/17577
        def initialize(exception)
          @exception = Marshal.dump(exception)
        end

        def exception
          Marshal.load(@exception)
        end
      end
      private_constant :WrappedException

      def send_exception(exception)
        send(WrappedException.new(exception), sync: sync && :conclude)
      end

      def receive
        enforce_sync_when_receiving!
        unwrap(Request.receive_if(&self))
      end

      def inspect
        [
          '<Request',
          info,
          ("for: #{response_to}" if response_to),
          ("sync: #{sync}" if sync),
          "from: #{ractor_name(initiating_ractor)}>",
        ].compact.join(' ')
      end
      alias_method :to_s, :inspect

      def respond_to_ractor
        response_to.initiating_ractor
      end

      class << self
        include Debugging

        def message(*args, **options)
          request = new(**options)
          [request, *args].freeze
        end

        def pending_send_conclusion
          ::Ractor.current[:ractor_server_request_send_conclusion] ||= ::ObjectSpace::WeakMap.new
        end

        def pending_receive_conclusion
          ::Ractor.current[:ractor_server_request_receive_conclusion] ||= ::ObjectSpace::WeakMap.new
        end

        def receive_if(&block)
          message = ::Ractor.receive_if(&block)
          rq, = message
          rq.sync_after_receiving
          debug(:receive) { "Received #{message}" }
          message
        end

        def send(ractor, *arguments, move: false, **options)
          message = Request.message(*arguments, **options)
          request, = message
          request.enforce_sync_when_sending!
          debug(:send) { "Sending #{message}" }
          ractor.send(message, move: move)
          request
        end

        %i[tell ask converse conclude].each do |sync|
          class_eval <<~RUBY, __FILE__, __LINE__ + 1
            def #{sync}(r, *args, **options)             # def tell(r, *args, **options)
              send(r, *args, **options, sync: :#{sync})  #   send(r, *args, **options, sync: :tell)
            end                                          # end
          RUBY
        end
      end

      private def unwrap(message)
        _rq, arg = message
        raise_exception(arg) if arg.is_a?(WrappedException)

        message
      end

      private def raise_exception(exc)
        if exc.exception.is_a?(Ractor::RemoteError)
          debug(:exception) { 'Received RemoteError, raising original cause' }
          raise exc.exception.cause
        else
          debug(:exception) { 'Received exception, raising RemoveError' }
          begin
            raise exc.exception
          rescue Exception
            raise Ractor::RemoteError # => sets `cause` to exc.exception
          end
        end
      end

      # @api private
      def enforce_sync_when_sending!
        # Only dynamic checks are done here; static validity checked in constructor
        case sync
        when :conclude
          registry = Request.pending_send_conclusion
          raise Talk::Error, "Request #{response_to} already answered" unless registry[response_to]

          registry[response_to] = false
        when :ask, :converse
          Request.pending_receive_conclusion[self] = true
        end
      end

      # @api private
      def sync_after_receiving
        # Only dynamic checks are done here; static validity checked in constructor
        case sync
        when :conclude
          Request.pending_receive_conclusion[response_to] = false
        when :ask, :converse
          Request.pending_send_conclusion[self] = true
        end
      end

      # Receiver is request to receive a reply from
      private def enforce_sync_when_receiving!
        case sync
        when :tell, :conclude
          raise Talk::Error, "Can not receive from a Request for a `#{sync}` sync: #{self}"
        when :ask, :converse
          return :ok if Request.pending_receive_conclusion[self]

          raise Talk::Error, "Can not receive as #{self} is already answered"
        end
      end

      private def ractor_name(ractor)
        ractor.name || "##{ractor.to_s.match(/#(\d+) /)[1]}"
      end

      private def enforce_valid_sync!
        case [response_to&.sync, sync]
        in [nil, nil]
          :ok_unsynchronized
        in [nil | :converse, :tell | :ask | :converse]
          :ok_talk
        in [:ask | :converse, :conclude]
          :ok_concluding
        in [:tell | :conclude => from, _]
          raise Talk::Error, "Can not respond to a Request with `#{from.inspect}` sync"
        in [:ask, _]
          raise Talk::Error, "Request with `ask` sync must be responded with a `conclude` sync, got #{sync.inspect}"
        in [_, nil]
          raise Talk::Error, "Specify sync to respond to a Request with #{sync.inspect}"
        else
          raise ArgumentError, "Unrecognized sync: #{sync.inspect}"
        end
      end
    end
  end
end
