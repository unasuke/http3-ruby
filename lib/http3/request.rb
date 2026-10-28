# frozen_string_literal: true

module HTTP3
  # A request as a Session put it together. headers is an Array of
  # [name, value] binary Strings with lowercase names, the pseudo-headers
  # (:method, :scheme, :authority, :path) first; a repeated name keeps one
  # pair per field. input is the request body, a binary IO at its start,
  # which becomes rack.input: a StringIO, or a temporary File once the body
  # is past the Session's request_body_buffer_size.
  Request = Data.define(:stream_id, :headers, :input)
end
