require 'minitest/autorun'
require 'spec_helper'

describe Stripe::Callbacks do
  include Rack::Test::Methods
  include CallbackHelpers

  let(:app) { Rails.application }
  let(:observer) do
    Class.new.tap do |cls|
      cls.class_eval do
        include Stripe::Callbacks
      end
    end
  end

  before do
    header 'Accept', 'application/json'
    header 'Content-Type', 'application/json'

    event                   = JSON.parse(File.read File.expand_path('../event.json', __FILE__))
    invoice                 = JSON.parse(File.read File.expand_path('../invoice.json', __FILE__))
    event['data']['object'] = invoice

    @content = event
    self.type = @content['type']
  end

  after { ::Stripe::Callbacks.clear_callbacks! }

  describe 'when there are eager loaded callbacks in the configuration (config/environment/test.rb)' do
    it 'should be eager loaded' do
      Dummy.const_defined?(:ModelWithCallbacks).must_equal true
      Dummy.const_defined?(:ModuleWithCallbacks).must_equal true
    end
  end

  describe 'the ping interface' do
    subject { get '/stripe/ping' }

    it { subject.must_be :ok? }
  end

  describe 'defined with a bang' do
    let(:callback) { :after_invoice_payment_succeeded! }

    describe 'when it is invoked for the invoice.payment_succeeded event' do
      before  { run_callback_with(callback) {|target, e| @event = e; @target = target} }
      subject { post 'stripe/events', JSON.pretty_generate(@content) }

      it 'is invoked for the invoice.payment_succeeded event' do
        subject
        @event.wont_be_nil
        @event.type.must_equal 'invoice.payment_succeeded'
        @target.total.must_equal 6999
      end
    end

    describe 'when the invoked.payment_failed webhook is called' do
      before do
        run_callback_with(callback) { fail }
        self.type = 'invoked.payment_failed'
      end
      subject { post 'stripe/events/', JSON.pretty_generate(@content) }

      it 'the invoice.payment_succeeded callback is not invoked' do
        subject # won't raise RuntimeError
      end
    end

    describe 'if it raises an exception' do
      before  { run_callback_with(callback) { fail } }
      subject { post 'stripe/events', JSON.pretty_generate(@content) }

      it 'causes the whole webhook to fail' do
        ->{ subject }.must_raise RuntimeError
      end
    end
  end

  describe 'defined without a bang and raising an exception' do
    let(:callback) { :after_invoice_payment_succeeded }
    before { run_callback_with(callback) { fail } }

    it 'does not cause the webhook to fail' do
      post 'stripe/events', JSON.pretty_generate(@content)
      last_response.status.must_be :>=, 200
      last_response.status.must_be :<, 300
    end
  end

  describe 'the after_stripe_event callback to catch any event' do
    let(:events) { [] }
    before  { run_callback_with(:after_stripe_event) { |_, evt| events << evt } }
    subject { post 'stripe/events/', JSON.pretty_generate(@content) }

    describe 'when it gets invoked for a standard event' do
      before  { self.type = 'invoice.payment_failed' }

      it 'it will be run' do
        subject
        events.first.type.must_equal 'invoice.payment_failed'
      end
    end

    describe 'when it gets invoked for an arbitrary event' do
      before  { self.type = 'foo.bar.baz' }

      it 'it will be run' do
        subject
        events.first.type.must_equal 'foo.bar.baz'
      end
    end
  end

  describe 'filtering on specific changed attributes' do
    events = nil
    before do
      events = []
      self.type = 'invoice.updated'
      @stubbed_event.data.previous_attributes = {}
    end
    subject { post 'stripe/events', JSON.pretty_generate(@content) }

    describe 'specified as an single symbol' do
      before do
        observer.class_eval do
          after_invoice_updated! :only => :closed do |invoice, evt|
            events << evt
          end
        end
      end

      describe 'when a prior attribute was not specified' do
        it 'does not fire events' do
          subject
          events.length.must_equal 0
        end
      end

      describe 'when a prior attribute was specified' do
        before { @stubbed_event.data.previous_attributes['closed'] = true }
        it 'fires events' do
          subject
          events.length.must_equal 1
        end
      end
    end

    describe 'specified as an array' do
      before do
        observer.class_eval do
          after_invoice_updated! :only => [:currency, :subtotal] do |invoice, evt|
            events << evt
          end
        end
      end

      describe 'when a prior attribute was not specified' do
        it 'does not fire events' do
          subject
          events.length.must_equal 0
        end
      end

      describe 'when prior attributes were specified' do
        before { @stubbed_event.data.previous_attributes['subtotal'] = 699 }
        it 'fire events' do
          subject
          events.length.must_equal 1
        end
      end
    end

    describe 'specified as a lambda' do
      before do
        observer.class_eval do
          after_invoice_updated :only => proc {|target, evt| evt.data.previous_attributes.to_hash.has_key? :closed} do |i,e|
            events << e
          end
        end
      end

      describe 'when the lambda is not true' do
        it 'does not fire events' do
          subject
          events.length.must_equal 0
        end
      end

      describe 'when the lambda is not true' do
        before { @stubbed_event.data.previous_attributes['closed'] = 'false' }
        it 'fires events' do
          subject
          events.length.must_equal 1
        end
      end
    end
  end
end