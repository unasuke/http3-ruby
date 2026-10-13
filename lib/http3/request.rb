# frozen_string_literal: true

module HTTP3
  # A request as a Session put it together. headers is an Array of
  # [name, value] binary Strings with lowercase names, the pseudo-headers
  # (:method, :scheme, :authority, :path) first; a repeated name keeps one
  # pair per field. body is the request body, a binary String.
  Request = Data.define(:stream_id, :headers, :body)
end
