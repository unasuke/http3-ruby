# frozen_string_literal: true

module HTTP3
  module Nghttp3
    # Internal stream ID management
    #
    # HTTP/3 uses different stream ID allocation for clients and servers:
    # - Client-initiated bidirectional streams: 0, 4, 8, 12, ...
    # - Server-initiated bidirectional streams: 1, 5, 9, 13, ...
    # - Client-initiated unidirectional streams: 2, 6, 10, 14, ...
    # - Server-initiated unidirectional streams: 3, 7, 11, 15, ...
    #
    # @private
    class StreamManager
      # Stream types
      BIDI_CLIENT = 0x00
      BIDI_SERVER = 0x01
      UNI_CLIENT = 0x02
      UNI_SERVER = 0x03

      def initialize(is_server:)
        @is_server = is_server
        # Next stream IDs by type
        @next_bidi_stream_id = is_server ? 1 : 0
        @next_uni_stream_id = is_server ? 3 : 2
        # Track active streams
        @active_streams = {}
      end

      # Allocate a new bidirectional stream ID
      # @return [Integer] new stream ID
      def allocate_bidi_stream_id
        id = @next_bidi_stream_id
        @next_bidi_stream_id += 4
        @active_streams[id] = {type: :bidi, state: :open}
        id
      end

      # Allocate a new unidirectional stream ID
      # @return [Integer] new stream ID
      def allocate_uni_stream_id
        id = @next_uni_stream_id
        @next_uni_stream_id += 4
        @active_streams[id] = {type: :uni, state: :open}
        id
      end

      # Register an externally-opened stream (e.g., from QUIC layer)
      # @param stream_id [Integer] stream ID
      # @param type [Symbol] :bidi or :uni
      def register_stream(stream_id, type: :bidi)
        @active_streams[stream_id] = {type: type, state: :open}
      end

      # Close a stream
      # @param stream_id [Integer] stream ID to close
      def close_stream(stream_id)
        if @active_streams[stream_id]
          @active_streams[stream_id][:state] = :closed
        end
      end

      # Remove a stream from tracking
      # @param stream_id [Integer] stream ID to remove
      def remove_stream(stream_id)
        @active_streams.delete(stream_id)
      end

      # Check if stream is active
      # @param stream_id [Integer] stream ID
      # @return [Boolean]
      def stream_active?(stream_id)
        @active_streams[stream_id]&.dig(:state) == :open
      end

      # Get all active stream IDs
      # @return [Array<Integer>]
      def active_stream_ids
        @active_streams.select { |_, v| v[:state] == :open }.keys
      end

      # Get stream info
      # @param stream_id [Integer] stream ID
      # @return [Hash, nil] stream info or nil if not found
      def stream_info(stream_id)
        @active_streams[stream_id]&.dup
      end

      # Check if this is a client-initiated stream
      # @param stream_id [Integer] stream ID
      # @return [Boolean]
      def client_initiated?(stream_id)
        (stream_id & 0x01) == 0
      end

      # Check if this is a server-initiated stream
      # @param stream_id [Integer] stream ID
      # @return [Boolean]
      def server_initiated?(stream_id)
        (stream_id & 0x01) == 1
      end

      # Check if this is a bidirectional stream
      # @param stream_id [Integer] stream ID
      # @return [Boolean]
      def bidirectional?(stream_id)
        (stream_id & 0x02) == 0
      end

      # Check if this is a unidirectional stream
      # @param stream_id [Integer] stream ID
      # @return [Boolean]
      def unidirectional?(stream_id)
        (stream_id & 0x02) == 2
      end
    end
  end
end
