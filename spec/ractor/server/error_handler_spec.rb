# frozen_string_literal: true

require_relative '../fixtures/error_handler'

RSpec.describe ErrorHandler do
  subject(:obj) { described_class.start }

  it { is_expected.to be_shareable }

  it 'passes errors transparently' do
    expect { obj.direct { XYZ } }.to raise_error(NameError)
    expect { obj.direct { 42.foo } }.to raise_error(NoMethodError)
    expect(obj.stuck?).to eq false
  end

  if Ractor::Server::WRAP_IN_REMOTE_ERROR
    it 'allows client to get server-side exceptions' do
      expect { obj.with_error }.to raise_error(Ractor::RemoteError)
      expect(obj.stuck?).to eq false
    end

    it 'allows server to filter exceptions' do
      expect { obj.filter_error { XYZ } }.to raise_error(NameError)
      expect(obj.filter_error { 42.foo }).to eq :wrapped_no_method_error
      expect(obj.stuck?).to eq false
    end
  else
    it 'allows client to get server-side exceptions' do
      expect { obj.with_error }.to raise_error(NoMethodError)
      expect(obj.stuck?).to eq false
    end

    it 'allows server to filter exceptions' do
      expect { obj.filter_error { XYZ } }.to raise_error(NameError)
      expect(obj.filter_error { 42.foo }).to eq :no_method_error
      expect(obj.stuck?).to eq false
    end
  end
end
