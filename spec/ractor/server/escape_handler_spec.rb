# frozen_string_literal: true

require_relative '../fixtures/escape_handler'

RSpec.describe EscapeHandler do
  subject(:obj) { described_class.start }

  it { is_expected.to be_shareable }

  it 'passes errors transparently' do
    trace = []
    catch :goto do
      obj.with_ensure do
        obj.with_ensure do
          throw :goto
        ensure
          trace << :inner
        end
        raise 'never here'
      ensure
        trace << :outer
      end
    end
    expect(trace).to eq %i[inner outer]
    expect(obj.ensure_runs).to eq 2
  end
end
