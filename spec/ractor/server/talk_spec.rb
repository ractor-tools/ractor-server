# frozen_string_literal: true

using Ractor::Server::Talk

RSpec.describe Ractor::Server::Talk do
  context 'without sync' do
    it 'works (no sync)' do
      ractor = Ractor.new do
        request, data = receive_request
        Ractor.main.send :not_a_request
        Ractor.main.send_request(:not_a_response)
        request.send(:hello)
        data
      end
      ractor.send :not_related

      request = ractor.send_request(:example)
      _response_rq, result = request.receive
      expect(ractor.take).to eq :example
      expect(result).to eq :hello
      expect(Ractor.receive).to eq :not_a_request
      expect(Ractor.receive).to end_with :not_a_response
    end
  end

  context 'with a sync' do
    def test(sync, reply_sync)
      ractor = Ractor.new(sync) do |sync|
        rq = Ractor.main.send_request :test, sync: sync
        2.times.map { rq.receive.last rescue :error }
      end
      request, _msg = Ractor.receive_request
      replies = 2.times.map do
        request.send(:reply, sync: reply_sync) && :ok rescue :error
      end
      request.send(:fallback, sync: :conclude) rescue nil
      results = ractor.take
      [*replies, *results]
    end

    it '`sync: :tell` enforces not responding/receiving' do
      expect(test(:tell, nil)).to eq %i[error error error error]
      expect(test(:tell, :tell)).to eq %i[error error error error]
      expect(test(:tell, :ask)).to eq %i[error error error error]
    end

    it '`sync: :ask` enforces responding/receiving once with tell' do
      expect(test(:ask, :conclude)).to eq %i[ok error reply error]
      expect(test(:ask, :ask)).to eq %i[error error fallback error]
      expect(test(:ask, nil)).to eq %i[error error fallback error]
    end

    it '`sync: converse` enforces responding with a non-nil sync' do
      expect(test(:converse, :conclude)).to eq %i[ok error reply error]
      expect(test(:converse, :ask)).to eq %i[ok ok reply reply]
      expect(test(:converse, nil)).to eq %i[error error fallback error]
    end
  end

  context 'responding with an exception' do
    it 'raises in #receive' do
      ractor = Ractor.new do
        request, _data = receive_request
        request.send_exception(IndexError.new('foo'))
      end
      request = ractor.send_request(:example)
      exc = begin
        request.receive
      rescue Ractor::RemoteError => e
        e.cause
      end
      expect(exc).to be_a(IndexError)
    end
  end
end
