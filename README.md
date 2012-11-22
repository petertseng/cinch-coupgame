# Cinch-Coup

## Description

This is a Cinch plugin to enable your bot to moderate Coup by Rikki Tahta. 

http://www.boardgamegeek.com/boardgame/131357/coup

## Usage

Here's an example of what your *bot.rb* might look like: 

    require 'cinch'
    require './cinch-coupgame/lib/cinch/plugins/coup_game'

    bot = Cinch::Bot.new do

      configure do |c|
        c.nick            = "CoupBot"
        c.server          = "irc.freenode.org"
        c.channels        = ["#playcoup"]
        c.verbose         = true
        c.plugins.plugins = [
          Cinch::Plugins::CoupGame
        ]
        c.plugins.options[Cinch::Plugins::CoupGame] = {
          :mods     => ["caitlinface", "shard8"],
          :channel  => "#playcoup",
          :settings => "settings.yml"
        }
      end

    end

    bot.start

## Development

(pivotal tracker link)