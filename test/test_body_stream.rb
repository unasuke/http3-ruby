# frozen_string_literal: true

require "test_helper"
require "rack/lint"
require "stringio"

# HTTP3::Body::Stream, the stream a streaming body is called with, on a
# real Body::Pipe whose other end the test takes, as the server's I/O loop
# would.
class TestBodyStream < Minitest::Test
  def setup
    @threads = []
    @input = StringIO.new("request body".b)
    @pipe = HTTP3::Body::Pipe.new(capacity: 100, wake: -> {})
  end

  # A thread is stopped, and waited for, so that it cannot be stopped
  # inside the pipe's lock as the next test starts. join raises what the
  # thread ended with, which its test has looked at.
  def teardown
    @threads.each do |thread|
      thread.kill.join(1)
    rescue Exception # rubocop:disable Lint/RescueException
      nil
    end
  end

  # Rack::Lint checks that the stream has the methods Rack 3 asks for.
  def test_rack_lint_takes_it
    Rack::Lint::Wrapper::StreamWrapper.new(new_stream)
  end

  # write takes any objects, as IO#write does, and returns the bytes
  # written; << returns the stream.
  def test_write_goes_to_the_pipe
    stream = new_stream
    assert_equal 5, stream.write("ab", 1, :cd)
    assert_equal 0, stream.write
    assert_same stream, stream << "e"
    assert_equal ["ab", "1", "cd", "e"], Array.new(4) { @pipe.take }
  end

  def test_write_waits_while_the_pipe_is_full
    pipe = HTTP3::Body::Pipe.new(capacity: 2, wake: -> {})
    stream = new_stream(pipe: pipe)
    stream.write("ab")
    writer = start { stream.write("c") }
    assert_waiting writer
    assert_equal "ab", pipe.take
    assert_equal 1, writer.value
  end

  def test_flush_waits_until_the_pipe_is_taken
    stream = new_stream
    stream.write("a")
    flusher = start { stream.flush }
    assert_waiting flusher
    assert_equal "a", @pipe.take
    assert_same stream, flusher.value
  end

  def test_read_reads_the_request_body
    stream = new_stream
    assert_equal "requ", stream.read(4)
    assert_equal "est body", stream.read
  end

  # close_write ends the body, and waits until all of it has been taken.
  def test_close_write_finishes_the_pipe
    stream = new_stream
    stream.write("a")
    closer = start { stream.close_write }
    assert_waiting closer
    assert_equal ["a", :eof], [@pipe.take, take_eventually]
    assert_nil closer.value
  end

  # As on an IO: the closes may be called again, and writing, flushing or
  # reading after them raises IOError.
  def test_closes_are_idempotent_and_end_their_side
    stream = new_stream
    closer = start { stream.close_write }
    assert_equal :eof, take_eventually
    assert_nil closer.value
    assert_nil stream.close_write
    refute_predicate stream, :closed?
    assert_equal "request body", stream.read
    error = assert_raises(IOError) { stream.write("a") }
    assert_equal "not opened for writing", error.message
    assert_raises(IOError) { stream.flush }
    stream.close_read
    assert_nil stream.close_read
    assert_predicate @input, :closed?
    assert_predicate stream, :closed?
    error = assert_raises(IOError) { stream.read }
    assert_equal "not opened for reading", error.message
    assert_nil stream.close
  end

  # close closes both sides; a request body the application closed itself
  # is left as it is.
  def test_close_closes_both_sides
    stream = new_stream
    @input.close
    closer = start { stream.close }
    assert_equal :eof, take_eventually
    assert_nil closer.value
    assert_predicate stream, :closed?
  end

  def test_body_of_content_length_finishes
    stream = new_stream(length: 4)
    stream.write("ab", "cd")
    closer = start { stream.close_write }
    assert_equal ["ab", "cd", :eof], [@pipe.take, @pipe.take, take_eventually]
    assert_nil closer.value
  end

  # content-length counts bytes, not characters.
  def test_content_length_counts_bytes
    stream = new_stream(length: 1)
    writer = start { stream.write("\u00e9") }
    error = take_eventually
    assert_kind_of HTTP3::RackAdapter::InvalidResponse, error
    assert_equal "the body is at least 2 bytes but content-length says otherwise", error.message
    assert_raises(HTTP3::StreamClosed) { writer.value }
  end

  # A body short of content-length fails the pipe when it ends, and is
  # aborted rather than ended.
  def test_body_short_of_content_length_fails_the_pipe
    stream = new_stream(length: 5)
    stream.write("abcd")
    closer = start { stream.close_write }
    assert_equal "abcd", @pipe.take
    error = take_eventually
    assert_kind_of HTTP3::RackAdapter::InvalidResponse, error
    assert_equal "the body is 4 bytes but content-length says otherwise", error.message
    assert_nil closer.value
  end

  # The write that takes the body past content-length fails the pipe, and
  # raises StreamClosed, as do the writes after it; the body is not ended.
  def test_writing_past_content_length_fails_the_pipe
    stream = new_stream(length: 3)
    stream.write("ab")
    writer = start { stream.write("cd") }
    assert_equal "ab", @pipe.take
    error = take_eventually
    assert_kind_of HTTP3::RackAdapter::InvalidResponse, error
    assert_equal "the body is at least 4 bytes but content-length says otherwise", error.message
    assert_raises(HTTP3::StreamClosed) { writer.value }
    assert_raises(HTTP3::StreamClosed) { stream.write("e") }
    assert_raises(HTTP3::StreamClosed) { stream.flush }
    assert_nil stream.close_write
    assert_kind_of HTTP3::RackAdapter::InvalidResponse, @pipe.take, "the body should not have ended"
  end

  # Once the server has given up on the stream, write and flush raise
  # StreamClosed, and so does the close that would end it, once.
  def test_writes_after_cancel_raise_stream_closed
    stream = new_stream
    @pipe.cancel
    assert_raises(HTTP3::StreamClosed) { stream.write("a") }
    assert_raises(HTTP3::StreamClosed) { stream.flush }
    assert_raises(HTTP3::StreamClosed) { stream.close }
    assert_predicate @input, :closed?
    assert_nil stream.close
  end

  private

  def new_stream(pipe: @pipe, length: nil)
    HTTP3::Body::Stream.new(pipe: pipe, input: @input, length: length)
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

  # What the pipe gives next, once it has something.
  def take_eventually
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until (taken = @pipe.take)
      flunk "the pipe gave nothing" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
    taken
  end
end
