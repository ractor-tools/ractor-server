# frozen_string_literal: true

require_relative '../fixtures/shared_object'

RSpec.describe SharedObject do
  subject(:obj) { described_class.start }

  it { is_expected.to be_shareable }

  it 'has the right ancestors' do
    expect(obj.class.ancestors).to start_with [
      SharedObject::Client,
      SharedObject::Client::ServerCallLayer,
      Ractor::Server::Client,
    ]
    SharedObject::Client.refresh_server_call_layer
    expect(SharedObject::Client::ServerCallLayer.instance_methods).to match_array %i[
      value value= update server_exec
    ]
  end

  it 'has the right config' do
    expect(SharedObject::Client.config(:tell_methods).to_a).to eq %i[server_exec]
  end

  let 'given an initialization value' do
    subject(:obj) { described_class.start([:example]) }

    its(:value) { is_expected.to eq [:example] }
  end

  describe '#value' do
    its(:value) { is_expected.to eq nil }

    context 'after a caller is called' do
      let(:value) { [1, 2] }
      before { obj.value = value }

      it 'makes the value sent to the setter shareable' do
        y = Ractor.new(obj) { |obj| obj.value += [3, 4] }.take
        expect(y).to eq [1, 2, 3, 4]
        expect(y).to equal obj.value
      end

      it 'returns shareable value' do
        expect(obj.value).to be_shareable
        expect(obj.value).to equal value
      end
    end
  end

  describe '#update' do
    it 'provides an atomic way to update the value' do
      obj.value = [1, 2]
      r1 = Ractor.new(obj) do |obj|
        receive # => :sync

        obj.update do |cur|
          Ractor.main << :update_r1
          cur + [4]
        end
        Ractor.main << :end
      end
      r2 = Ractor.new(obj, r1) do |obj, r1|
        obj.update do |cur|
          r1.send :sync

          sleep(0.01)
          Ractor.main << :update_r2
          cur + [3]
        end
      end
      acks = 3.times.map { Ractor.receive }

      expect(acks).to eq %i[update_r2 update_r1 end]
      expect(obj.value).to eq [1, 2, 3, 4]
      expect(obj.value).to be_shareable
      expect(r2.take).to eq [1, 2, 3]
    end

    it 'is exclusively reentrant' do
      obj.value = [1, 2]
      r = Ractor.new(obj) do |obj|
        receive # => sync
        obj.value # => will have to wait for the end of `update`
      end
      obj.update do |cur|
        r << :sync
        sleep(0.1)
        reentrant = obj.value # => does not have to wait for the end of `update` (yay)
        cur + [cur.equal?(reentrant)]
      end
      expect(obj.value).to eq [1, 2, true]
      expect(r.take).to eq [1, 2, true]
    end
  end

  describe '#update_on_server' do
    it 'provides an atomic way to update the value on the server' do
      obj.value = [1, 2]

      r1 = Ractor.new(obj) do |obj|
        receive # => :sync

        obj.server_exec do
          Ractor.main << :update_r1
          @value += [4]
        end
        Ractor.main << :end
      end
      r2 = Ractor.new(obj, r1) do |obj, r1|
        result = obj.server_exec(r1) do |r1|
          r1.send :sync

          sleep(0.01)
          Ractor.main << :update_r2
          @value += [3]
        end
        Ractor.main << :end
        result
      end
      acks = 4.times.map { Ractor.receive }

      expect(acks).to eq %i[end end update_r2 update_r1]
      expect(obj.value).to eq [1, 2, 3, 4]
      expect(obj.value).not_to be_shareable
      expect(r2.take).to be_a(Ractor::Server::Request)
    end
  end
end
