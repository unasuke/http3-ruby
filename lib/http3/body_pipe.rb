# frozen_string_literal: true

module HTTP3
  # The stream a response was being sent on is gone: the client reset it,
  # the connection ended, or the server stopped. Body::Pipe's write, finish
  # and flush raise it. It is an IOError, as a write to a closed socket
  # raises one.
  class StreamClosed < IOError
  end

  module Body
    # A response body written by the thread that runs the application and
    # taken by the server's I/O loop, which sends it. On the writer's side,
    # #write waits while capacity bytes or more are queued, and #finish ends
    # the body, #fail ends it with an exception, each waiting until all of
    # it has been taken. On the I/O loop's side, #take never waits, and
    # #cancel gives up on the body: from then on the writer's write, finish
    # and flush raise StreamClosed, those waiting included, and fail
    # returns. Since a writer waits for the
    # end of its body to be taken, the pipes holding chunks are no more than
    # the writers.
    #
    # wake is called, with no lock held, each time the body goes from
    # having nothing to take to having something: a chunk, its end, or the
    # exception that ended it.
    class Pipe
      def initialize(capacity:, wake:)
        @capacity = capacity
        @wake = wake
        @lock = Thread::Mutex.new
        @changed = Thread::ConditionVariable.new
        @chunks = []
        @bytes = 0
        @finished = false
        @end_taken = false
        @error = nil
        @cancelled = false
      end

      # Queue chunk, a String, first waiting while capacity bytes or more are
      # queued. A String that can still change is copied. Returns its size.
      def write(chunk)
        raise TypeError, "chunk must be a String (got #{chunk.class})" unless chunk.is_a?(String)

        chunk = chunk.dup.freeze unless chunk.frozen?
        woke = @lock.synchronize do
          @changed.wait(@lock) while @bytes >= @capacity && !@cancelled
          check_writable
          next false if chunk.empty?

          was_empty = @chunks.empty?
          @chunks << chunk
          @bytes += chunk.bytesize
          was_empty
        end
        @wake.call if woke
        chunk.bytesize
      end

      # End the body, and wait until the I/O loop has taken all of it, its
      # end included.
      def finish
        woke = @lock.synchronize do
          check_writable
          @finished = true
          @chunks.empty?
        end
        @wake.call if woke
        @lock.synchronize do
          wait_for_the_end
          raise StreamClosed, "stream closed" unless @end_taken
        end
        nil
      end

      # End the body with error, for the I/O loop to abort the stream once
      # it has taken what is queued, and wait until it has. Does nothing
      # once the body has ended or been given up on.
      def fail(error)
        woke = @lock.synchronize do
          next nil if @cancelled || @finished || @error

          @error = error
          @chunks.empty?
        end
        return nil if woke.nil?

        @wake.call if woke
        @lock.synchronize { wait_for_the_end }
        nil
      end

      # Wait until the I/O loop has taken every chunk queued.
      def flush
        @lock.synchronize do
          @changed.wait(@lock) until @chunks.empty? || @cancelled
          raise StreamClosed, "stream closed" if @cancelled
        end
        self
      end

      # The next of what the writer queued, without waiting: a chunk; once
      # they have all been taken, :eof for a body that ended, or the
      # exception given to #fail; nil while there is nothing yet, and after
      # #cancel.
      def take
        @lock.synchronize do
          return nil if @cancelled

          if (chunk = @chunks.shift)
            @bytes -= chunk.bytesize
            @changed.broadcast
            return chunk
          end
          return nil unless @finished || @error

          @end_taken = true
          @changed.broadcast
          @error || :eof
        end
      end

      # True when #take has something new to return: a chunk, or the end.
      def ready?
        @lock.synchronize do
          !@cancelled && (!@chunks.empty? || ((@finished || !@error.nil?) && !@end_taken))
        end
      end

      # Give up on the body: what is queued is dropped, and the writer's
      # calls, those waiting included, raise StreamClosed.
      def cancel
        @lock.synchronize do
          @cancelled = true
          @chunks.clear
          @bytes = 0
          @changed.broadcast
        end
        nil
      end

      private

      # With the lock held.
      def wait_for_the_end
        @changed.wait(@lock) until @end_taken || @cancelled
      end

      def check_writable
        raise StreamClosed, "stream closed" if @cancelled
        raise IOError, "body already ended" if @finished || @error
      end
    end
  end
end
