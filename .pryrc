# frozen_string_literal: true

$LOAD_PATH << './lib'
require 'ractor/server'

# Pry.config.hooks.add_hook(:when_started, :set_context) do |binding, options, pry|
#   if binding.eval('self').class == Object # true when starting `pry`
#     # false when called from binding.pry
#     pry.input = StringIO.new('cd Ractor::Server')
#   end
# end
