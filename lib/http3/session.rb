# frozen_string_literal: true

require "stringio"
require "tempfile"
require "tmpdir"

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
    # A request still coming in; started is when its headers began
    # (CLOCK_MONOTONIC). body is a StringIO, or a File once the body has
    # gone past request_body_buffer_size (#spool); received is how many
    # bytes of body have come.
    Incoming = Struct.new(:pseudo, :fields, :body, :started, :received)

    # A response whose body is being sent.
    Outgoing = Struct.new(:request, :body, :done)

    # What a field counts for besides its name and value, as RFC 9114
    # section 4.2.2 counts it, and as the C part does for 431.
    FIELD_OVERHEAD = 32

    # Bytes the requests coming in may hold: a connection's, and through
    # parent the server's. Only the server's I/O loop, one thread, calls
    # it, so it takes no lock.
    class Budget
      attr_reader :limit, :used

      def initialize(limit, parent: nil)
        @limit = limit
        @used = 0
        @parent = parent
      end

      # Count n bytes and return true if they fit both here and in the
      # parent; count nothing and return false if not.
      def reserve(n)
        return false if @used + n > @limit
        return false if @parent && !@parent.reserve(n)

        @used += n
        true
      end

      def release(n)
        @used -= n
        @parent&.release(n)
      end
    end
    private_constant :Budget

    # The limits on what the requests of a connection, and through their
    # parents the server's, hold in temporary files: bytes, and files open
    # at once.
    Spool = Struct.new(:bytes, :files)
    private_constant :Spool

    # Take over quic_conn's streams. A request body over max_request_body
    # bytes is answered with 413, a header section over
    # max_field_section_size bytes (RFC 9114 section 4.2.2) with 431, as
    # soon as the request passes the limit; the rest of it is not read.
    #
    # A request body is kept in memory up to request_body_buffer_size
    # bytes; past that, all of it goes to a temporary file
    # (Session.spool_file).
    #
    # The requests not yet handed out (#next_request) may hold
    # max_connection_request_buffer bytes of memory in all, header fields
    # counted as for 431 and bodies by their bytes, and those of every
    # Session given the same shared_buffer (Session.shared_buffer) its
    # limit. The requests whose temporary files are open may hold
    # max_connection_request_spool bytes in them, and
    # max_connection_request_spool_files of them, and those of every
    # Session given the same shared_spool (Session.shared_spool) its
    # limits; a file stays open until the response body is done (see
    # #next_request). A request that would pass any of these limits, or
    # whose file cannot be made or written, is answered with 503.
    #
    # A request not received in full within request_timeout seconds of the
    # start of its headers is answered with 408 (#expire_requests); nil is
    # no limit.
    def self.attach(quic_conn, max_request_body:, max_field_section_size:,
      max_connection_request_buffer: 4_194_304, shared_buffer: nil, request_timeout: nil,
      request_body_buffer_size: 65_536, max_connection_request_spool: 16_777_216,
      max_connection_request_spool_files: 16, shared_spool: nil)
      session = _attach(quic_conn, max_field_section_size)
      spool = Spool.new(Budget.new(max_connection_request_spool, parent: shared_spool&.bytes),
        Budget.new(max_connection_request_spool_files, parent: shared_spool&.files))
      session.send(:setup, max_request_body, Budget.new(max_connection_request_buffer, parent: shared_buffer),
        request_timeout, request_body_buffer_size, spool)
      session
    end

    # A limit of limit bytes for the requests coming in on every Session
    # given it as attach's shared_buffer.
    def self.shared_buffer(limit)
      Budget.new(limit)
    end

    # Limits of limit bytes in temporary files, and of files open at once,
    # for the requests on every Session given it as attach's shared_spool.
    def self.shared_spool(limit, files:)
      Spool.new(Budget.new(limit), Budget.new(files))
    end

    # A temporary file in Dir.tmpdir for a request body, without a name and
    # in binary mode. O_TMPFILE makes it without one; where the file system
    # does not take that (overlayfs, NFS), a file made with a random name is
    # unlinked at once. Raises SystemCallError when no file can be had.
    def self.spool_file
      dir = Dir.tmpdir
      file = begin
        File.open(dir, File::RDWR | File::TMPFILE, 0o600)
      rescue Errno::EOPNOTSUPP, Errno::EISDIR, Errno::EINVAL
        named = Tempfile.create(["http3-body-", ""], dir)
        begin
          File.unlink(named.path)
        rescue SystemCallError
          named.close
          raise
        end
        named
      end
      # File::BINARY is 0 on Linux: only binmode makes the file ASCII-8BIT.
      file.binmode
      file
    end

    # The requests refused since the last call, each as [request, status]:
    # the status (408, 413, 431, 503) to answer it with directly. A request
    # comes out as soon as it is refused, before the rest of it has arrived,
    # with neither headers nor body.
    def take_refusals
      refused = @refused
      @refused = []
      refused
    end

    # The next request received in full, for the application to answer, or
    # nil. The bytes it held in memory no longer count for the limits.
    #
    # Its temporary file, if it has one, stays open, and counts for the
    # spool's limits with its bytes, until its response body is done: once
    # #respond returns for a response without a body or with a Body::File,
    # once #fill_bodies has queued all of a Body::Chunks body, or when its
    # stream closes. The application, or a body that reads rack.input as it
    # goes, may read it until then. It is closed then, unless it is closed
    # already.
    def next_request
      request = @ready.shift or return nil
      release_held(request.stream_id)
      request
    end

    # True while the request on stream_id can still be answered: its stream
    # is open, the client has not reset it, it has not been refused, and it
    # has not been answered.
    def answerable?(stream_id)
      @open.key?(stream_id) && !@reset[stream_id] && !@rejected[stream_id] && !@answered[stream_id]
    end

    # The first exception a temporary file raised since the last call, or
    # nil. The request it was for has been answered with 503.
    def take_spool_error
      error = @spool_error
      @spool_error = nil
      error
    end

    # Refuse with 408 the requests still coming in whose request_timeout
    # has passed at now (CLOCK_MONOTONIC); #take_refusals hands them out.
    def expire_requests(now)
      return if @request_timeout.nil?

      @incoming.each do |id, request|
        next if @rejected[id] || request.started + @request_timeout > now

        reject(id, request, 408)
      end
    end

    # When the next request still coming in runs out of time
    # (CLOCK_MONOTONIC), or nil.
    def next_request_deadline
      return nil if @request_timeout.nil?

      started = @incoming.filter_map { |id, request| request.started unless @rejected[id] }.min
      started && started + @request_timeout
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
      if body.nil?
        finish_input(id)
        return
      end

      # Only the pseudo-headers stay, for the log, while the body is sent:
      # the request body would otherwise be held all along, uncounted.
      pseudo = request.headers.select { |name, _| name.start_with?(":") }
      @outgoing[id] = Outgoing.new(Request.new(stream_id: id, headers: pseudo, input: empty_input), body, false)
      return unless body.is_a?(Body::File)

      begin
        attach_file(id, body.io, body.offset, body.length)
      rescue SystemCallError => e
        abort_stream(id, Nghttp3::H3_INTERNAL_ERROR)
        yield e if block_given?
      ensure
        body.io.close
        finish_input(id)
      end
    end

    # Queue more of each Body::Chunks body until limit bytes wait unsent on
    # its stream, connection_limit on the whole connection (#unsent_total),
    # and room more bytes have been queued; nil is no limit. A chunk may
    # take any of them past its limit, by less than its size. Returns the
    # bytes queued.
    #
    # A body whose enum raises is the application failing after its headers
    # went out: the stream is aborted with H3_INTERNAL_ERROR and the block
    # gets (request, exception). That request has only the pseudo-headers,
    # and no body.
    def fill_bodies(limit, connection_limit: nil, room: nil)
      left = [room, connection_limit && connection_limit - unsent_total].compact.min
      queued = 0
      @outgoing.each_value do |out|
        next if out.done || !out.body.is_a?(Body::Chunks)
        break if left && queued >= left

        queued += fill_body(out, limit, left && left - queued) { |error| yield out.request, error if block_given? }
        finish_input(out.request.stream_id) if out.done
      end
      queued
    end

    # True when a Body::Chunks body could take more right now, with the
    # limits of #fill_bodies.
    def wants_fill?(limit, connection_limit: nil, room: nil)
      return false if room && room <= 0
      return false if connection_limit && unsent_total >= connection_limit

      @outgoing.any? do |id, out|
        !out.done && out.body.is_a?(Body::Chunks) && unsent_bytes(id) < limit
      end
    end

    # Bytes of the Body::Chunks bodies queued but not taken by nghttp3 yet,
    # on every stream; a body that has ended may still have some.
    def unsent_total
      @outgoing.sum { |id, out| out.body.is_a?(Body::Chunks) ? unsent_bytes(id) : 0 }
    end

    # True while a request stream is open: received in part, waiting for
    # its answer, or with a response still being sent.
    def busy?
      !@open.empty?
    end

    # Let go of the streams nghttp3 closed: their requests are dropped and
    # their bodies closed. The block gets (stream_id, exception) for a body
    # whose close raised. First, the requests the client reset before their
    # end (#on_reset) get our side of their streams reset too, with
    # H3_REQUEST_INCOMPLETE as RFC 9114 section 4.1 says, so that the
    # streams close.
    def release_closed(&block)
      @incomplete.each { |id| abort_stream(id, Nghttp3::H3_REQUEST_INCOMPLETE) }
      @incomplete.clear
      take_closed.each { |id| release(id, &block) }
    end

    # The connection is gone: close every body still held.
    def release_all(&block)
      (@open.keys | @outgoing.keys).each { |id| release(id, &block) }
    end

    # Called by the C part.

    def on_begin_headers(id)
      @open[id] = true
      @incoming[id] = Incoming.new([], [], empty_input, Process.clock_gettime(Process::CLOCK_MONOTONIC), 0)
    end

    def on_header(id, name, value)
      request = @incoming[id] or return
      return if @rejected[id]
      return reject(id, request, 503) unless hold(id, name.bytesize + value.bytesize + FIELD_OVERHEAD)

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

      if request.received + bytes.bytesize > @max_request_body
        reject(id, request, 413)
      elsif @spool_files.key?(id) || request.received + bytes.bytesize > @request_body_buffer_size
        spool(id, request, bytes)
      elsif !hold(id, bytes.bytesize)
        reject(id, request, 503)
      else
        request.body.write(bytes)
        request.received += bytes.bytesize
      end
    end

    def on_end_stream(id)
      return if @rejected[id]

      request = @incoming[id] or return
      input = request.body
      begin
        input.flush
        input.rewind
      rescue => e
        @spool_error ||= e
        return reject(id, request, 503)
      end
      @incoming.delete(id)
      @spool_inputs[id] = input if input.is_a?(File)
      headers = request.pseudo + request.fields
      @ready << Request.new(stream_id: id, headers: headers, input: input)
    end

    # The client reset its side of the stream, and the request is no longer
    # #answerable?. A request it had not finished is dropped with the bytes
    # it held, and #release_closed resets our side; one received in full,
    # or refused, is answered as it would have been. Inside a callback, so
    # it calls no C.
    def on_reset(id)
      @reset[id] = true if @open.key?(id)
      return unless @incoming.key?(id) && !@rejected[id]

      request = @incoming.delete(id)
      close_input(request.body)
      release_held(id)
      release_spooled(id)
      release_spool_file(id)
      @incomplete << id
    end

    private

    def setup(max_request_body, budget, request_timeout, request_body_buffer_size, spool)
      @max_request_body = max_request_body
      @budget = budget
      @request_timeout = request_timeout
      @request_body_buffer_size = request_body_buffer_size
      @spool = spool
      @held = {}
      # stream_id => bytes of the request's body counted in @spool.bytes,
      # until its file is closed
      @spooled = {}
      # stream_id => true for a request whose file counts in @spool.files
      @spool_files = {}
      # stream_id => the temporary file of a request handed out, until its
      # response body is done
      @spool_inputs = {}
      @spool_error = nil
      @incoming = {}
      # [request, status] of the requests refused, until #take_refusals
      @refused = []
      # The requests received in full, until #next_request
      @ready = []
      @outgoing = {}
      @open = {}
      # stream_id => true for a stream the client has reset
      @reset = {}
      @rejected = {}
      @answered = {}
      @incomplete = []
    end

    # Count n more bytes for the request on id, if the budget has room.
    def hold(id, n)
      return false unless @budget.reserve(n)

      @held[id] = @held.fetch(id, 0) + n
      true
    end

    # The request on id holds nothing any more. Calling it again does
    # nothing.
    def release_held(id)
      n = @held.delete(id) or return
      @budget.release(n)
    end

    # Write bytes to the temporary file of the request on id, making it
    # first if it has none: what the request has in memory goes to the
    # file, and from the memory budget to the spool's. The request is
    # answered with 503 if the spool limits have no room for it, or if its
    # file cannot be made or written; the exception then waits for
    # #take_spool_error. Inside a callback, so it lets nothing out.
    def spool(id, request, bytes)
      unless @spool_files.key?(id)
        return reject(id, request, 503) unless @spool.files.reserve(1)

        @spool_files[id] = true
        in_memory = request.received
        return reject(id, request, 503) unless reserve_spooled(id, in_memory)

        file = open_spool
        begin
          file.write(request.body.string)
        rescue
          close_input(file)
          raise
        end
        request.body = file
        @held[id] = @held.fetch(id, 0) - in_memory
        @budget.release(in_memory)
      end
      return reject(id, request, 503) unless reserve_spooled(id, bytes.bytesize)

      request.body.write(bytes)
      request.received += bytes.bytesize
    rescue => e
      @spool_error ||= e
      reject(id, request, 503)
    end

    # The temporary file for a request body; tests replace it.
    def open_spool
      Session.spool_file
    end

    # Count n more bytes of the request on id in the spool, if it has room.
    def reserve_spooled(id, n)
      return false unless @spool.bytes.reserve(n)

      @spooled[id] = @spooled.fetch(id, 0) + n
      true
    end

    # The request on id holds no bytes in the spool any more. Calling it
    # again does nothing.
    def release_spooled(id)
      n = @spooled.delete(id) or return
      @spool.bytes.release(n)
    end

    # The temporary file of the request on id is closed: it no longer
    # counts as open. Calling it again does nothing.
    def release_spool_file(id)
      @spool_files.delete(id) or return
      @spool.files.release(1)
    end

    # The response body of the request on id is done: its temporary file,
    # if it has one, is closed, and it and its bytes no longer count.
    # Calling it again does nothing.
    def finish_input(id)
      input = @spool_inputs.delete(id) or return
      close_input(input)
      release_spooled(id)
      release_spool_file(id)
    end

    # Close input unless the application has; a file that cannot be flushed
    # is given up on all the same.
    def close_input(input)
      input.close unless input.closed?
    rescue IOError, SystemCallError
      nil
    end

    # Answer the request on id with status, at once, instead of passing it
    # on: what has come of it is dropped, with the bytes it held, and
    # #respond stops reading the rest. Its Incoming stays in @incoming,
    # emptied, until the stream closes, and the callbacks still to come for
    # it are ignored. 431 may come before all of the pseudo-headers, so the
    # request goes out without any headers. A refusal is not logged: only
    # failures are, and a flood of refusals would flood the log.
    def reject(id, request, status)
      request.pseudo.clear
      request.fields.clear
      close_input(request.body)
      request.body = empty_input
      request.received = 0
      release_held(id)
      release_spooled(id)
      release_spool_file(id)
      @rejected[id] = true
      @refused << [Request.new(stream_id: id, headers: [], input: empty_input), status]
    end

    # Queue chunks of out's body while its stream has less than limit bytes
    # unsent and less than room (nil for no limit) has been queued. Returns
    # the bytes queued.
    def fill_body(out, limit, room)
      queued = 0
      id = out.request.stream_id
      while unsent_bytes(id) < limit && (room.nil? || queued < room)
        begin
          chunk = out.body.enum.next
        rescue StopIteration
          out.done = true
          push_eof(id)
          return queued
        rescue => e
          out.done = true
          abort_stream(id, Nghttp3::H3_INTERNAL_ERROR)
          yield e
          return queued
        end
        unless chunk.is_a?(String)
          out.done = true
          abort_stream(id, Nghttp3::H3_INTERNAL_ERROR)
          yield TypeError.new("body chunk must be a String (got #{chunk.class})")
          return queued
        end
        push_chunk(id, chunk)
        queued += chunk.bytesize
      end
      queued
    rescue Nghttp3::Error
      # The stream went away under the body (the peer reset it); it is
      # released when its close comes through.
      out.done = true
      queued
    end

    # An input with no body, for the requests that keep none.
    def empty_input
      StringIO.new("".b)
    end

    def release(id)
      @open.delete(id)
      incoming = @incoming.delete(id)
      close_input(incoming.body) if incoming
      release_held(id)
      release_spooled(id)
      finish_input(id)
      release_spool_file(id)
      @reset.delete(id)
      @rejected.delete(id)
      @answered.delete(id)
      @refused.reject! { |request, _| request.stream_id == id }
      @ready.reject! { |request| request.stream_id == id }
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
