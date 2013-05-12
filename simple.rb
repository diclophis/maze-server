#!/usr/bin/env ruby



require './config'

$SELECT_TIMEOUT = 0.1000

def main
  connections = Array.new 
  server = TCPServer.new(7001)
  uid = 0
  loop do
    begin
      ready_for_reading, ready_for_writing, errored = IO.select([server] + connections, nil, connections, $SELECT_TIMEOUT)

      if ready_for_reading && ready_for_reading.index(server) != nil then
        socket_io = server.accept_nonblock
        uid += 1
        me = Player.new(uid, socket_io)
        connections << me
        puts ["accept", uid].inspect
        ready_for_reading.delete(server)
      end

      ready_for_reading.each do |user|
        bytes_read = user.perform_required_reading
        if (bytes_read.nil?)
          puts ["quit on read", user.player_id, bytes_read].inspect
          connections.delete(user) 
        end
      end if ready_for_reading

      connections.each do |user|
        bytes_written = user.perform_required_writing(connections)
        if (bytes_written.nil?)
          puts ["quit on write", user.player_id, bytes_written].inspect
          connections.delete(user)
        end
      end

      errored.each do |user|
        puts ["quit on errored", user.player_id].inspect
        connections.delete(user)
      end if errored
    end
  end
end

main
