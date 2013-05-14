#!/usr/bin/env ruby

require './config'


class Server
  SELECT_TIMEOUT = 0.1000

  attr_accessor :connections
  attr_accessor :server
  attr_accessor :uid

  def initialize
    self.connections = Array.new 
    self.server = TCPServer.new(7001)
    self.uid = 0
  end

  def run
    loop do
      begin
        ready_for_reading, ready_for_writing, errored = IO.select([self.server] + self.connections, nil, self.connections, SELECT_TIMEOUT)

        if ready_for_reading && ready_for_reading.index(self.server) != nil then
          socket_io = self.server.accept_nonblock
          self.uid += 1
          me = Player.new(self.uid, socket_io)
          self.connections << me
          puts ["accept", uid].inspect
          ready_for_reading.delete(self.server)
        end

        ready_for_reading.each do |user|
          bytes_read = user.perform_required_reading
          if (bytes_read.nil?)
            puts ["quit on read", user.player_id, bytes_read].inspect
            self.connections.delete(user) 
          end
        end if ready_for_reading

        self.connections.each do |user|
          bytes_written = user.perform_required_writing(self.connections)
          if (bytes_written.nil?)
            puts ["quit on write", user.player_id, bytes_written].inspect
            self.connections.delete(user)
          end
        end

        errored.each do |user|
          puts ["quit on errored", user.player_id].inspect
          self.connections.delete(user)
        end if errored
      end
    end
  end
end
