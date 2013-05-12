#!/usr/bin/env ruby

require 'io/wait'
require 'socket'
require 'digest'
require 'base64'
require 'stringio'
require 'yajl'

$SELECT_TIMEOUT = 1.000
$WEB_SOCKET_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
$OPCODE_CONTINUATION = 0x00
$OPCODE_TEXT = 0x01
$OPCODE_BINARY = 0x02
$OPCODE_CLOSE = 0x08
$OPCODE_PING = 0x09
$OPCODE_PONG = 0x0a
$CRLF = "\r\n"
$READ_SOMETHING_TIMEOUT = 0.5

class Player
  attr_accessor :player_id
  attr_accessor :px
  attr_accessor :py
  attr_accessor :tx
  attr_accessor :ty
  attr_accessor :registered
  attr_accessor :update

  attr_accessor :request_headers
  attr_accessor :socket_io
  attr_accessor :read_magic
  attr_accessor :got_blank_lines
  attr_accessor :input_buffer
  attr_accessor :websocket_framing

  attr_accessor :websocket_framing_state
  attr_accessor :fin
  attr_accessor :opcode

  attr_accessor :payload
  attr_accessor :payload_raw

  attr_accessor :state_sent_open
  attr_accessor :state_sent_id

  attr_accessor :user_updates

  attr_accessor :json_sax_parser

  attr_accessor :websocket_plength
  attr_accessor :websocket_mask
  attr_accessor :websocket_mask_key 
  attr_accessor :websocket_wrote_handshake
  attr_accessor :websocket_read_something
  attr_accessor :websocket_get

  def initialize(pid, socket)
    self.player_id = pid
    self.registered = false
    self.update = 0
    self.request_headers = Hash.new
    self.socket_io = socket
    self.read_magic = false
    self.input_buffer = String.new
    self.got_blank_lines = 0
    self.websocket_framing = false

    self.user_updates = Hash.new

    self.json_sax_parser = Yajl::Parser.new(:symbolize_keys => false)
    self.json_sax_parser.on_parse_complete = self

    self.websocket_framing_state = :read_frame_type
    self.websocket_wrote_handshake = false
    self.websocket_read_something = Time.now.to_f
  end

  def to_io
    self.socket_io
  end

  def call(obj)
    if obj["update_player"]
      self.registered = true
      self.update += 1
      unless (self.px == obj["update_player"][0] &&
        self.py == obj["update_player"][1] &&
        self.tx == obj["update_player"][2] &&
        self.ty == obj["update_player"][3])
        self.px = obj["update_player"][0]
        self.py = obj["update_player"][1]
        self.tx = obj["update_player"][2]
        self.ty = obj["update_player"][3]
        puts "#{self.player_id} is going to #{self.px},#{self.py} => #{self.tx},#{self.ty}"
      end
    end
  end

  def waiting_to_read_magic?
    self.read_magic == false
  end

  def write_byte(buffer, byte)
    buffer.write([byte].pack("C"))
  end

  def websocket_apply_mask(payload, mask_key)
    orig_bytes = payload.unpack("C*")
    new_bytes = []
    orig_bytes.each_with_index() do |b, i|
      new_bytes.push(b ^ mask_key[i % 4])
    end
    return new_bytes.pack("C*")
  end

  def send_frame(io, opcode, payload)
    buffer = StringIO.new
    byte1 = opcode | 0b10000000
    write_byte(io, byte1)
    masked_byte = 0x00
    if payload.bytesize <= 125
      write_byte(buffer, masked_byte | payload.bytesize)
    elsif payload.bytesize < 2 ** 16
      write_byte(buffer, masked_byte | 126)
      buffer.write([payload.bytesize].pack("n"))
    else
      write_byte(buffer, masked_byte | 127)
      buffer.write([payload.bytesize / (2 ** 32), payload.bytesize % (2 ** 32)].pack("NN"))
    end

    buffer.write(payload)
    io.write(buffer.string)
  end

  def create_websocket_accept_token(key)
    sha1 = Digest::SHA1.new
    message = key + $WEB_SOCKET_MAGIC
    digested = sha1.digest message
    Base64.encode64(digested).strip
  end

  def write_websocket_handshake(io, accept_token)
    s = String.new
    s << "HTTP/1.1 101 Switching Protocols" + $CRLF
    s << "Upgrade: websocket" + $CRLF
    s << "Connection: Upgrade" + $CRLF
    s << "Sec-WebSocket-Accept: " + accept_token + $CRLF
    s << "Sec-WebSocket-Protocol: binary" + $CRLF 
    s << $CRLF 
    loop do
      ready_for_reading, ready_for_writing, errored = IO.select(nil, [io])
      ready_for_writing.each do |socket_to_write_to|
        bytes_to_write = s.slice!(0, s.length)
        bytes_written = socket_to_write_to.write(bytes_to_write)
      end
      break if s.length == 0 #NOTE: stop writing once we have delivered the entire header response
    end
  end

  def perform_required_reading
    return if self.socket_io.closed?

    buf = ""
    fionread = 0x541B
    ioctl_res = self.socket_io.ioctl(fionread, buf)
    things = buf.unpack("l")
    bytes_available = things[0]

    unless self.got_blank_lines > 0
      if waiting_to_read_magic? then
        return if self.socket_io.eof?
        partial_input = self.socket_io.read(bytes_available)
        if partial_input.length > 0
          if partial_input[0] == "{"
            self.read_magic = true
          end
        end
        self.input_buffer << partial_input
        return self.input_buffer.length unless waiting_to_read_magic?
        loop do
          pos_of_end_line = self.input_buffer.index($CRLF)
          if pos_of_end_line.nil?
            break
          else
            line = self.input_buffer.slice!(0, pos_of_end_line + $CRLF.length).strip
            self.got_blank_lines += 1 if (line.length == 0) #NOTE: break reading because we are at blank line at head of HTTP headers
            parts = line.split(":")
            if parts.length == 2
              self.request_headers[parts[0]] = parts[1].strip
            else
              #NOTE: not a header, likely the "GET / ..." line, discarded
              self.websocket_get = line
            end
          end
        end
      end
      return [bytes_available, self.input_buffer.length] if self.got_blank_lines == 0 && waiting_to_read_magic?
    end

    unless self.read_magic || self.websocket_wrote_handshake
      if key = request_headers["Sec-WebSocket-Key"] #NOTE: socket is a websocket, respond with handshake
        raise "only binary websockets are supported" unless request_headers["Sec-WebSocket-Protocol"] == "binary"
        write_websocket_handshake(self.socket_io, create_websocket_accept_token(key))
        self.websocket_framing = true
        self.websocket_wrote_handshake = true
      else
        raise "not sure what this is, abort and close" unless self.read_magic
      end
    end

    ioctl_res = self.socket_io.ioctl(fionread, buf)
    things = buf.unpack("l")
    bytes_available = things[0]

    need_to_disconnect_nothing_to_read_native = (bytes_available == 0 && !self.websocket_framing)
    need_to_disconnect_nothing_to_read_websocket = (bytes_available == 0 && self.websocket_framing && ((Time.now.to_f - self.websocket_read_something) > $READ_SOMETHING_TIMEOUT))
    need_to_skip_websocket = (bytes_available == 0 && self.websocket_framing && !self.read_magic)

    return if need_to_disconnect_nothing_to_read_native
    return if need_to_disconnect_nothing_to_read_websocket
    return 0 if need_to_skip_websocket

    partial_input = self.socket_io.read(bytes_available)
    self.input_buffer << partial_input

    if self.websocket_framing
      self.payload = self.extract_websocket_payload
      if self.payload && self.payload.length > 0 && self.payload[0] == "{" && self.read_magic == false
        self.read_magic = true
      end
    else
      self.payload = self.extract_native_payload
    end

    if self.payload
      begin
        self.json_sax_parser << self.payload
      rescue Yajl::ParseError => e
        return
      end
      self.payload = nil
    end

    [bytes_available, self.input_buffer.length]
  end

  def extract_native_payload
    if self.input_buffer.length > 0
      self.input_buffer.slice!(0, self.input_buffer.length)
    end
  end

  def perform_required_writing(usrs)
    return 0 if (!self.websocket_framing && !self.read_magic) || (self.websocket_framing && !self.websocket_wrote_handshake)
    out_frame = ""
    if self.state_sent_open
      if self.state_sent_id
        usrs.each do |usr|
          unless usr == self
            if self.user_updates[usr].nil? || usr.update > self.user_updates[usr] then
              self.user_updates[usr] = usr.update
              out_frame += "[\"update_player\",\n#{usr.player_id},#{usr.px},#{usr.py},#{usr.tx},#{usr.ty}]," if usr.registered
            end
          end
        end
      else
        self.state_sent_id = true
        out_frame = "[\"request_registration\",\n#{self.player_id}],"
      end
    else
      self.state_sent_open = true
      out_frame = "{\"stream\":["
    end

    if out_frame.length > 0
      begin
        if self.websocket_framing
          send_frame(self.socket_io, $OPCODE_BINARY, out_frame)
        else
          self.socket_io.write(out_frame)
        end
      rescue Errno::ECONNRESET, Errno::EPIPE => e
        return
      end
    end

    return out_frame.length
  end

  def extract_websocket_payload
    paydirt = nil
    if self.websocket_framing_state == :read_frame_type && self.input_buffer.length >= 1
      byte = self.input_buffer.slice!(0, 1).unpack("C")[0]
      self.fin = (byte & 0x80) != 0
      self.opcode = byte & 0x0f
      self.websocket_framing_state = :read_frame_length
    elsif self.websocket_framing_state == :read_frame_length && self.input_buffer.length >= 1
      byte = self.input_buffer.slice!(0, 1).unpack("C")[0]
      self.websocket_mask = (byte & 0x80) != 0
      self.websocket_plength = byte & 0x7f
      if self.websocket_plength == 126
        self.websocket_framing_state = :read_frame_length_126
      elsif self.websocket_plength == 127
        self.websocket_framing_state = :read_frame_length_127
      else
        if self.websocket_mask
          self.websocket_framing_state = :read_frame_mask
        else
          self.websocket_framing_state = :read_frame_payload
        end
      end
    elsif self.websocket_framing_state == :read_frame_length_126 && self.input_buffer.length >= 2
      bytes_packed = self.input_buffer.slice!(0, 2)
      self.websocket_plength = bytes_packed.unpack("n")[0]
      if self.websocket_mask
        self.websocket_framing_state = :read_frame_mask
      else
        self.websocket_framing_state = :read_frame_payload
      end
    elsif self.websocket_framing_state == :read_frame_length_127 && self.input_buffer.length >= 8
      bytes_packed = self.input_buffer.slice!(0, 8)
      (high, low) = bytes_unpacked.unpack("NN")
      self.websocket_plength = high * (2 ** 32) + low
      if self.websocket_mask
        self.websocket_framing_state = :read_frame_mask
      else
        self.websocket_framing_state = :read_frame_payload
      end
    elsif self.websocket_framing_state == :read_frame_mask && self.input_buffer.length >= 4
      self.websocket_mask_key = self.input_buffer.slice!(0, 4).unpack("C*")
      self.websocket_framing_state = :read_frame_payload
    elsif self.websocket_framing_state == :read_frame_payload && self.input_buffer.length >= self.websocket_plength
      self.payload_raw = self.input_buffer.slice!(0, self.websocket_plength)
      if self.websocket_mask
        paydirt = websocket_apply_mask(self.payload_raw, self.websocket_mask_key)
      else
        paydirt = self.payload_raw
      end
      self.input_buffer.slice!(0, self.input_buffer.length)
      self.websocket_read_something = Time.now.to_f if paydirt
      case self.opcode
        when $OPCODE_TEXT, $OPCODE_BINARY
        when $OPCODE_CLOSE
          puts "client sent close request" #TODO: make sure this stops the thread
        when $OPCODE_PING
          puts "received ping, which is not supported"
        when $OPCODE_PONG
          puts "received pong, which is not supported"
        else
          puts "received unknown opcode: %d" % self.opcode
      end
      self.websocket_framing_state = :read_frame_type
    end

    paydirt
  end
end

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
