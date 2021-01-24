# frozen_string_literal: true
# shareable_constant_value: literal

require 'refine_export'
using RefineExport

class Ractor
  module Server
    module Talk
      class Error < Server::Error
      end

      class << self
        def receive_request
          Request.receive_if { |rq,| rq.is_a?(Request) }
        end
      end

      refine ::Ractor, export: true do
        include Debugging

        # @return [Request]
        private def receive_request
          Talk.receive_request
        end

        # @return [Request]
        def send_request(*arguments, **options)
          Request.send(self, *arguments, **options)
        end
      end

      refine ::Ractor.singleton_class do
        def receive_request
          Talk.receive_request
        end
      end
    end
  end
end
