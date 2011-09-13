#
# Logging
#

class Log
  @@level = 0
  @@out = STDERR
  @@outname = "STDERR"

  def Log.level
    @@level
  end
  
  def Log.level= level
    @@level = level
  end
  
  def Log.name
    @@outname
  end
  
  def Log.name= name
    Log.close
    @@outname = "#{name}.log"
    @@out = File.open @@outname, "w+"
    raise unless @@out
    STDERR.puts "Logging to #{@@outname}"
  end
  
  def Log.close
    @@out.close unless @@out == STDERR
  end
  
  def Log.log level, format, *values
    return unless level <= @@level
    @@out.puts format % values
  end
end
