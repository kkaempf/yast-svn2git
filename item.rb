#
# Read generic item
#
class Item
  attr_reader :pos, :content_pos, :type, :value, :size, :content_size, :is_relevant

protected
  def init_from_dumpfile dump
    raise EOFError if dump.eof?
    # read header
    while (line = dump.gets)
      if line.empty?
	if @type # end of header
	  break
	else
	  next # skip empty lines before type
	end
      end
      key,value = line.split ":"
      if value.nil?
	raise "Bad line '#{line}' at %08x" % dump.pos_of_line
      end
      value.strip!
      @order << key
      @header[key] = value
      unless @type
	@pos = dump.pos_of_line
        @type, @value = key,value
      end
      break if dump.eof?
    end
    @pos ||= dump.pos_of_line
    cl = @header["Content-length"]
    @content_size = cl ? cl.to_i : 0
    @content_pos = dump.pos
    @size = @content_pos + @content_size - @pos
    dump.skip @content_size
  end
  
  def init_from_yaml input
    order = input["order"] || []
    order.each do |keyval|
      key, value = keyval
      unless @type
        @type, @value = key,value
      end
      @order << key
      @header[key] = value
    end
    @pos = input["pos"]
    cl = @header["Content-length"]
    @content_size = cl ? cl.to_i : 0
    @content_pos = @pos + input["cpos"]
    @size = @content_pos + @content_size - @pos
  end

public
  #
  # Initialize from Dumpfile or YAML (Hash)
  #
  # Hash example:   {"order"=>[["Revision-number", 3984], ["Prop-content-length", 140], ["Content-length", 140]], "cpos"=>68, "pos"=>336443341,
  # (first item in "order" array is type
  #
  def initialize input
    
    @header = {}
    @order = []
    @type = nil
    @is_relevant = false

    if input.is_a? Dumpfile
      self.init_from_dumpfile input
    else
      self.init_from_yaml input
    end
    @changed = false
  end

  def [] key
    @header[key]
  end

  def []= key, value
    @header[key] = value
    @changed = true
  end

  #
  def copy_to dump, file
    if @changed
      @order.each do |key|
	value = @header[key]
	file.puts "#{key}: #{value}"
      end
      file.puts
      dump.copy_to @content_pos, @content_size, file
    else
      dump.copy_to @pos, @size, file
    end
  end

  def to_s
    "Item #{@type} @ %08x\n" % @pos
  end

end


