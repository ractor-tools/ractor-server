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

    it '`sync: interrupt` enforces responding to a 2-level conversation' do
      expect(test(:converse, :interrupt)).to eq %i[error error fallback error]
      %i[double_conclude interrupt].map do |method|
        Ractor.new(method) do |method|
          result = []
          rq = send_request :test, sync: :converse
          result << :ok1 if receive_request == [rq, :test]
          rq2 = rq.send(:further_down, sync: :converse)
          result << :ok2 if rq.receive == [rq2, :further_down]
          if method == :double_conclude
            rq3 = rq2.send(:stop, sync: :conclude)
            result << :ok3 if rq2.receive == [rq3, :stop]
            rq4 = rq.send(:stop_outer, sync: :conclude)
            result << :ok4 if rq.receive == [rq4, :stop_outer]
          else
            rq3 = rq2.send(:stop, sync: :interrupt)
            result << :ok5 if rq2.receive == [rq3, :stop]
            result << (rq.send(:stop_outer, sync: :conclude) && :sent rescue :err)
            result << (rq.receive && :received rescue :err)
          end
          result << (rq3.send(:bad, sync: :conclude) && :sent rescue :err)
          result << (rq2.send(:bad, sync: :conclude) && :sent rescue :err)
          result << (rq.send(:bad, sync: :tell) && :sent rescue :err)
          result
        end.take
      end => results
      expect(results).to eq [
        %i[ok1 ok2 ok3 ok4 err err sent],
        %i[ok1 ok2 ok5 err err err err sent],
      ]
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
      rescue Exception => e
        e
      end
      expect(exc).to be_a(IndexError)
    end
  end
end
