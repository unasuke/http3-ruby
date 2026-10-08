# frozen_string_literal: true

module HTTP3
  module Nghttp3
    # A case-insensitive header collection for HTTP/3
    #
    # Header names are automatically normalized to lowercase.
    # Supports multiple values for the same header name.
    class Headers
      include Enumerable

      def initialize(hash = {})
        @headers = {}
        hash&.each { |k, v| self[k] = v }
      end

      # Get header value by name (case-insensitive)
      # @param name [String, Symbol] header name
      # @return [String, nil] header value or nil if not found
      def [](name)
        @headers[normalize_name(name)]
      end

      # Set header value (case-insensitive)
      # @param name [String, Symbol] header name
      # @param value [String, #to_s] header value
      # @return [String] the value
      def []=(name, value)
        @headers[normalize_name(name)] = value.to_s
      end

      # Delete a header
      # @param name [String, Symbol] header name
      # @return [String, nil] deleted value or nil
      def delete(name)
        @headers.delete(normalize_name(name))
      end

      # Check if header exists
      # @param name [String, Symbol] header name
      # @return [Boolean]
      def key?(name)
        @headers.key?(normalize_name(name))
      end
      alias_method :has_key?, :key?
      alias_method :include?, :key?

      # Iterate over all headers
      # @yield [name, value] each header name-value pair
      def each(&block)
        return enum_for(:each) unless block_given?
        @headers.each(&block)
      end

      # Merge another hash into this headers collection
      # @param other [Hash, Headers] headers to merge
      # @return [self]
      def merge!(other)
        other.each { |k, v| self[k] = v }
        self
      end

      # Return a new Headers with merged values
      # @param other [Hash, Headers] headers to merge
      # @return [Headers] new Headers instance
      def merge(other)
        dup.merge!(other)
      end

      # Convert to Hash
      # @return [Hash{String => String}]
      def to_h
        @headers.dup
      end
      alias_method :to_hash, :to_h

      # Number of headers
      # @return [Integer]
      def size
        @headers.size
      end
      alias_method :length, :size

      # Check if empty
      # @return [Boolean]
      def empty?
        @headers.empty?
      end

      # Remove all headers
      # @return [self]
      def clear
        @headers.clear
        self
      end

      # Duplicate the headers collection
      # @return [Headers]
      def dup
        self.class.new(@headers)
      end

      # String representation
      def inspect
        "#<#{self.class} #{@headers.inspect}>"
      end

      private

      def normalize_name(name)
        name.to_s.downcase
      end
    end
  end
end
