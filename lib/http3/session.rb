# frozen_string_literal: true

module HTTP3
  # HTTP/3 on one QUIC connection. The C part (ext/http3/session.c) runs
  # nghttp3 inside the connection's packet I/O and calls the on_* methods
  # below with the parts of each request. This part puts the requests
  # together and keeps the bodies of the responses being sent.
  #
  # A Session belongs to the server's I/O loop: Server takes the finished
  # requests, answers them, keeps the bodies flowing and lets go of what
  # the streams no longer need.
  class Session
    # A request still coming in.
    Incoming = Struct.new(:pseudo, :fields, :body)

    # A response whose body is being sent.
    Outgoing = Struct.new(:request, :body, :done)

    # Take over quic_conn's streams. A request body over max_request_body
    # bytes is answered with 413, a header section over
    # max_field_section_size bytes (RFC 9114 section 4.2.2) with 431, as
    # soon as the request passes the limit; the rest of it is not read.
    def self.attach(quic_conn, max_request_body:, max_field_section_size:)
      session = _attach(quic_conn, max_field_section_size)
      session.send(:setup, max_request_body)
      session
    end

    # The requests received in full since the last call, each as
    # [request, status]: status is nil for the application to answer the
    # request, or the status to answer it with directly. A request answered
    # directly comes out as soon as it is refused, before the rest of it
    # has arrived, with neither headers nor body.
    def take_requests
      done = @done
      @done = []
      done
    end

    # Send response to request. Its body, if any, is kept until the stream
    # closes, but the IO of a Body::File is closed at once: the C part reads
    # the file through a descriptor of its own. When that descriptor cannot
    # be had (EMFILE, say), the stream is aborted with H3_INTERNAL_ERROR and
    # the block gets the exception. A request is answered once: nghttp3
    # would send a second response after the first, so it raises
    # Nghttp3::InvalidStateError.
    def respond(request, response)
      id = request.stream_id
      raise Nghttp3::InvalidStateError, "stream #{id} has been answered" if @answered[id]

      stop_reading(id) if @rejected[id]
      headers = [[":status", response.status.to_s], *response.headers]
      body = response.body
      submit_response(id, headers, !body.nil?)
      @answered[id] = true
      return if body.nil?

      @outgoing[id] = Outgoing.new(request, body, false)
      return unless body.is_a?(Body::File)

      begin
        attach_file(id, body.io, body.offset, body.length)
      rescue SystemCallError => e
        abort_stream(id, Nghttp3::H3_INTERNAL_ERROR)
        yield e if block_given?
      ensure
        body.io.close
      end
    end

    # Queue more of each Body::Chunks body until limit bytes wait unsent on
    # its stream. A body whose enum raises is the application failing after
    # its headers went out: the stream is aborted with H3_INTERNAL_ERROR and
    # the block gets (request, exception).
    def fill_bodies(limit)
      @outgoing.each_value do |out|
        next if out.done || !out.body.is_a?(Body::Chunks)

        fill_body(out, limit) { |error| yield out.request, error if block_given? }
      end
    end

    # True when a Body::Chunks body could take more right now.
    def wants_fill?(limit)
      @outgoing.any? do |id, out|
        !out.done && out.body.is_a?(Body::Chunks) && unsent_bytes(id) < limit
      end
    end

    # True while a request stream is open: received in part, waiting for
    # its answer, or with a response still being sent.
    def busy?
      !@open.empty?
    end

    # Let go of the streams nghttp3 closed: their requests are dropped and
    # their bodies closed. The block gets (stream_id, exception) for a body
    # whose close raised.
    def release_closed(&block)
      take_closed.each { |id| release(id, &block) }
    end

    # The connection is gone: close every body still held.
    def release_all(&block)
      (@open.keys | @outgoing.keys).each { |id| release(id, &block) }
    end

    # Called by the C part.

    def on_begin_headers(id)
      @open[id] = true
      @incoming[id] = Incoming.new([], [], "".b)
    end

    def on_header(id, name, value)
      request = @incoming[id] or return
      return if @rejected[id]

      (name.start_with?(":") ? request.pseudo : request.fields) << [name, value]
    end

    def on_fields_too_large(id)
      request = @incoming[id] or return
      return if @rejected[id]

      reject(id, request, 431)
    end

    def on_end_headers(id)
    end

    def on_data(id, bytes)
      request = @incoming[id] or return
      return if @rejected[id]

      if request.body.bytesize + bytes.bytesize > @max_request_body
        reject(id, request, 413)
      else
        request.body << bytes
      end
    end

    def on_end_stream(id)
      return if @rejected[id]

      request = @incoming.delete(id) or return
      headers = request.pseudo + request.fields
      @done << [Request.new(stream_id: id, headers: headers, body: request.body), nil]
    end

    private

    def setup(max_request_body)
      @max_request_body = max_request_body
      @incoming = {}
      @done = []
      @outgoing = {}
      @open = {}
      @rejected = {}
      @answered = {}
    end

    # Answer the request on id with status, at once, instead of passing it
    # on: what has come of it is dropped, and #respond stops reading the
    # rest. Its Incoming stays in @incoming, emptied, until the stream
    # closes, and the callbacks still to come for it are ignored. 431 may
    # come before all of the pseudo-headers, so the request goes out
    # without any headers. A refusal is not logged: only failures are, and
    # a flood of refusals would flood the log.
    def reject(id, request, status)
      request.pseudo.clear
      request.fields.clear
      request.body = "".b
      @rejected[id] = true
      @done << [Request.new(stream_id: id, headers: [], body: "".b), status]
    end

    def fill_body(out, limit)
      id = out.request.stream_id
      while unsent_bytes(id) < limit
        begin
          chunk = out.body.enum.next
        rescue StopIteration
          out.done = true
          push_eof(id)
          return
        rescue => e
          out.done = true
          abort_stream(id, Nghttp3::H3_INTERNAL_ERROR)
          yield e
          return
        end
        unless chunk.is_a?(String)
          out.done = true
          abort_stream(id, Nghttp3::H3_INTERNAL_ERROR)
          yield TypeError.new("body chunk must be a String (got #{chunk.class})")
          return
        end
        push_chunk(id, chunk)
      end
    rescue Nghttp3::Error
      # The stream went away under the body (the peer reset it); it is
      # released when its close comes through.
      out.done = true
    end

    def release(id)
      @open.delete(id)
      @incoming.delete(id)
      @rejected.delete(id)
      @answered.delete(id)
      @done.reject! { |request, _| request.stream_id == id }
      out = @outgoing.delete(id) or return

      close_body(out.body)
    rescue => e
      yield id, e if block_given?
    end

    def close_body(body)
      body.io.close if body.is_a?(Body::File) && !body.io.closed?
    ensure
      body.rack_body.close if body.rack_body.respond_to?(:close)
    end
  end
end
