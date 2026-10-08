# frozen_string_literal: true

module HTTP3
  # A response for a Session to send. status is an Integer, headers an Array
  # of [name, value] Strings without pseudo-headers, and body nil (no
  # content) or one of the HTTP3::Body types.
  Response = Data.define(:status, :headers, :body)

  module Body
    # length bytes of io from offset, read by the C part of the Session as
    # the connection can take them. The Session closes io, and rack_body
    # unless it is nil, when the stream ends.
    File = Data.define(:io, :offset, :length, :rack_body)

    # Chunks pulled with enum.next as the send buffer drains; StopIteration
    # ends the body. The Session closes rack_body, unless it is nil, when
    # the stream ends.
    Chunks = Data.define(:enum, :rack_body)
  end
end
