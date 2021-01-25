# frozen_string_literal: true
# shareable_constant_value: literal
require 'timeout'

class EscapeHandler
  include Ractor::Server
  attr_accessor :ensure_runs

  def initialize
    @ensure_runs = 0
  end

  def with_ensure
    yield
    raise 'not meant to run'
  ensure
    @ensure_runs += 1
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
