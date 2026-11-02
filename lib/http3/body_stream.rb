# frozen_string_literal: true

module HTTP3
  module Body
    # The stream a streaming body (Rack 3's call(stream)) is called with.
    # What it writes goes to a Body::Pipe, and what it reads comes from the
    # request body, which has arrived in full. Its methods behave as IO's
    # do, as Rack 3 asks: write takes any objects and returns the bytes
    # written, a write or flush after close_write raises IOError, as a read
    # after close_read does, and the closes may be called again.
    #
    # Once the stream has gone away (the client reset it, or it was aborted
    # after response_timeout), write and flush raise StreamClosed, and so
    # do close_write and close, once. Writing past length, the
    # content-length, fails the pipe, so that the stream is aborted, and
    # raises StreamClosed, so that the body stops there; ending short of it
    # fails the pipe too.
    class Stream
      def initialize(pipe:, input:, length:)
        @pipe = pipe
        @input = input
        @length = length
        @size = 0
        @failed = false
        @read_closed = false
        @write_closed = false
        @lock = Thread::Mutex.new
      end

      # Read from the request body, as IO#read does.
      def read(...)
        raise IOError, "not opened for reading" if @read_closed

        @input.read(...)
      end

      # Write each of objects, as a String (to_s), first waiting while the
      # pipe is full. Returns the bytes written.
      def write(*objects)
        @lock.synchronize do
          objects.sum do |object|
            chunk = object.to_s
            check_writable
            count(chunk.bytesize)
            @pipe.write(chunk)
          end
        end
      end

      def <<(object)
        write(object)
        self
      end

      # Wait until what has been written has been taken to be sent.
      def flush
        @lock.synchronize { check_writable }
        @pipe.flush
        self
      end

      # Stop reading: close the request body, unless it is closed already.
      def close_read
        @read_closed = true
        @input.close unless @input.closed?
        nil
      end

      # End the body, and wait until all of it has been taken to be sent;
      # fail the pipe instead if it is short of length.
      def close_write
        @lock.synchronize do
          next if @write_closed

          @write_closed = true
          next if @failed

          if @length && @size != @length
            @pipe.fail(length_mismatch("the body is #{@size} bytes"))
          else
            @pipe.finish
          end
        end
        nil
      end

      def close
        close_read
        close_write
      end

      def closed?
        @read_closed && @write_closed
      end

      private

      # With the lock held.
      def check_writable
        raise IOError, "not opened for writing" if @write_closed
        raise StreamClosed, "stream closed" if @failed
      end

      # With the lock held. Past length, the pipe fails and StreamClosed is
      # raised.
      def count(bytes)
        @size += bytes
        return unless @length && @size > @length

        @failed = true
        @pipe.fail(length_mismatch("the body is at least #{@size} bytes"))
        raise StreamClosed, "stream closed"
      end

      def length_mismatch(what)
        RackAdapter::InvalidResponse.new("#{what} but content-length says otherwise")
      end
    end
  end
end
