# Ractor::Server

## Usage

### Intro

This gem streamlines communication to a Ractor:
* a "Server" that makes its methods available (think Elixir/Erlang's `GenServer`)
* a "Client" that is immutable (Ractor shareable) and can call a "Server" from any Ractor.

Any class can `include Ractor::Server` and this automatically creates an interface:

```ruby
class RactorHash < Hash
  include Ractor::Server
end

H = RactorHash.start # => starts Server, returns instance of a Client

Ractor.new { H[:example] = 42 }.take # => 42
puts Ractor.new { H[:example] }.take # => 42
```

Calls are atomic but also allow reentrant calls from blocks:

```ruby
ractors = 3.times.map do |i|
  Ractor.new(i) do |i|
    H.fetch_values(:foo, :bar) do |val|
      H[val] = i
    end
  end
end

puts H # => {:example => 42, :foo => 0, :bar => 0}
       # (maybe 0 will be 1 or 2, but both will be same)
```

The first ractor to call `fetch_values` will have its block called twice; only the `fetch_values` has completed will the other Ractors have their calls to `fetch_values` run. The block is reentrant as it calls `[]=`; that call will not wait.

Exceptions are propagated between Client and Server. If they were raised on the remote side, they will be `Ractor::RemoveError`, otherwise they will be the original exception.

```ruby
begin
  H.fetch_values(:z) { raise ArgumentError }
rescue Ractor::RemoteError
  # raised remote-side
  :there
rescue ArgumentError
  # raised on this side
  :here
end # => :here
```

The implementation relies on three layers of functionality.

### Low-level API: `Request`

The first layer is the concept of a `Request` that uniquely identifies a message sent to a Ractor.

This enables a way to safely reply to a request:

```ruby
using Ractor::Server::Talk

ractor = Ractor.new do
  request, data = receive_request
  puts data # => :example
  request.send(:hello)
end

request = ractor.send_request(:example)
response_request, result = request.receive
puts result # => :hello
```

#### `Request` is an envelope

The `Request` itself contains no data other than the initiating Ractor (`Request#initiating_ractor`) and if it is a reply to another `Request` (`Request#response_to`):

```ruby
request.initiating_ractor == Ractor.current # => true
response_request.initiating_ractor == ractor # => true
request.response_to # => nil
response_request.response_to # => request
```

Note that a `Request` is immutable and thus Ractor-shareable irrespective of the data that accompanies it.

#### Nesting `Request`s

One may reply to a `Request` any number of times; it is up to the requester to receive the proper amount of times.

A response to a `Request` is itself a `Request`; `Requests` may be nested as deeply as required:

```ruby
# as above...
ractor = Ractor.new do
  request, data = receive_request
  puts data # => :example
  request.send(:hello)
  response_request = request.send(:world)
  other_request, data = response_request.receive
  puts data # => :inner
  # ...
end

request = ractor.send_request(:example)
_request, result = request.receive
puts result # => :hello
response_request, result = request.receive
puts result # => :world
response_request.send(:inner)
```

The method `receive_request` will only receive a `Request` that was sent with `send_request` and thus is not a response to another `Request`.

The method `Request#receive` will only receive a `Request` that is a direct response to the receiver.

#### Exceptions

Instead of responsing with data, it is possible to respond by raising (on the remote side) an error with `send_exception`.

Calling `send_exception` wraps the original exception in a `Ractor::Remote`:

```ruby
ractor = Ractor.new do
  request, data = receive_request
rescue Ractor::RemoteError => e
  puts e.cause # => 'example' (ArgumentError)
end

ractor.send_exception(ArgumentError.new('example'))
ractor.take
```

Calling `send_exception` again on the wrapped `Ractor::Remote` will unwrap it. This way, if an exception travels from the client to the server and back to the client, this voyage will be transparent to the client.

#### Implementation

`send_request` / `receive_request` use `Ractor#send` and `Ractor#receive_if` with the following layout:

```ruby
message = [Request, ...]
```

To avoid interfering with `Request`, any other Ractor communication must use `receive_if` and filter out messages of that form (i.e. any array starting with an instance of `Request`).

### Mid-level API: `Talk` using `sync:`

One may specify the expected syncing for a `Request`:

* `:tell`: receiver may not reply ("do this, I'm assuming it will get done")
* `:ask`: receiver must reply exactly once with sync type `:conclude`  ("do this, let me know when done, and don't me ask questions")
* `:conclude`: as with `:tell`, receiver may not reply. Must be in response of `ask` or `converse`
* `:converse`: receiver may reply has many times as desired (with sync type `:tell`, `:ask`, or `:converse`) and must then reply exactly once with sync type `:conclude`.  ("do this, ask questions if need be, and let me know when done")

The API uses `send_request`/`send` with a `sync:` named argument:

```ruby
ractor = Ractor.new do
  request, data = receive_request
  puts data # => :example
  request.send(:hello, sync: :tell)
  response_request = request.send(:world, sync: :ask)
  other_request, data = response_request.receive
  puts data # => :inner
  # ...
end

request = ractor.send_request(:example, sync: :converse)
response_request, result = request.receive
puts result # => :hello
puts response_request.sync # => :tell
response_request.send(:whatever, sync: :conclude) # => Error "can not reply to sync: say"
response_request, result = request.receive
puts result # => :world
request.receive # => Error, "request must be replied to"
response_request.send(:inner, sync: :conclude)
```

This example achieves exactly the same as before, but with clear semantics and checking on the sequence of events.

Shortcuts exists:

```ruby
ractor.send_request(..., sync: :tell) # or :ask, :conclude or :converse
# shortcuts:
ractor.tell(...)  # or .ask(...), .conclude(...) or .converse(...)

# Similarly for `Request#send`:
request.send(..., sync: :tell)
# same as
request.tell(...)
# etc.
```

### High-level API: `Client` & `Server`

The `Client` and `Server` module make it easy to use the `sync:` API to allow a client to call methods on the server and for the server to yield back to the client.

The client makes a method call using either `:tell` or `:ask` and the data consists of the method name, arguments and keyword parameters.
The result is either the request (`:tell`) or the data received (`:ask`).

For method calls with blocks, the client uses `:converse`. The server may yield back to the client with a nested `:converse` response. From inside the block, the client can send nested calls to the server (simple or with block). The result of the block is returned to the server with `:conclude`. The server may then yield again, or if it is finished it `conclude`s the outer conversation.

To define a server, it suffices to define the methods that may be called normally and use `yield` if desired.

All public methods are assumed to be callable from a client with `:ask`, except setters that are assumed to be called with `:tell`.

Here is a complete example of how to define a `Server` that can hold a value:

```ruby
class SharedObject < Ractor::Client
  class Server
    include Ractor::Server

    attr_accessor :value

    def initialize(value = nil)
      @value = value
    end

    def update
      @value = yield @value
    end
  end
end

LIST = ShareObject.new([1, 2])

Ractor.new do
  LIST.value # => [1, 2]
  LIST.value = [:changed]
end.take

LIST.value # => [:changed]
LIST.update do |cur|
  cur << :extra
end
LIST.value # => [:changed, :extra]
```

Note that `update` in the example above is atomic; if another Ractor calls `LIST.<anything>`, that request will wait until the `update` is completed. Nevertheless, calls issued from *inside* the `update` block will be processed synchroneously.

#### Defining classes

To create a `Server` class:

```ruby
class MyServer
  include Ractor::Server

  # define your methods...
end
```

This adds a few methods (`#main_loop`, `#receive_request` and `#process_request`)
as well as class methods `tells` (private).

This automatically defines a `Client` class and a `Client::ServerCallLayer` module; these may be subclassed/included if desired:

```ruby
class MyClient < MyServer::Client

  # special handling (if needed)
end
```

Note that subclass defines a method `initialize(...)` that:
* starts the server
* make itself shareable

An equivalent way to declare a Client is:

```ruby
class MyClient < Ractor::Client
  include MyServer::Client::ServerCallLayer

  # special handling (if needed)
end
```

#### Customizing the client

It may be necessary to customize the `Client` interface.

For example in the `SharedObject` example above, it may be more efficient if the shared object is always shareable. This can be done by customizing the client:

```ruby
class SharedObject
  # ... as above

  class Client # refine the client interface:
    def initialize(value = nil)
      Ractor.make_shareable(value)
      super
    end

    def update
      super { Ractor.make_shareable(yield) }
    end
  end
end
```

In this case, the `update` block above would raise a `FrozenError` and must be modified to a non-mutating form:

```ruby
LIST.update do |cur|
  cur + [:extra]
end
```

#### Customizing the sync

If we wanted to add a method `clear` to our server, there is no real need for the client to wait for the response as the result will not be useful. To specify that the method should be called with `:tell` instead of `:ask`, one may call `tells :clear`, or use the fact that `def` returns the method it defined:

```ruby
class SharedObject
  # ...

  tells def clear
    @value = nil
  end
end
```

## To do

* Exception rescuing and propagation
* API to pass block via makeshareable
* Monitoring
* Promise-style communication

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ractor-server'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install ractor-server

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/marcandre/ractor-server. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/marcandre/ractor-server/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Ractor::Server project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/marcandre/ractor-server/blob/master/CODE_OF_CONDUCT.md).
