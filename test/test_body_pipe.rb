# frozen_string_literal: true

require "test_helper"

# HTTP3::Body::Pipe between a writer thread and the thread that takes, as
# between a worker and the server's I/O loop.
class TestBodyPipe < Minitest::Test
  def setup
    @wakes = 0
    @threads = []
  end

  def teardown
    @threads.each(&:kill)
  end

  def test_stream_closed_is_an_io_error
    assert_operator HTTP3::StreamClosed, :<, IOError
  end

  def test_write_waits_while_the_pipe_holds_capacity
    pipe = new_pipe(capacity: 10)
    assert_equal 10, pipe.write("x" * 10)
    writer = start { pipe.write("y") }
    assert_waiting writer
    assert_equal "x" * 10, pipe.take
    assert_equal 1, writer.value
    assert_equal "y", pipe.take
  end

  # Below capacity a write goes in whole, however large.
  def test_write_below_capacity_does_not_wait
    pipe = new_pipe(capacity: 10)
    pipe.write("x" * 9)
    pipe.write("y" * 100)
    assert_equal ["x" * 9, "y" * 100], [pipe.take, pipe.take]
  end

  def test_write_copies_a_string_that_can_change
    pipe = new_pipe
    chunk = +"abc"
    pipe.write(chunk)
    chunk << "d"
    assert_equal "abc", pipe.take
  end

  def test_finish_waits_until_everything_is_taken
    pipe = new_pipe
    pipe.write("a")
    finisher = start { pipe.finish }
    assert_waiting finisher
    assert_equal "a", pipe.take
    assert_waiting finisher
    assert_equal :eof, pipe.take
    assert_nil finisher.value
    assert_equal :eof, pipe.take
  end

  def test_flush_waits_until_the_chunks_are_taken
    pipe = new_pipe
    pipe.write("a")
    flusher = start { pipe.flush }
    assert_waiting flusher
    assert_equal "a", pipe.take
    assert_same pipe, flusher.value
  end

  # fail, the writer's last call, returns without raising.
  def test_cancel_wakes_the_waiters_with_stream_closed
    full = new_pipe(capacity: 1)
    full.write("x")
    writer = start { full.write("y") }
    flusher = start { full.flush }
    ended = new_pipe
    ended.write("z")
    finisher = start { ended.finish }
    failed = new_pipe
    failed.write("z")
    failer = start { failed.fail(RuntimeError.new("x")) }
    [writer, flusher, finisher, failer].each { |thread| assert_waiting thread }
    [full, ended, failed].each(&:cancel)
    [writer, flusher, finisher].each do |thread|
      assert_raises(HTTP3::StreamClosed) { thread.value }
    end
    assert_nil failer.value
  end

  def test_calls_after_cancel_raise_stream_closed
    pipe = new_pipe
    pipe.write("a")
    pipe.cancel
    assert_raises(HTTP3::StreamClosed) { pipe.write("b") }
    assert_raises(HTTP3::StreamClosed) { pipe.write("") }
    assert_raises(HTTP3::StreamClosed) { pipe.flush }
    assert_raises(HTTP3::StreamClosed) { pipe.finish }
    assert_nil pipe.fail(RuntimeError.new("too late"))
    assert_nil pipe.take
    refute pipe.ready?
  end

  # What was written before fail is taken first, then the exception, and
  # fail waits until it has been.
  def test_take_returns_the_exception_of_fail_after_the_chunks
    pipe = new_pipe
    pipe.write("a")
    error = RuntimeError.new("body failed")
    failer = start { pipe.fail(error) }
    assert_waiting failer
    assert_equal "a", pipe.take
    assert pipe.ready?
    assert_same error, pipe.take
    assert_nil failer.value
    refute pipe.ready?
    assert_raises(IOError) { pipe.write("b") }
  end

  def test_writing_after_finish_raises
    pipe = new_pipe
    start { pipe.finish }
    assert_equal :eof, take_eventually(pipe)
    assert_raises(IOError) { pipe.write("a") }
  end

  def test_ready
    pipe = new_pipe
    refute pipe.ready?
    pipe.write("a")
    assert pipe.ready?
    pipe.take
    refute pipe.ready?
    start { pipe.finish }
    eventually { assert pipe.ready? }
    assert_equal :eof, pipe.take
    refute pipe.ready?
  end

  # The lock is let go before wake: a wake that takes does not deadlock.
  def test_wake_comes_outside_the_lock
    taken = []
    taking = nil
    taking = HTTP3::Body::Pipe.new(capacity: 100, wake: -> { taken << taking.take })
    taking.write("a")
    assert_equal ["a"], taken
  end

  # A write, and the end, wake only a pipe that had nothing to take.
  def test_wake_comes_when_there_is_something_to_take
    pipe = new_pipe
    pipe.write("a")
    pipe.write("b")
    assert_equal 1, @wakes
    pipe.take
    pipe.take
    pipe.write("c")
    assert_equal 2, @wakes
    failer = start { pipe.fail(RuntimeError.new("x")) }
    assert_waiting failer
    assert_equal 2, @wakes, "the pipe held a chunk already"
    assert_equal "c", pipe.take
    assert_kind_of RuntimeError, pipe.take
    assert_nil failer.value
  end

  def test_the_end_wakes_an_empty_pipe
    finished = new_pipe
    start { finished.finish }
    eventually { assert_equal 1, @wakes }
    failed = new_pipe
    start { failed.fail(RuntimeError.new("x")) }
    eventually { assert_equal 2, @wakes }
  end

  private

  def new_pipe(capacity: 100)
    HTTP3::Body::Pipe.new(capacity: capacity, wake: -> { @wakes += 1 })
  end

  def start(&block)
    Thread.new(&block).tap do |thread|
      thread.report_on_exception = false
      @threads << thread
    end
  end

  # The thread waits, on the pipe: it goes to sleep, and stays asleep a
  # while.
  def assert_waiting(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until thread.status == "sleep"
      flunk "the thread should be waiting" if !thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    assert_nil thread.join(0.05), "the thread should be waiting"
  end

  def take_eventually(pipe)
    taken = nil
    eventually { refute_nil(taken = pipe.take) }
    taken
  end

  def eventually(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    begin
      yield
    rescue Minitest::Assertion
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
      retry
    end
  end
end
