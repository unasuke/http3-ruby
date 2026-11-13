# frozen_string_literal: true

require "test_helper"

# HTTP3::Session.spool_file, the temporary file for a request body: made
# without a name with O_TMPFILE, or with a random name unlinked at once
# where Ruby has no File::TMPFILE (OpenBSD) or the file system does not
# take it. File#path tells the two apart: nil for the first, the name it
# was made with for the second.
class TestSpoolFile < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @tmpdir = ENV["TMPDIR"]
    ENV["TMPDIR"] = @dir
    @files = []
  end

  def teardown
    @files.each(&:close)
  ensure
    ENV["TMPDIR"] = @tmpdir
    FileUtils.remove_entry(@dir)
  end

  def test_spool_file
    skip "Ruby has no File::TMPFILE here" unless defined?(File::TMPFILE)
    file = spool_file
    skip "#{@dir} does not take O_TMPFILE" unless file.path.nil?
    assert_unnamed_binary(file)
  end

  def test_spool_file_without_tmpfile
    # File::Constants, which File includes, has it.
    tmpfile = File::Constants.send(:remove_const, :TMPFILE) if defined?(File::TMPFILE)
    begin
      file = spool_file
    ensure
      File::Constants.const_set(:TMPFILE, tmpfile) if tmpfile
    end
    assert file.path.start_with?(File.join(@dir, "http3-body-")), file.path
    assert_unnamed_binary(file)
  end

  private

  def spool_file
    HTTP3::Session.spool_file.tap { |file| @files << file }
  end

  # Readable and writable, binary, and leaves nothing in the directory.
  def assert_unnamed_binary(file)
    assert_empty Dir.children(@dir)
    file.write("\xFF\x00body".b)
    file.rewind
    read = file.read
    assert_equal "\xFF\x00body".b, read
    assert_equal Encoding::ASCII_8BIT, read.encoding
  end
end
