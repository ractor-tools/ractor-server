# frozen_string_literal: true
# shareable_constant_value: literal

class SharedObject
  include Ractor::Server

  attr_accessor :value

  def initialize(value = nil)
    @value = value
  end

  share_args :value=, :initialize

  share_args def update
    @value = yield @value
  end

  tells share_args def server_exec(*args, block)
    instance_exec(*args, &block)
  end

  class Client
    def server_exec(*args, &block)
      super(*args, block)
    end
  end
end
