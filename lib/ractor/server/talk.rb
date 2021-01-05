# frozen_string_literal: true
# shareable_constant_value: literal

module RefinementExporter
  refine Module do
    # See https://bugs.ruby-lang.org/issues/17374#note-8
    def refine(what, export: false)
      mod = super(what)
      return mod unless export

      export = self if export == true
      export.class_eval do
        mod.instance_methods(false).each do |method|
          define_method(method, mod.instance_method(method))
        end
        mod.private_instance_methods(false).each do |method|
          private define_method(method, mod.instance_method(method))
        end
      end
      mod
    end
  end
end
using RefinementExporter

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
