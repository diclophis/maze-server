#!/usr/bin/env ruby

require 'io/wait'
require 'socket'
require 'digest'
require 'base64'
require 'stringio'
require 'yajl'

autoload(:Player, "./player.rb")
autoload(:Server, "./server.rb")
