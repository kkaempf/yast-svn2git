
File.open("yast.map", "r") do |inf|
  File.open("authors.txt", "w") do |outf|
    while (line = inf.gets)
      spl = line.chomp.split " "
      spl.insert(1,"=")
      outf.puts spl.join(" ")
    end
  end
end
