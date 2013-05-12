#!/usr/bin/env ruby

require 'spec_helper'

describe Player do

  def mock_bytes(bytes)
    @io.stub(:closed?) { false }
    @io.stub(:eof?) { false }
    @io.stub(:read).with(bytes.length) { bytes }
    @player.stub(:socket_bytes_available) { bytes.length }
  end

  before do
    @uid = 1
    @io = double("io")
    @player = Player.new(@uid, @io)
  end

  it "initializes with a player id" do
    @player.player_id.should == @uid
  end

  it "responds to :to_io" do
    @player.to_io.should == @io
  end

  describe "when connecting with native sockets" do
    before do
      @magic = "{\"-1\":[]}\n"
      mock_bytes(@magic)
      @player.perform_required_reading.should == [@magic.length, 0]
    end

    it "should read magic" do
      @player.read_magic.should be_true
    end

    describe "when reading player updates" do
      before do
        @px = 64.0, @py = 8.0
        @tx = 64.0, @ty = 8.0
        @player_update = "{\"update_player\":[#{@px}, #{@py}, #{@tx}, #{@ty}]}"
        mock_bytes(@player_update)
        @player.perform_required_reading.should == [@player_update.length, 0]
      end

      it "should update the players position and target" do
        @player.px.should == @px 
        @player.py.should == @py
        @player.tx.should == @tx
        @player.ty.should == @ty
      end
    end
  end
end
