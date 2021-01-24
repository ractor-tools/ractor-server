# frozen_string_literal: true
# shareable_constant_value: literal
require 'timeout'

class ErrorHandler
  include Ractor::Server

  def filter_error
    yield
  rescue Ractor::RemoteError => e
    raise e unless e.cause.is_a?(NoMethodError)

    :wrapped_no_method_error
  rescue NoMethodError
    :no_method_error
  end

  def direct
    yield
  end

  def with_error
    42.foo
  end

  def stuck?
    false
  end

  class Client
    def stuck?
      Timeout.timeout(0.1) { super }
    end
  end
end
