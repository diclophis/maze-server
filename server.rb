#!/usr/bin/env ruby

require './config'


class Server
  SELECT_TIMEOUT = 1.0 

  attr_accessor :connections
  attr_accessor :server
  attr_accessor :uid
  attr_accessor :running

  def initialize
    self.connections = Array.new 
    self.server = TCPServer.new(7001)
    self.uid = 0
    self.running = false
    Signal.trap("INT") do |signo|
      self.running = false
    end
  end

  def selectable_sockets
    [self.server] + self.connections
  end

  def select_sockets_that_require_action
    IO.select(self.selectable_sockets, nil, self.selectable_sockets, SELECT_TIMEOUT)
  end

  def accept_new_player
    socket_io = self.server.accept_nonblock
    self.uid += 1
    new_player = Player.new(self.uid, socket_io)
    self.connections << new_player
    puts ["accept", uid].inspect
  end

  def run
    self.running = true

    while self.running do
      begin
        ready_for_reading, ready_for_writing, errored = self.select_sockets_that_require_action

        if ready_for_reading && ready_for_reading.index(self.server) != nil then
          self.accept_new_player
        end

        ready_for_reading.each do |user|
          next if user == self.server
          bytes_read = user.perform_required_reading
          if (bytes_read.nil?)
            puts ["quit on read", user.player_id, bytes_read].inspect
            self.connections.delete(user) 
          end
        end if ready_for_reading

        self.connections.each do |user|
          next if user == self.server
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

    self.server.close
  end
end
