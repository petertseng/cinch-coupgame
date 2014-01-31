require 'cinch'
require 'yaml'

require File.expand_path(File.dirname(__FILE__)) + '/core/action'
require File.expand_path(File.dirname(__FILE__)) + '/core/game'
require File.expand_path(File.dirname(__FILE__)) + '/core/turn'
require File.expand_path(File.dirname(__FILE__)) + '/core/player'
require File.expand_path(File.dirname(__FILE__)) + '/core/character'

module Cinch
  module Plugins

    CHANGELOG_FILE = File.expand_path(File.dirname(__FILE__)) + "/changelog.yml"

    class CoupGame
      include Cinch::Plugin

      def initialize(*args)
        super
        @game = Game.new
 
        @changelog     = self.load_changelog

        @mods          = config[:mods]
        @channel_name  = config[:channel]
        @settings_file = config[:settings]
        @games_dir     = config[:games_dir]

        @idle_timer_length    = config[:allowed_idle]
        @invite_timer_length  = config[:invite_reset]

        @idle_timer   = self.start_idle_timer
      end

      # start 
      match /join/i,                 :method => :join
      match /leave/i,                :method => :leave
      match /start/i,                :method => :start_game
    
      # game    
      match /action (duke|ambassador|income|foreign_aid)/i,   :method => :do_action
      match /action (assassin|captain|coup) (.+)/i,           :method => :do_action
      match /block (duke|contessa|captain|ambassador)/i,      :method => :do_block
      match /pass/i,                 :method => :react_pass
      match /challenge/i,            :method => :react_challenge
      match /bs/i,                   :method => :react_challenge

      match /lose (1|2)/i,           :method => :flip_card  
      match /switch (([1-6]))/i,     :method => :switch_cards

      match /me$/i,                  :method => :whoami
      match /table$/i,               :method => :show_table
      match /who$/i,                 :method => :list_players

      # other
      match /invite/i,               :method => :invite
      match /subscribe/i,            :method => :subscribe
      match /unsubscribe/i,          :method => :unsubscribe
      match /help ?(.+)?/i,          :method => :help
      match /intro/i,                :method => :intro
      match /rules ?(.+)?/i,         :method => :rules
      match /changelog$/i,           :method => :changelog_dir
      match /changelog (\d+)/i,      :method => :changelog
      # match /about/i,              :method => :about
   
      # mod only commands
      match /reset/i,                :method => :reset_game
      match /replace (.+?) (.+)/i,   :method => :replace_user
      match /kick (.+)/i,            :method => :kick_user
      match /room (.+)/i,            :method => :room_mode
      # match /chars/i,              :method => :who_chars

      listen_to :join,               :method => :voice_if_in_game
      listen_to :leaving,            :method => :remove_if_not_started
      listen_to :op,                 :method => :devoice_everyone_on_start


      #--------------------------------------------------------------------------------
      # Listeners & Timers
      #--------------------------------------------------------------------------------
      
      def voice_if_in_game(m)
        if @game.has_player?(m.user)
          Channel(@channel_name).voice(m.user)
        end
      end

      def remove_if_not_started(m, user)
        if @game.not_started?
          self.remove_user_from_game(user)
        end
      end

      def devoice_everyone_on_start(m, user)
        if user == bot
          self.devoice_channel
        end
      end

      def start_idle_timer
        Timer(300) do
          @game.players.map{|p| p.user }.each do |user|
            user.refresh
            if user.idle > @idle_timer_length
              self.remove_user_from_game(user)
              user.send "You have been removed from the #{@channel_name} game due to inactivity."
            end
          end
        end
      end


      #--------------------------------------------------------------------------------
      # Main IRC Interface Methods
      #--------------------------------------------------------------------------------

      def join(m)
        # self.reset_timer(m)
        if Channel(@channel_name).has_user?(m.user)
          if @game.accepting_players? 
            added = @game.add_player(m.user)
            unless added.nil?
              Channel(@channel_name).send "#{m.user.nick} has joined the game (#{@game.players.count}/#{Game::MAX_PLAYERS})"
              Channel(@channel_name).voice(m.user)
            end
          else
            if @game.started?
              Channel(@channel_name).send "#{m.user.nick}: Game has already started."
            elsif @game.at_max_players?
              Channel(@channel_name).send "#{m.user.nick}: Game is at max players."
            else
              Channel(@channel_name).send "#{m.user.nick}: You cannot join."
            end
          end
        else
          User(m.user).send "You need to be in #{@channel_name} to join the game."
        end
      end

      def leave(m)
        if @game.accepting_players?
          left = @game.remove_player(m.user)
          unless left.nil?
            Channel(@channel_name).send "#{m.user.nick} has left the game (#{@game.players.count}/#{Game::MAX_PLAYERS})"
            Channel(@channel_name).devoice(m.user)
          end
        else
          if @game.started?
            m.reply "Game is in progress.", true
          end
        end
      end

      def start_game(m)
        unless @game.started?
          if @game.at_min_players?
            if @game.has_player?(m.user)
              @idle_timer.stop
              @game.start_game!

              Channel(@channel_name).send "The game has started."

              self.pass_out_characters

              Channel(@channel_name).send "Turn order is: #{@game.players.map{ |p| p.user.nick }.join(' ')}"
              Channel(@channel_name).send "FIRST TURN. Player: #{@game.current_player}. Please choose an action."
              #User(@game.team_leader.user).send "You are team leader. Please choose a team of #{@game.current_team_size} to go on first mission. \"!team#{team_example(@game.current_team_size)}\""
            else
              m.reply "You are not in the game.", true
            end
          else
            m.reply "Need at least #{Game::MIN_PLAYERS} to start a game.", true
          end
        end
      end

      #--------------------------------------------------------------------------------
      # Game interaction methods
      #--------------------------------------------------------------------------------

      # For use in tests, since @game is not exposed to tests
      def coins(p)
        @game.find_player(p).coins
      end

      # for use in tests
      def force_characters(p, c1, c2)
        @game.find_player(p).switch_character(Character.new(c1), 0)
        @game.find_player(p).switch_character(Character.new(c2), 1)
      end

      def pass_out_characters
        @game.players.each do |p|
          User(p.user).send "="*40
          self.tell_characters_to(p)
        end
      end

      def whoami(m)
        if @game.started? && @game.has_player?(m.user)
          player = @game.find_player(m.user)
          self.tell_characters_to(player)
        end
      end
      
      def tell_characters_to(player, tell_coins = true)
        character_1, character_2 = player.characters

        char1_str = character_1.face_down? ? "(#{character_1})" : "[#{character_1}]"
        char2_str = character_2.face_down? ? "(#{character_2})" : "[#{character_2}]"
        coins_str = tell_coins ? " - Coins: #{player.coins}" : ""
        User(player.user).send "#{char1_str} #{char2_str}#{coins_str}"
      end


      def do_action(m, action, target = "")
        if @game.started? && @game.has_player?(m.user)
          if @game.current_turn.waiting_for_action? && @game.current_player.user == m.user

            if target.empty?
              target_msg = ""
            else
              target_player = @game.find_player(target)
              if target_player.nil?
                User(m.user).send "\"#{target}\" is an invalid target."
              else
                target_msg = " on #{target}"
              end
            end

            unless target_msg.nil?
              Channel(@channel_name).send "#{m.user.nick} uses #{action.upcase}#{target_msg}"
              @game.current_turn.add_action(action, target_player)
              if @game.current_turn.action.needs_reactions?
                @game.current_turn.wait_for_reactions
                puts "==== Waiting for reactions"
              else 
                self.process_turn
              end
            end

          else
            User(m.user).send "You are not the current player."
          end
        end
      end

      def do_block(m, action)
        if @game.started? && @game.has_player?(m.user)
          player = @game.find_player(m.user)
          if @game.current_turn.waiting_for_reactions? && @game.reacting_players.include?(player)
            if @game.current_turn.action.blockable?
              if Game::ACTIONS[action.to_sym].blocks == @game.current_turn.action.action
                @game.current_turn.add_counteraction(action, player)
                Channel(@channel_name).send "#{m.user.nick} uses #{action.upcase}"
                @game.current_turn.wait_for_reactions
              else
                User(m.user).send "#{action.upcase} does not block that #{@game.current_turn.action.action.upcase}."
              end
            else
              User(m.user).send "#{@game.current_turn.action.action.upcase} cannot be blocked."
            end
          end
        end
      end

      def react_pass(m)
        if @game.started? && @game.has_player?(m.user)
          player = @game.find_player(m.user)
          if @game.current_turn.waiting_for_reactions? && @game.reacting_players.include?(player)
            @game.current_turn.pass(player)
            Channel(@channel_name).send "#{m.user.nick} passes."

            if @game.all_reactions_in?
              self.process_turn
            end
          end
        end
      end

      def react_challenge(m)
        if @game.started? && @game.has_player?(m.user)
          player = @game.find_player(m.user)
          if @game.current_turn.waiting_for_reactions? && @game.reacting_players.include?(player)
            chall_player = @game.current_turn.challengee_player
            chall_action = @game.current_turn.challengee_action

            if chall_action.character_required?
              @game.current_turn.pause
              Channel(@channel_name).send "#{m.user.nick} challenges #{chall_player} on #{chall_action.to_s.upcase}!"
              sleep 3
              if chall_player.has_character?(chall_action.action)
                Channel(@channel_name).send "... and #{chall_player} has a [#{chall_action.character_required.to_s.upcase}]. #{player} loses an influence."
                @game.replace_character_with_new(chall_player, chall_action.character_required)
                Channel(@channel_name).send "#{chall_player} switches the character card with one from the deck."
                self.tell_characters_to(chall_player, false)
                loser = player
              else 
                Channel(@channel_name).send "... and #{chall_player} does not have a [#{chall_action.character_required.to_s.upcase}]. #{chall_player} loses an influence."
                loser = chall_player
              end
              @game.current_turn.make_decider(loser)
              @game.current_turn.wait_for_decision
              self.prompt_to_flip(loser)
            else
              User(m.user).send "#{chall_action.action.upcase} cannot be challenged."
            end
          end
        end
      end

      def prompt_to_flip(target)
        if target.influence == 2
          character_1, character_2 = target.characters
          User(target.user).send "Choose a character to turn face up: 1 - (#{character_1}) or 2 - (#{character_2}); \"!lose 1\" or \"!lose 2\""
        else 
          character = target.characters.find{ |c| c.face_down? }
          i = target.characters.index(character)
          User(target.user).send "You only have one character left. #{i+1} - (#{character}); \"!lose #{i+1}\""
        end
      end

      def flip_card(m, position)
        if @game.started? && @game.has_player?(m.user)
          player = @game.find_player(m.user)
          if @game.current_turn.waiting_for_decision? && @game.current_turn.decider == player
            character = player.flip_character_card(position.to_i)
            Channel(@channel_name).send "#{m.user.nick} turns a #{character} face up."
            self.check_player_status(player)
            self.start_new_turn
          end
        end
      end

      def prompt_to_switch(target)
        @drawn_cards = @game.draw_cards(2)
        if target.influence == 2
          puts "="*80
          character_options = get_switch_options(@drawn_cards)
          puts character_options.inspect
          puts "="*80
          User(target.user).send "Choose an option for a new hand; \"!switch #\""
          character_options.each_with_index do |option, i|
            User(target.user).send "#{i+1} - " + option.map{ |o| "[#{o}]" }.join(" ")
          end
        else 
        #   character = target.characters.find{ |c| c.face_down? }
        #   i = target.characters.index(character)
        #   User(target.user).send "You only have one character left. #{i+1} - (#{character}); \"!lose #{i+1}\""
        end
      end

      def switch_cards(m, choice)
        if @game.started? && @game.has_player?(m.user)
          player = @game.find_player(m.user)
          if @game.current_turn.waiting_for_decision? && @game.current_turn.decider == player

            character = player.switch_cards(position.to_i)
            Channel(@channel_name).send "#{m.user.nick} turns a #{character} face up."

            self.start_new_turn
          end
        end
      end

      def get_switch_options(new_cards)
        (target.characters + new_cards).combination(2).to_a.uniq{ |p| p || p.reverse }.shuffle
      end

      def show_table(m)
        @game.players.each do |p|
          character_1, character_2 = p.characters

          char1_str = character_1.face_down? ? "(########)" : "[#{character_1}]"
          char2_str = character_2.face_down? ? "(########)" : "[#{character_2}]"
          m.reply "#{dehighlight_nick(p.to_s)}: #{char1_str} #{char2_str} - Coins: #{p.coins}"
        end
        unless @game.discard_pile.empty?
          discards = @game.discard_pile.map{ |c| "[#{c}]" }.join(" ")
          m.reply "Discard Pile: #{discards}"
        end
      end

      def check_player_status(player)
        unless player.has_influence?
          Channel(@channel_name).send "#{player} has no more influence, and is out of the game."
          @game.discard_characters_for(player)
          left = @game.remove_player(player.user)
          unless left.nil?
            Channel(@channel_name).devoice(player.user)
          end
          self.check_game_state 
        end
      end

      def process_turn
        turn = @game.current_turn
        if turn.counteracted? 
          Channel(@channel_name).send "#{turn.active_player}'s #{turn.action.action.upcase} was blocked by #{turn.counteracting_player} with #{turn.counteraction.action.upcase}."
          self.start_new_turn
        else
          target_msg = turn.target_player.nil? ? "" : ": #{turn.target_player}"
          Channel(@channel_name).send "#{@game.current_player} proceeds with #{turn.action.action.upcase}. #{turn.action.effect}#{target_msg}."
          @game.process_current_turn
          if turn.action.needs_decision?
            turn.wait_for_decision
            if turn.action.action == :coup || turn.action.action == :assassin
              self.prompt_to_flip(turn.target_player)
            elsif turn.action.action == :ambassador
              self.prompt_to_switch(turn.active_player)
            end
          else
            self.start_new_turn
          end
        end
      end

      def start_new_turn
        @game.next_turn
        Channel(@channel_name).send "#{@game.current_player}: It is your turn. Please choose an action."
      end


      def check_game_state
        if @game.is_over?
          self.do_end_game
        else
          self.start_new_turn
        end
      end

      def do_end_game
        Channel(@channel_name).send "Game is over! #{@game.winner} wins!"
        self.start_new_game
      end

      def start_new_game
        Channel(@channel_name).moderated = false
        @game.players.each do |p|
          Channel(@channel_name).devoice(p.user)
        end
        @game = Game.new
        @idle_timer.start
      end



      def list_players(m)
        if @game.players.empty?
          m.reply "No one has joined the game yet."
        else
          m.reply @game.players.map{ |p| dehighlight_nick(p.to_s) }.join(' ')
        end
      end

      def devoice_channel
        Channel(@channel_name).voiced.each do |user|
          Channel(@channel_name).devoice(user)
        end
      end

      def remove_user_from_game(user)
        if @game.not_started?
          left = @game.remove_player(user)
          unless left.nil?
            Channel(@channel_name).send "#{user.nick} has left the game (#{@game.players.count}/#{Game::MAX_PLAYERS})"
            Channel(@channel_name).devoice(user)
          end
        end
      end

      def dehighlight_nick(nickname)
        nickname.chars.to_a.join(8203.chr('UTF-8'))
      end

      #--------------------------------------------------------------------------------
      # Mod commands
      #--------------------------------------------------------------------------------

      def is_mod?(nick)
        # make sure that the nick is in the mod list and the user in authenticated 
        user = User(nick) 
        user.authed? && @mods.include?(user.authname)
      end

      def reset_game(m)
        if self.is_mod? m.user.nick
          if @game.started?
            spies, resistance = get_loyalty_info
            Channel(@channel_name).send "The spies were: #{spies.join(", ")}"
            Channel(@channel_name).send "The resistance were: #{resistance.join(", ")}"
          end
          @game = Game.new
          self.devoice_channel
          Channel(@channel_name).send "The game has been reset."
          @idle_timer.start
        end
      end

      def kick_user(m, nick)
        if self.is_mod? m.user.nick
          if @game.not_started?
            user = User(nick)
            left = @game.remove_player(user)
            unless left.nil?
              Channel(@channel_name).send "#{user.nick} has left the game (#{@game.players.count}/#{Game::MAX_PLAYERS})"
              Channel(@channel_name).devoice(user)
            end
          else
            User(m.user).send "You can't kick someone while a game is in progress."
          end
        end
      end

      def replace_user(m, nick1, nick2)
        if self.is_mod? m.user.nick
          # find irc users based on nick
          user1 = User(nick1)
          user2 = User(nick2)
          
          # replace the users for the players
          player = @game.find_player(user1)
          player.user = user2

          # devoice/voice the players
          Channel(@channel_name).devoice(user1)
          Channel(@channel_name).voice(user2)

          # inform channel
          Channel(@channel_name).send "#{user1.nick} has been replaced with #{user2.nick}"

          # tell loyalty to new player
          User(player.user).send "="*40
          self.tell_loyalty_to(player)
        end
      end

      def room_mode(m, mode)
        if self.is_mod? m.user.nick
          case mode
          when "silent"
            Channel(@channel_name).moderated = true
          when "vocal"
            Channel(@channel_name).moderated = false
          end
        end
      end


      #--------------------------------------------------------------------------------
      # Helpers
      #--------------------------------------------------------------------------------

      def help(m, page)
        if page.to_s.downcase == "mod" && self.is_mod?(m.user.nick)
          User(m.user).send "--- HELP PAGE MOD ---"
          User(m.user).send "!reset - completely resets the game to brand new"
          User(m.user).send "!replace nick1 nick1 - replaces a player in-game with a player out-of-game"
          User(m.user).send "!kick nick1 - removes a presumably unresponsive user from an unstarted game"
          User(m.user).send "!room silent|vocal - switches the channel from voice only users and back"
        else 
          case page
          when "2"
            User(m.user).send "--- HELP PAGE 2/3 ---"
          when "3"
            User(m.user).send "--- HELP PAGE 3/3 ---"
            User(m.user).send "!rules - provides rules for the game"
            User(m.user).send "!subscribe - subscribe your current nick to receive PMs when someone calls !invite"
            User(m.user).send "!unsubscribe - remove your nick from the invitation list"
            User(m.user).send "!invite - invites #boardgames and subscribers to join the game"
            User(m.user).send "!changelog (#) - shows changelog for the bot, when provided a number it showed details"
          else
            User(m.user).send "--- HELP PAGE 1/3 ---"
            User(m.user).send "!join - joins the game"
            User(m.user).send "!leave - leaves the game"
            User(m.user).send "!start - starts the game"

            User(m.user).send "!help (#) - when provided a number, pulls up specified page"
          end
        end
      end

      def intro(m)
        User(m.user).send "Welcome to CoupBot. You can join a game if there's one getting started with the command \"!join\". For more commands, type \"!help\". If you don't know how to play, you can read a rules summary with \"!rules\". If already know how to play, great. But there's a few things you should know."
      end

      def rules(m)
        User(m.user).send "You are head of a family in an Italian city-state, a city run by a weak and corrupt court. You need to manipulate, bluff and bribe your way to power. Your object is to destroy the influence of all the other families, forcing them into exile. Only one family will survive..."
        User(m.user).send "In Coup, you want to be the last player with influence in the game, with influence being represented by face-down character cards in your playing area."
        User(m.user).send "Each player starts the game with two coins and two influence - i.e., two face-down character cards; the fifteen card deck consists of three copies of five different characters, each with a unique set of powers:"
        User(m.user).send "  * Duke: Take three coins from the treasury. Block someone from take foreign aid."
        User(m.user).send "  * Assassin: Pay three coins and try to assassinate another player's character."
        User(m.user).send "  * Contessa: Block an assassination attempt."
        User(m.user).send "  * Captain: Take two coins from another player, or block someone from stealing coins from you."
        User(m.user).send "  * Ambassador: Draw two character cards from the Court (the deck), choose which (if any) to exchange with your face-down characters, then return two. Block someone from stealing coins from you."
        User(m.user).send "On your turn, you can take any of the actions listed above, regardless of which characters you actually have in front of you, or you can take one of three other actions:"
        User(m.user).send "  * Income: Take one coin from the treasury."
        User(m.user).send "  * Foreign aid: Take two coins from the treasury."
        User(m.user).send "  * Coup: Pay seven coins and launch a coup against an opponent, forcing that player to lose an influence. (If you have ten coins, you must take this action.)"
        User(m.user).send "When you take one of the character actions - whether actively on your turn, or defensively in response to someone else\'s action - that character\'s action automatically succeeds unless an opponent challenges you. In this case, if you can\'t reveal the appropriate character, you lose an influence, turning one of your characters face-up. Face-up characters cannot be used, and if both of your characters are face-up, you\'re out of the game."
        User(m.user).send "If you do have the character in question, you reveal it, the opponent loses an influence, then you shuffle that character into the deck and draw a new one, perhaps getting the same character again and perhaps not."
        User(m.user).send "The last player to still have influence - that is, a face-down character - wins the game!"
      end

      def list_players(m)
        if @game.players.empty?
          m.reply "No one has joined the game yet."
        else
          m.reply @game.players.map{ |p| p == @game.hammer ? "#{dehighlight_nick(p.user.nick)}*" : dehighlight_nick(p.user.nick) }.join(' ')
        end
      end

      def status(m)
        if @game.started?
            # status = "Waiting on players to PASS or CHALLENGE: #{self.not_back_from_mission.map(&:user).join(", ")}"
        else
          if @game.player_count.zero?
            status = "No game in progress."
          else
            status = "Game being started. #{player_count} players have joined: #{self.players.map(&:user).join(", ")}"
          end
        end
        m.reply status
      end

      def changelog_dir(m)
        @changelog.first(5).each_with_index do |changelog, i|
          User(m.user).send "#{i+1} - #{changelog["date"]} - #{changelog["changes"].length} changes" 
        end
      end

      def changelog(m, page = 1)
        changelog_page = @changelog[page.to_i-1]
        User(m.user).send "Changes for #{changelog_page["date"]}:"
        changelog_page["changes"].each do |change|
          User(m.user).send "- #{change}"
        end
      end

      def invite(m)
        if @game.accepting_players?
          if @game.invitation_sent?
            m.reply "An invitation cannot be sent out again so soon."
          else      
            @game.mark_invitation_sent
            User("BG3PO").send "!invite_to_coup_game"
            User(m.user).send "Invitation has been sent."

            settings = load_settings || {}
            subscribers = settings["subscribers"]
            current_players = @game.players.map{ |p| p.user.nick }
            subscribers.each do |subscriber|
              unless current_players.include? subscriber
                User(subscriber).refresh
                if User(subscriber).online?
                  User(subscriber).send "A game of Coup is gathering in #playcoup ..."
                end
              end
            end

            # allow for reset after provided time
            Timer(@invite_timer_length, shots: 1) do
              @game.reset_invitation
            end
          end
        end
      end

      def subscribe(m)
        settings = load_settings || {}
        subscribers = settings["subscribers"] || []
        if subscribers.include?(m.user.nick)
          User(m.user).send "You are already subscribed to the invitation list."
        else
          if User(m.user).authed?
            subscribers << m.user.nick 
            settings["subscribers"] = subscribers
            save_settings(settings)
            User(m.user).send "You've been subscribed to the invitation list."
          else
            User(m.user).send "Whoops. You need to be identified on freenode to be able to subscribe. Either identify (\"/msg Nickserv identify [password]\") if you are registered, or register your account (\"/msg Nickserv register [email] [password]\")"
            User(m.user).send "See http://freenode.net/faq.shtml#registering for help"
          end
        end
      end

      def unsubscribe(m)
        settings = load_settings || {}
        subscribers = settings["subscribers"] || []
        if subscribers.include?(m.user.nick)
          if User(m.user).authed?
            subscribers.delete_if{ |sub| sub == m.user.nick }
            settings["subscribers"] = subscribers
            save_settings(settings)
            User(m.user).send "You've been unsubscribed to the invitation list."
          else
            User(m.user).send "Whoops. You need to be identified on freenode to be able to unsubscribe. Either identify (\"/msg Nickserv identify [password]\") if you are registered, or register your account (\"/msg Nickserv register [email] [password]\")"
            User(m.user).send "See http://freenode.net/faq.shtml#registering for help"
          end
        else
          User(m.user).send "You are not subscribed to the invitation list."
        end
      end


      #--------------------------------------------------------------------------------
      # Settings
      #--------------------------------------------------------------------------------
      
      def save_settings(settings)
        output = File.new(@settings_file, 'w')
        output.puts YAML.dump(settings)
        output.close
      end

      def load_settings
        output = File.new(@settings_file, 'r')
        settings = YAML.load(output.read)
        output.close

        settings
      end

      def load_changelog
        output = File.new(CHANGELOG_FILE, 'r')
        changelog = YAML.load(output.read)
        output.close

        changelog
      end


    end
    
  end
end
