# frozen_string_literal: true

module HTTP3
  # A request as a Session put it together. headers is an Array of
  # [name, value] binary Strings with lowercase names, the pseudo-headers
  # (:method, :scheme, :authority, :path) first; a repeated name keeps one
  # pair per field. input is the request body, a binary IO at its start,
  # which becomes rack.input.
  Request = Data.define(:stream_id, :headers, :input)
end
