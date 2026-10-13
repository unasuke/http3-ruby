# frozen_string_literal: true

require "test_helper"

class TestHeaders < Minitest::Test
  def test_new_creates_empty_headers
    headers = H3TestClient::Headers.new
    assert_kind_of H3TestClient::Headers, headers
    assert headers.empty?
  end

  def test_new_with_hash
    headers = H3TestClient::Headers.new({"content-type" => "text/html"})
    assert_equal "text/html", headers["content-type"]
  end

  def test_case_insensitive_access
    headers = H3TestClient::Headers.new({"Content-Type" => "text/html"})
    assert_equal "text/html", headers["content-type"]
    assert_equal "text/html", headers["Content-Type"]
    assert_equal "text/html", headers["CONTENT-TYPE"]
  end

  def test_case_insensitive_set
    headers = H3TestClient::Headers.new
    headers["Content-Type"] = "text/html"
    assert_equal "text/html", headers["content-type"]
  end

  def test_bracket_set_converts_value_to_string
    headers = H3TestClient::Headers.new
    headers["content-length"] = 100
    assert_equal "100", headers["content-length"]
  end

  def test_include_is_case_insensitive
    headers = H3TestClient::Headers.new({"content-type" => "text/html"})
    assert headers.include?("content-type")
    assert headers.include?("Content-Type")
    assert headers.include?("CONTENT-TYPE")
  end

  def test_delete_is_case_insensitive
    headers = H3TestClient::Headers.new({"content-type" => "text/html", "accept" => "*/*"})
    headers.delete("Content-Type")
    refute headers.include?("content-type")
    assert headers.include?("accept")
  end

  def test_each_iterates_over_headers
    headers = H3TestClient::Headers.new({"Content-Type" => "text/html", "Accept" => "*/*"})
    pairs = []
    headers.each { |name, value| pairs << [name, value] }
    assert_includes pairs, ["content-type", "text/html"]
    assert_includes pairs, ["accept", "*/*"]
  end

  def test_enumerable_methods
    headers = H3TestClient::Headers.new({"a" => "1", "b" => "2", "c" => "3"})
    assert_equal 3, headers.count
    assert headers.any? { |name, _| name == "b" }
  end

  def test_to_h_returns_normalized_hash
    headers = H3TestClient::Headers.new({"Content-Type" => "text/html", "Accept" => "*/*"})
    h = headers.to_h
    assert_kind_of Hash, h
    assert_equal "text/html", h["content-type"]
    assert_equal "*/*", h["accept"]
  end

  def test_merge_combines_headers
    headers = H3TestClient::Headers.new({"a" => "1"})
    headers["b"] = "2"
    headers["c"] = "3"
    assert_equal "1", headers["a"]
    assert_equal "2", headers["b"]
    assert_equal "3", headers["c"]
  end

  def test_merge_overwrites_existing
    headers = H3TestClient::Headers.new({"a" => "1"})
    headers["A"] = "2"
    assert_equal "2", headers["a"]
  end

  def test_size_returns_header_count
    headers = H3TestClient::Headers.new({"a" => "1", "b" => "2"})
    assert_equal 2, headers.size
    assert_equal 2, headers.length
  end

  def test_empty_returns_true_for_empty_headers
    headers = H3TestClient::Headers.new
    assert headers.empty?
    headers["a"] = "1"
    refute headers.empty?
  end

  def test_clear_removes_all_headers
    headers = H3TestClient::Headers.new({"a" => "1", "b" => "2"})
    headers.clear
    assert headers.empty?
  end

  def test_dup_creates_copy
    original = H3TestClient::Headers.new({"a" => "1"})
    copy = original.dup
    copy["b"] = "2"
    refute original.include?("b")
    assert copy.include?("b")
  end
end
