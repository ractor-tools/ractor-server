# frozen_string_literal: true
# shareable_constant_value: literal

class Ractor
  module Server
    module Debugging
      def debug(_kind)
        puts yield if $DEBUG
      end
    end
  end
end
