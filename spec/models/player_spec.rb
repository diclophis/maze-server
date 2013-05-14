#!/usr/bin/env ruby

require 'spec_helper'

describe Player do

  def mock_bytes(bytes)
    @io.stub(:read).with(bytes.length) { bytes }
    @player.stub(:socket_bytes_available) { bytes.length }
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

  def mock_websocket_bytes(payload, opcode = nil)
    opcode ||= 0x02
    mask = true
    buffer = StringIO.new
    write_byte(buffer, 0x80 | opcode)
    masked_byte = mask ? 0x80 : 0x00
    if payload.bytesize <= 125
      write_byte(buffer, masked_byte | payload.bytesize)
    elsif payload.bytesize < 2 ** 16
      write_byte(buffer, masked_byte | 126)
      buffer.write([payload.bytesize].pack("n"))
    else
      write_byte(buffer, masked_byte | 127)
      buffer.write([payload.bytesize / (2 ** 32), payload.bytesize % (2 ** 32)].pack("NN"))
    end
    if mask
      mask_key = Array.new(4){ rand(256) }
      buffer.write(mask_key.pack("C*"))
      payload = apply_mask(payload, mask_key)
    end
    buffer.write(payload)

    @player.stub(:socket_bytes_available) { buffer.string.length }
    @io.stub(:read).with(buffer.string.length) { buffer.string }
  end

  before do
    @magic = "{\"-1\":[]}\n"
    @uid = 1
    @io = double("io")
    @player = Player.new(@uid, @io)

    @io.stub(:closed?) { false }
    @io.stub(:eof?) { false }
  end

  it "initializes with a player id" do
    @player.player_id.should == @uid
  end

  it "responds to :to_io" do
    @player.to_io.should == @io
  end
  
  describe "when the connection is closed" do
    before do
      @io.stub(:closed?) { true }
    end

    it "returns nil when reading" do
      @player.perform_required_reading.should be_nil
    end

    it "returns nil when writing" do
      @player.perform_required_writing.should be_nil
    end
  end

  describe "when the connection is at the end of file" do
    before do
      @player.stub(:socket_bytes_available) { 0 }
      @io.stub(:eof?) { true }
    end

    it "returns nil when reading" do
      @player.perform_required_reading.should be_nil
    end
  end

  describe "when connecting with native sockets" do
    before do
      mock_bytes(@magic)
      @player.perform_required_reading.should == @magic.length
    end

    it "should read magic" do
      @player.read_magic.should be_true
    end

    describe "reading player updates as a stream" do
      before do
        @px = 64.0, @py = 8.0
        @tx = 64.0, @ty = 8.0
        @player_update = "{\"update_player\":[#{@px}, #{@py}, #{@tx}, #{@ty}]}"
        @player_update.split("").each do |byte|
          mock_bytes(byte)
          @player.perform_required_reading.should == byte.length
        end
      end

      it "should update the players position and target" do
        @player.px.should == @px 
        @player.py.should == @py
        @player.tx.should == @tx
        @player.ty.should == @ty
      end
    end
  end

  describe "when connecting with web sockets" do
    before do
      @websocket_get = String.new
      @websocket_get << "GET / HTTP/1.1\r\n"
      @websocket_get << "Upgrade: websocket\r\n"
      @websocket_get << "Connection: Upgrade\r\n"
      @websocket_get << "Host: emscripten.risingcode.com:7001\r\n"
      @websocket_get << "Origin: http://emscripten.risingcode.com\r\n"
      @websocket_get << "Sec-WebSocket-Protocol: binary\r\n"
      @websocket_get << "Pragma: no-cache\r\n"
      @websocket_get << "Cache-Control: no-cache\r\n"
      @websocket_get << "Sec-WebSocket-Key: nRHKK7/ovSPoKPqqIMcGAQ==\r\n"
      @websocket_get << "Sec-WebSocket-Version: 13\r\n"
      @websocket_get << "Sec-WebSocket-Extensions: x-webkit-deflate-frame\r\n"
      @websocket_get << "\r\n"

      @websocket_get.split("").each do |byte|
        mock_bytes(byte)
        @player.perform_required_reading.should == byte.length
      end
    end

    describe "when sent close opcode" do
      before do
        @player.websocket_wrote_handshake = true
        mock_websocket_bytes("", 0x08)
        @io.should_receive(:close) { true }
        @io.should_not_receive(:write) { true }
      end

      it "closes the socket" do
        @player.perform_required_reading.should_not be_nil
        @player.perform_required_reading.should_not be_nil

        @io.stub(:closed?) { true }
        @player.perform_required_writing.should be_nil
      end
    end

    describe "when sent magic" do
      before do
        @player.websocket_wrote_handshake = true
        mock_websocket_bytes(@magic)
      end

      it "should read magic" do
        @player.perform_required_reading.should_not be_nil
        @player.read_magic.should be_true
      end
    end
  end
end
