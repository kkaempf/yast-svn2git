#
# Accessing the svn dumpfile
#

class Dumpfile
  attr_reader :pos_of_line

  def initialize filename
    @filename = filename
    @dump = File.open(filename, "r")
    @line = nil
  end

  def eof?
    @dump.eof?
  end

  def gets
    @pos_of_line = @dump.pos
    return nil if @dump.eof?
    @line = @dump.gets.chomp
    @line
  end
  
  def skip bytes
    @dump.pos = @dump.pos + bytes
  end

  def pos= p
    @dump.pos = p
  end

  def pos
    @dump.pos
  end
  
  def copy_to from, size, file
    return unless size > 0
    old = @dump.pos
    # Ruby 1.9: IO.copy_stream(@dump, file, size, from)
    @dump.pos = from
    buf = @dump.read size
    file.write buf
    @dump.pos = old
  end
end

