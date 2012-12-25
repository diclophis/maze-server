#!/usr/bin/env ruby

require 'socket'
require 'digest'
require 'base64'
require 'stringio'

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
=begin
  frame = ''

  byte1 = opcode | 0b10000000 # fin bit set, rsv1-3 are 0
  frame << byte1

  length = payload.size
  if length <= 125
    byte2 = length # since rsv4 is 0
    frame << byte2
  elsif length < 65536 # write 2 byte length
    frame << 126
    frame << [length].pack('n')
  else # write 8 byte length
    frame << 127
    frame << [length >> 32, length & 0xFFFFFFFF].pack("NN")
  end

  frame << payload

  puts frame.inspect

  io.write(frame)
  io.flush
=end

  payload = force_encoding(payload.dup(), "ASCII-8BIT")
  buffer = StringIO.new(force_encoding("", "ASCII-8BIT"))
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

  buffer.write(binary(payload))
  #puts packed = Array(payload.bytes).pack("C*").inspect
puts binary(payload).inspect
  puts buffer.string.inspect
  #io.write(buffer.string)
  io.write(buffer.string)

  #write_binary(io, payload)
end

# File lib/sunshowers/io.rb, line 87
def write_binary(io, buf)
  buf = binary(buf)
  n = buf.size
  length = []
  begin
    length.unshift((n % 128) | 0x80)
  end while (n /= 128) > 0
  length[-1] ^= 0x80

  io.write("\x80#{length.pack("C*")}#{buf}")
end

def binary(buf)
  buf.encoding == Encoding::BINARY ? buf : buf.dup.force_encoding(Encoding::BINARY)
end

serv = TCPServer.new(7001)

loop do
  begin
    # sock is an accepted socket.
    sock = serv.accept_nonblock
    Thread.new {
      i = 0
      handshake_complete = false
      read_data = false
      loop do
        begin
          if handshake_complete
            loop do
              begin
                partial_input = StringIO.new(sock.read_nonblock(65536))
                bytes = partial_input.read(2).unpack("C*")
                fin = (bytes[0] & 0x80) != 0
                opcode = bytes[0] & 0x0f
                mask = (bytes[1] & 0x80) != 0
                plength = bytes[1] & 0x7f
                if plength == 126
                  bytes = partial_input.read(2)
                  plength = bytes.unpack("n")[0]
                elsif plength == 127
                  bytes = partial_input.read(8)
                  (high, low) = bytes.unpack("NN")
                  plength = high * (2 ** 32) + low
                end
                mask_key = mask ? partial_input.read(4).unpack("C*") : nil
                payload = partial_input.read(plength)
                payload = apply_mask(payload, mask_key) if mask
                case opcode
                  when $OPCODE_TEXT
                    puts force_encoding(payload, "UTF-8")
                    read_data = true
                  when $OPCODE_BINARY
                    raise "received binary data, which is not supported"
                  when $OPCODE_CLOSE
                    raise "close"
                  when $OPCODE_PING
                    raise "received ping, which is not supported"
                  when $OPCODE_PONG
                    raise "received pong, which is not supported"
                  else
                    raise "received unknown opcode: %d" % opcode
                end
              rescue Errno::EAGAIN => e
                puts "no read data"
              end

              json = "{[" + ("1," * 1) + "0]}"

              send_frame(sock, $OPCODE_BINARY, json)

              sleep 1
            end
          else
            IO.select([sock])

            input_buffer = String.new
            request_headers = {}

            loop do
              begin
                partial_input = sock.read_nonblock(1024)
                input_buffer += partial_input
              rescue EOFError => e
                puts "read input done"
                puts e.inspect
              rescue Errno::EAGAIN => e
                break
              rescue => e
                puts e.inspect
              end
            end

            lines = input_buffer.split("\n")

            lines.each { |line|
              puts line.inspect
              parts = line.split(":")
              if parts.length == 2
                request_headers[parts[0]] = parts[1].strip
              else
                puts line
              end
            }

            if key = request_headers["Sec-WebSocket-Key"]
              s = StringIO.new
              s.write("HTTP/1.1 101 Switching Protocols" + "\r\n")
              s.write("Upgrade: websocket" + "\r\n")
              s.write("Connection: Upgrade" + "\r\n")
              s.write("Sec-WebSocket-Accept: " + create_web_socket_accept(key) + "\r\n")
              s.write("Sec-WebSocket-Protocol: binary" + "\r\n")
              s.write("\r\n")

              puts s.string.inspect

              sock.write(s.string)

              handshake_complete = true
            end
          end
        rescue IOError, SocketError, SystemCallError => e
          puts "inner"
          puts e.inspect
          break;
        rescue => e
          puts "inner oops"
          puts e.inspect
          sleep 1
        end
      end
      puts "closing connection"
    }
  rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR => e
    puts "outer"
    puts e.inspect
    IO.select([serv])
    retry
  end
end

=begin

<<<
GET / HTTP/1.1
Upgrade: websocket
Connection: Upgrade
Host: emscripten.risingcode.com:7001
Origin: http://emscripten.risingcode.com
Sec-WebSocket-Protocol: binary
Sec-WebSocket-Key: VYIlpy3LRRYY0eGO8YukxQ==
Sec-WebSocket-Version: 13
Sec-WebSocket-Extensions: x-webkit-deflate-frame

>>>

HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: HSmrc0sMlYUkAGmm5OPpG2HaGWk=
Sec-WebSocket-Protocol: chat



irb(main):009:0> sha1 = Digest::SHA1.new
=> #<Digest::SHA1: da39a3ee5e6b4b0d3255bfef95601890afd80709>
irb(main):010:0> sha1.digest "foo"
=> "\v\xEE\xC7\xB5\xEA?\x0F\xDB\xC9]\r\xD4\x7F<[\xC2u\xDA\x8A3"
irb(main):011:0> magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
=> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
irb(main):012:0> key = "x3JJHMbDL1EzLkh9GBhXDw=="
=> "x3JJHMbDL1EzLkh9GBhXDw=="
irb(main):013:0> message = key + magic
=> "x3JJHMbDL1EzLkh9GBhXDw==258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
irb(main):014:0> sha1.digest message
=> "\x1D)\xABsK\f\x95\x85$\x00i\xA6\xE4\xE3\xE9\ea\xDA\x19i"
irb(main):015:0> digested = sha1.digest message
=> "\x1D)\xABsK\f\x95\x85$\x00i\xA6\xE4\xE3\xE9\ea\xDA\x19i"
irb(main):016:0> require "base64"
=> true
irb(main):017:0> enc = Base64.encode(digested)
NoMethodError: undefined method `encode' for Base64:Module
        from (irb):17
        from /home/jbardin/.rbenv/versions/1.9.3-p0/bin/irb:12:in `<main>'
irb(main):018:0> enc = Base64.encode64(digested)          
=> "HSmrc0sMlYUkAGmm5OPpG2HaGWk=\n"
irb(main):019:0> 




=end

# https://github.com/gimite/web-socket-ruby/blob/master/lib/web_socket.rb
