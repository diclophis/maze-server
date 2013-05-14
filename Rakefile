require 'rake'
require './config'
 
desc "Default Task"
task :default => [ :server ]

desc "Server"
task :server do
  server = Server.new
  server.run
end
