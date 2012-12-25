#!/usr/bin/env ruby

require 'socket'
require 'digest'
require 'base64'
require 'stringio'

$SELECT_TIMEOUT = 1
$WEB_SOCKET_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
$OPCODE_CONTINUATION = 0x00
$OPCODE_TEXT = 0x01
$OPCODE_BINARY = 0x02
$OPCODE_CLOSE = 0x08
$OPCODE_PING = 0x09
$OPCODE_PONG = 0x0a

def create_web_socket_accept(key)
  sha1 = Digest::SHA1.new
  message = key + $WEB_SOCKET_MAGIC
  digested = sha1.digest message
  Base64.encode64(digested).strip
end

def force_encoding(str, encoding)
  if str.respond_to?(:force_encoding)
    return str.force_encoding(encoding)
  else
    return str
  end
end

def binary(buf)
  buf.encoding == Encoding::BINARY ? buf : buf.dup.force_encoding(Encoding::BINARY)
end

def write_byte(buffer, byte)
  buffer.write([byte].pack("C"))
end

def apply_mask(payload, mask_key)
  orig_bytes = payload.unpack("C*")
  new_bytes = []
  orig_bytes.each_with_index() do |b, i|
    new_bytes.push(b ^ mask_key[i % 4])
  end
  return new_bytes.pack("C*")
end

def send_frame(io, opcode, payload)
  #TODO: figure out if force_encoding(payload) is required ???
  #payload = force_encoding(payload.dup(), "ASCII-8BIT")
  #buffer = StringIO.new(force_encoding("", "ASCII-8BIT"))
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

  buffer.write(payload) #TODO: figure out if binary(payload) ???
  io.write(buffer.string)
end

def handle_client(sock)
  crlf = "\r\n"
  bytes_at_a_time = 3
  websocket_framing = false
  read_magic = false
  input_buffer = String.new
  request_headers = Hash.new
  read_json_stream_start = false
  loop do # reading HTTP WebSocket headers, or magic
    ready_for_reading, ready_for_writing, errored = IO.select([sock], [], [sock], $SELECT_TIMEOUT)
    ready_for_reading.each do |socket_to_read_from|
      partial_input = sock.read_nonblock(bytes_at_a_time)
      if partial_input.length == 1
        if partial_input == "{"
          read_magic = true
        end
      end
      input_buffer << partial_input
    end if ready_for_reading
    break if read_magic #NOTE: break reading because we got the magic byte as first token (non-websocket client)
    pos_of_end_line = input_buffer.index(crlf)
    unless pos_of_end_line.nil?
      line = input_buffer.slice!(0, pos_of_end_line + crlf.length).strip
      break if line.length == 0 #NOTE: break reading because we are at blank line at head of HTTP headers
      parts = line.split(":")
      if parts.length == 2
        request_headers[parts[0]] = parts[1].strip
      else
        #NOTE: not a header, likely the "GET / ..." line, discarded
      end
    end
  end
  if key = request_headers["Sec-WebSocket-Key"] #NOTE: socket is a websocket, respond with handshake
    s = String.new
    s << "HTTP/1.1 101 Switching Protocols" + crlf 
    s << "Upgrade: websocket" + crlf 
    s << "Connection: Upgrade" + crlf 
    s << "Sec-WebSocket-Accept: " + create_web_socket_accept(key) + crlf
    s << "Sec-WebSocket-Protocol: binary" + crlf
    s << crlf 
    loop do
      ready_for_reading, ready_for_writing, errored = IO.select(nil, [sock])
      ready_for_writing.each do |socket_to_write_to|
        bytes_to_write = s.slice!(0, bytes_at_a_time)
        bytes_written = socket_to_write_to.write(bytes_to_write)
      end
      break if s.length == 0 #NOTE: stop writing once we have delivered the entire header response
    end
    websocket_framing = true
  else
    raise "not sure what this is, abort and close" unless read_magic
  end

  websocket_framing_state = :read_frame_type
  fin = nil
  opcode = nil
  plength = nil
  mask = nil
  mask_key = nil
  payload = nil

  loop do #NOTE: begin main read/write tick loop
    ready_for_reading, ready_for_writing, errored = IO.select([sock], [], [sock], $SELECT_TIMEOUT) #NOTE: do not wait for write in same thread as read?
    ready_for_reading.each do |socket_to_read_from|
      partial_input = sock.read_nonblock(bytes_at_a_time)
      input_buffer << partial_input
    end if ready_for_reading
    if websocket_framing
      if websocket_framing_state == :read_frame_type && input_buffer.length >= 1
        byte = input_buffer.slice!(0, 1).unpack("C")[0]
        fin = (byte & 0x80) != 0
        opcode = byte & 0x0f
        websocket_framing_state = :read_frame_length
      elsif websocket_framing_state == :read_frame_length && input_buffer.length >= 1
        byte = input_buffer.slice!(0, 1).unpack("C")[0]
        mask = (byte & 0x80) != 0
        plength = byte & 0x7f
        if plength == 126
          websocket_framing_state = :read_frame_length_126
        elsif plength == 127
          websocket_framing_state = :read_frame_length_127
        else
          if mask
            websocket_framing_state = :read_frame_mask
          else
            websocket_framing_state = :read_frame_payload
          end
        end
      elsif websocket_framing_state == :read_frame_length_126 && input_buffer.length >= 2
        bytes_packed = input_buffer.slice!(0, 2)
        plength = bytes_packed.unpack("n")[0]
        if mask
          websocket_framing_state = :read_frame_mask
        else
          websocket_framing_state = :read_frame_payload
        end
      elsif websocket_framing_state == :read_frame_length_127 && input_buffer.length >= 8
        bytes_packed = input_buffer.slice!(0, 8)
        (high, low) = bytes_unpacked.unpack("NN")
        plength = high * (2 ** 32) + low
        if mask
          websocket_framing_state = :read_frame_mask
        else
          websocket_framing_state = :read_frame_payload
        end
      elsif websocket_framing_state == :read_frame_mask && input_buffer.length >= 4
        mask_key = input_buffer.slice!(0, 4).unpack("C*")
        websocket_framing_state = :read_frame_payload
      elsif websocket_framing_state == :read_frame_payload && input_buffer.length >= plength
        payload_raw = input_buffer.slice!(0, plength)
        if mask
          payload = apply_mask(payload_raw, mask_key)
        else
          payload = payload_raw
        end
        case opcode
          when $OPCODE_TEXT, $OPCODE_BINARY
          when $OPCODE_CLOSE
            raise "close"
          when $OPCODE_PING
            raise "received ping, which is not supported"
          when $OPCODE_PONG
            raise "received pong, which is not supported"
          else
            raise "received unknown opcode: %d" % opcode
        end
        websocket_framing_state = :read_frame_type
      end
    else
      if input_buffer.length > 0
        payload = input_buffer.slice!(0, input_buffer.length)
      end
    end
    if payload
      #puts "buffer"
      #puts input_buffer.inspect
      #puts "state"
      #puts websocket_framing_state.inspect
      #puts "opcode"
      #puts opcode.inspect
      #puts "mask"
      #puts mask.inspect
      #puts "mask key"
      #puts mask_key.inspect
      #puts "payload length"
      #puts plength.inspect
      puts "payload"
      puts payload.inspect
      payload = nil
    end
    ready_for_writing.each do |socket_to_read_from|
      if read_magic
        puts "write something to client"
      end
    end if ready_for_writing

    send_frame(sock, $OPCODE_BINARY, "sent")
  end
end

serv = TCPServer.new(7001)

loop do
  begin
    # sock is an accepted socket.
    sock = serv.accept_nonblock
    Thread.new {
      begin
        handle_client(sock)
      rescue => e
        puts e.inspect
        puts e.backtrace.join("\n")
      end
    }
  rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR => e
    puts "outer"
    puts e.inspect
    IO.select([serv])
    retry
  end
end

# https://github.com/gimite/web-socket-ruby/blob/master/lib/web_socket.rb
# http://bogomips.org/sunshowers.git/tree/lib/sunshowers/io.rb?id=000a0fbb6fd04ed2cf75aba4117df6755d71f895
# http://rainbows.rubyforge.org/sunshowers/Sunshowers/IO.html
# https://github.com/gimite/web-socket-ruby/blob/master/lib/web_socket.rb
# http://www.whatwg.org/specs/web-socket-protocol/
# http://www.altdevblogaday.com/2012/01/23/writing-your-own-websocket-server/
# http://www.htmlgoodies.com/html5/tutorials/making-html5-websockets-work.html
# https://developer.mozilla.org/en-US/docs/WebSockets/Writing_WebSocket_client_applications
# https://github.com/igrigorik/em-websocket/blob/master/lib/em-websocket/handshake04.rb
