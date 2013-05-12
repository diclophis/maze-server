#!/usr/bin/env ruby

require 'spec_helper'

describe Player do
  it "initializes with a unique id and socket IO" do
    @uid = 1
    @io = mock 
    @player = Player.new(@uid, @io)

    @player.player_id.should == @uid
  end
end
