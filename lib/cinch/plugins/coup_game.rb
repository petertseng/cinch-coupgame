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

    ACTION_ALIASES = {
      'foreign aid' => 'foreign_aid',
      'tax' => 'duke',
      'assassinate' => 'assassin',
      'kill' => 'assassin',
      'steal' => 'captain',
      'extort' => 'captain',
      'exchange' => 'ambassador',
    }

    # Length of the longest character's name (Ambassador / Inquisitor)
    LONGEST_NAME = 10

    class CoupGame
      include Cinch::Plugin

      def initialize(*args)
        super
        @changelog     = self.load_changelog

        @mods          = config[:mods]
        @channel_names = config[:channels]
        @settings_file = config[:settings]
        @games_dir     = config[:games_dir]

        @idle_timer_length    = config[:allowed_idle]
        @invite_timer_length  = config[:invite_reset]

        @games = {}
        @idle_timers = {}
        @channel_names.each { |c|
          @games[c] = Game.new(c)
          @idle_timers[c] = self.start_idle_timer(c)
        }

        @user_games = {}

        @forced_id = 16
      end

      def self.xmatch(regex, args)
        match(regex, args.dup)
        args[:prefix] = lambda { |m| m.bot.nick + ': ' }
        match(regex, args.dup)
        args[:react_on] = :private
        args[:prefix] = /^/
        match(regex, args.dup)
      end

      # start 
      xmatch /join(?:\s*(##?\w+))?/i, :method => :join
      xmatch /leave/i,                :method => :leave
      xmatch /start/i,                :method => :start_game
    
      # game    
      xmatch /(?:action )?(duke|tax|ambassador|exchange|income|foreign(?: |_)aid)/i, :method => :do_action
      xmatch /(?:action )?(assassin(?:ate)?|kill|captain|steal|extort|coup|inquisitor)(?: (.+))?/i, :method => :do_action
      xmatch /block (duke|contessa|captain|ambassador|inquisitor)/i, :method => :do_block
      xmatch /pass/i,                 :method => :react_pass
      xmatch /challenge/i,            :method => :react_challenge
      xmatch /bs/i,                   :method => :react_challenge

      xmatch /flip (1|2)/i,           :method => :flip_card
      xmatch /lose (1|2)/i,           :method => :flip_card
      xmatch /switch (([1-6]))/i,     :method => :switch_cards

      xmatch /show (1|2)/i,           :method => :show_to_inquisitor
      xmatch /keep/i,                 :method => :inquisitor_keep
      xmatch /discard/i,              :method => :inquisitor_discard

      xmatch /pick (([1-5]))/i,       :method => :pick_card

      xmatch /me$/i,                  :method => :whoami
      xmatch /table(?:\s*(##?\w+))?/i,:method => :show_table
      xmatch /who$/i,                 :method => :list_players
      xmatch /status$/i,              :method => :status

      # other
      xmatch /invite/i,               :method => :invite
      xmatch /subscribe/i,            :method => :subscribe
      xmatch /unsubscribe/i,          :method => :unsubscribe
      xmatch /help ?(.+)?/i,          :method => :help
      xmatch /intro/i,                :method => :intro
      xmatch /rules ?(.+)?/i,         :method => :rules
      xmatch /changelog$/i,           :method => :changelog_dir
      xmatch /changelog (\d+)/i,      :method => :changelog
      # xmatch /about/i,              :method => :about

      xmatch /settings(?:\s+(##?\w+))?$/i,     :method => :get_game_settings
      xmatch /settings(?:\s+(##?\w+))? (.+)/i, :method => :set_game_settings
   
      # mod only commands
      xmatch /reset(?:\s+(##?\w+))?/i,        :method => :reset_game
      xmatch /replace (.+?) (.+)/i,           :method => :replace_user
      xmatch /kick(?:\s+(##?\w+))?\s+(.+)/i,  :method => :kick_user
      xmatch /room(?:\s+(##?\w+))?\s+(.+)/i,  :method => :room_mode
      xmatch /chars(?:\s+(##?\w+))?/i,        :method => :who_chars

      listen_to :join,               :method => :voice_if_in_game
      listen_to :leaving,            :method => :remove_if_not_started
      listen_to :op,                 :method => :devoice_everyone_on_start


      #--------------------------------------------------------------------------------
      # Listeners & Timers
      #--------------------------------------------------------------------------------
      
      def voice_if_in_game(m)
        game = @games[m.channel.name]
        m.channel.voice(m.user) if game && game.has_player?(m.user)
      end

      def remove_if_not_started(m, user)
        game = @games[m.channel.name]
        self.remove_user_from_game(user, game) if game.not_started?
      end

      def devoice_everyone_on_start(m, user)
        if user == bot
          self.devoice_channel(m.channel)
        end
      end

      def start_idle_timer(channel_name)
        Timer(300) do
          game = @games[channel_name]
          game.players.map{|p| p.user }.each do |user|
            user.refresh
            if user.idle > @idle_timer_length
              self.remove_user_from_game(user, game) if game.not_started?
              user.send "You have been removed from the #{channel_name} game due to inactivity."
            end
          end
        end
      end


      #--------------------------------------------------------------------------------
      # Main IRC Interface Methods
      #--------------------------------------------------------------------------------

      def join(m, channel_name = nil)
        channel = channel_name ? Channel(channel_name) : m.channel

        unless channel
          m.reply('To join a game via PM you must specify the channel: ' +
                  '!join #channel')
          return
        end

        # self.reset_timer(m)
        game = @games[channel.name]
        unless game
          m.reply(channel.name + ' is not a valid channel to join', true)
          return
        end

        if channel.has_user?(m.user)
          if (game2 = @user_games[m.user])
            m.reply("You are already in the #{game2.channel_name} game", true)
            return
          end

          if game.accepting_players? 
            added = game.add_player(m.user)
            unless added.nil?
              channel.send "#{m.user.nick} has joined the game (#{game.players.count}/#{Game::MAX_PLAYERS})"
              channel.voice(m.user)
              @user_games[m.user] = game
            end
          else
            if game.started?
              m.reply('Game has already started.', true)
            elsif game.at_max_players?
              m.reply('Game is at max players.', true)
            else
              m.reply('You cannot join.', true)
            end
          end
        else
          User(m.user).send "You need to be in #{channel.name} to join the game."
        end
      end

      def leave(m)
        game = self.game_of(m)
        return unless game

        if game.accepting_players?
          self.remove_user_from_game(m.user, game)
        else
          if game.started?
            m.reply "Game is in progress.", true
          end
        end
      end

      def start_game(m)
        game = self.game_of(m)
        return unless game

        unless game.started?
          if game.at_min_players?
            if game.has_player?(m.user)
              @idle_timers[game.channel_name].stop
              game.start_game!

              Channel(game.channel_name).send "The game has started."

              self.pass_out_characters(game)

              Channel(game.channel_name).send "Turn order is: #{game.players.map{ |p| p.user.nick }.join(' ')}"

              if game.players.size == 2
                Channel(game.channel_name).send('This is a two-player game. Both players have received their first character card and must now pick their second.')
                game.current_turn.wait_for_initial_characters
              else
                Channel(game.channel_name).send "FIRST TURN. Player: #{game.current_player}. Please choose an action."
              end
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
        game = @user_games[User(p)]
        game.find_player(p).coins
      end

      # for use in tests
      def force_characters(p, c1, c2)
        game = @user_games[User(p)]
        if c1
          game.find_player(p).switch_character(Character.new(@forced_id, c1), 0)
          @forced_id += 1
        end
        if c2
          game.find_player(p).switch_character(Character.new(@forced_id, c2), 1)
          @forced_id += 1
        end
      end

      def pass_out_characters(game)
        game.players.each do |p|
          User(p.user).send "="*40
          self.tell_characters_to(p, true, false)
        end

        if game.players.size == 2
          game.players.each do |p|
            chars = p.side_cards.each_with_index.map { |char, i|
              "#{i + 1} - (#{char.to_s})"
            }.join(' ')
            p.user.send(chars)
            p.user.send('Choose a second character card with "!pick #". The other four characters will not be used this game, and only you will know what they are.')
          end
        end
      end

      def whoami(m)
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          player = game.find_player(m.user)
          self.tell_characters_to(player)
        end
      end
      
      def tell_characters_to(player, tell_coins = true, tell_side = true)
        character_1, character_2 = player.characters

        char1_str = character_1.face_down? ? "(#{character_1})" : "[#{character_1}]"
        if character_2
          char2_str = character_2.face_down? ? " (#{character_2})" : " [#{character_2}]"
        else
          char2_str = ''
        end

        coins_str = tell_coins ? " - Coins: #{player.coins}" : ""
        if tell_side && !player.side_cards.empty?
          chars = player.side_cards.collect { |c| "(#{c.to_s})" }.join(' ')
          side_str = ' - Set aside: ' + chars
        else
          side_str = ''
        end
        User(player.user).send "#{char1_str}#{char2_str}#{coins_str}#{side_str}"
      end


      def do_action(m, action, target = "")
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          if game.current_turn.waiting_for_action? && game.current_player.user == m.user

            action = ACTION_ALIASES[action.downcase] || action.downcase

            if game.current_player.coins >= 10 && action.upcase != "COUP"
              m.user.send "Since you have 10 coins, you must use COUP. !action coup <target>"
              return
            end

            if (mf = Game::ACTIONS[action.to_sym].mode_forbidden) && game.settings.include?(mf)
              m.user.send("#{action.upcase} may not be used if the game type is #{mf.to_s.capitalize}.")
              return
            end
            if (mr = Game::ACTIONS[action.to_sym].mode_required) && !game.settings.include?(mr)
              m.user.send("#{action.upcase} may only be used if the game type is #{mr.to_s.capitalize}.")
              return
            end

            if target.nil? || target.empty?
              target_msg = ""

              if Game::ACTIONS[action.to_sym].needs_target
                m.user.send("You must specify a target for #{action.upcase}: !action #{action} <playername>")
                return
              end
            else
              target_player = game.find_player(target)

              # No self-targeting!
              if target_player == game.current_player && !Game::ACTIONS[action.to_sym].self_targettable
                m.user.send("You may not target yourself with #{action.upcase}.")
                return
              end

              if target_player.nil?
                User(m.user).send "\"#{target}\" is an invalid target."
              else
                target_msg = " on #{target}"
              end

              unless game.is_enemy?(game.current_player, target_player)
                us = Game::FACTIONS[game.current_player.faction]
                them = Game::FACTIONS[1 - game.current_player.faction]
                m.user.send("You cannot target a fellow #{us} with #{action.upcase} while the #{them} exist!")
                return
              end
            end

            unless target_msg.nil?
              cost = Game::ACTIONS[action.to_sym].cost
              if game.current_player.coins < cost
                coins = game.current_player.coins
                m.user.send "You need #{cost} coins to use #{action.upcase}, but you only have #{coins} coins."
                return
              end

              Channel(game.channel_name).send "#{m.user.nick} uses #{action.upcase}#{target_msg}"
              game.current_turn.add_action(action, target_player)
              if game.current_turn.action.character_required?
                game.current_turn.wait_for_action_challenge
                self.prompt_challengers(game)
              elsif game.current_turn.action.blockable?
                game.current_turn.wait_for_block
                self.prompt_blocker(game)
              else 
                self.process_turn(game)
              end
            end

          else
            User(m.user).send "You are not the current player."
          end
        end
      end

      def prompt_challengers(game)
        Channel(game.channel_name).send('All other players: Would you like to challenge ("!challenge") or not ("!pass")?')
      end

      def prompt_blocker(game)
        action = game.current_turn.action
        blockers = action.blockable_by.select { |c|
          game.action_usable?(Game::ACTIONS[c])
        }.collect { |c|
          "\"!block #{c.to_s.downcase}\""
        }.join(' or ')
        if action.needs_target
          prefix = game.current_turn.target_player.to_s
        else
          prefix = 'All other players'
        end
        Channel(game.channel_name).send("#{prefix}: Would you like to block the #{action.action.to_s.upcase} (#{blockers}) or not (\"!pass\")?")
      end

      def do_block(m, action)
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          player = game.find_player(m.user)
          if game.current_turn.waiting_for_block? && game.reacting_players.include?(player)
            if game.current_turn.action.blockable?
              if (mf = Game::ACTIONS[action.to_sym].mode_forbidden) && game.settings.include?(mf)
                m.user.send("#{action.upcase} may not be used if the game type is #{mf.to_s.capitalize}.")
                return
              end
              if (mr = Game::ACTIONS[action.to_sym].mode_required) && !game.settings.include?(mr)
                m.user.send("#{action.upcase} may only be used if the game type is #{mr.to_s.capitalize}.")
                return
              end

              unless game.is_enemy?(player, game.current_turn.active_player)
                us = Game::FACTIONS[game.current_player.faction]
                them = Game::FACTIONS[1 - game.current_player.faction]
                m.user.send("You cannot block a fellow #{us}'s #{game.current_turn.action.action.upcase} while the #{them} exist!")
                return
              end

              if Game::ACTIONS[action.to_sym].blocks == game.current_turn.action.action
                if game.current_turn.action.needs_target && m.user != game.current_turn.target_player.user
                  m.user.send "You can only block with #{action.upcase} if you are the target."
                  return
                end
                game.current_turn.add_counteraction(action, player)
                Channel(game.channel_name).send "#{m.user.nick} uses #{action.upcase} to block #{game.current_turn.action.action.upcase}"
                self.prompt_challengers(game)
                game.current_turn.wait_for_block_challenge
              else
                User(m.user).send "#{action.upcase} does not block that #{game.current_turn.action.action.upcase}."
              end
            else
              User(m.user).send "#{game.current_turn.action.action.upcase} cannot be blocked."
            end
          end
        end
      end

      def react_pass(m)
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          player = game.find_player(m.user)
          turn = game.current_turn
          if turn.waiting_for_challenges? && game.reacting_players.include?(player)
            success = game.current_turn.pass(player)
            Channel(game.channel_name).send "#{m.user.nick} passes." if success

            if game.all_reactions_in?
              if turn.waiting_for_action_challenge?
                # Nobody wanted to challenge the actor.
                if game.current_turn.action.blockable?
                  # If action is blockable, ask for block now.
                  game.current_turn.wait_for_block
                  self.prompt_blocker(game)
                else
                  # If action is unblockable, process turn.
                  self.process_turn(game)
                end
              elsif turn.waiting_for_block_challenge?
                # Nobody challenges blocker. Process turn.
                self.process_turn(game)
              end
            end
          elsif turn.waiting_for_block?
            if turn.action.needs_target && turn.target_player == player
              # Blocker didn't want to block. Process turn.
              Channel(game.channel_name).send "#{m.user.nick} passes."
              self.process_turn(game)
            elsif !turn.action.needs_target
              # This blocker didn't want to block, but maybe someone else will
              success = game.current_turn.pass(player)
              Channel(game.channel_name).send "#{m.user.nick} passes." if success
              # So we wait until all reactions are in.
              self.process_turn(game) if game.all_reactions_in?
            end
          end
        end
      end

      def react_challenge(m)
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          player = game.find_player(m.user)
          if game.current_turn.waiting_for_challenges? && game.reacting_players.include?(player)
            chall_player = game.current_turn.challengee_player
            chall_action = game.current_turn.challengee_action

            if chall_action.character_required?
              Channel(game.channel_name).send "#{m.user.nick} challenges #{chall_player} on #{chall_action.to_s.upcase}!"

              # Prompt player if he has a choice
              self.prompt_challenge_defendant(chall_player, chall_action) if chall_player.influence == 2

              if game.current_turn.waiting_for_action_challenge?
                game.current_turn.wait_for_action_challenge_reply
                game.current_turn.action_challenger = player
              elsif game.current_turn.waiting_for_block_challenge?
                game.current_turn.wait_for_block_challenge_reply
                game.current_turn.block_challenger = player
              end

              # If he doesn't have a choice, just sleep 3 seconds and make the choice for him.
              if chall_player.influence == 1
                sleep(3)
                i = chall_player.characters.index { |c| c.face_down? }
                self.respond_to_challenge(game, chall_player, i + 1, chall_action, player)
              end

            else
              User(m.user).send "#{chall_action.action.upcase} cannot be challenged."
            end
          end
        end
      end

      def prompt_challenge_defendant(target, action)
        user = User(target.user)
        user.send("You are being challenged to show a #{action}!")
        if target.influence == 2
          character_1, character_2 = target.characters
          user.send("Choose a character to reveal: 1 - (#{character_1}) or 2 - (#{character_2}); \"!flip 1\" or \"!flip 2\"")
        else
          character = target.characters.find{ |c| c.face_down? }
          i = target.characters.index(character)
          user.send("You only have one character left. #{i+1} - (#{character}); \"!flip #{i+1}\"")
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
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          player = game.find_player(m.user)
          turn = game.current_turn

          if turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :lose_influence
            self.couped(game, player, position)
          elsif turn.waiting_for_action_challenge_reply? && turn.active_player == player
            self.respond_to_challenge(game, player, position, turn.action, turn.action_challenger)
          elsif turn.waiting_for_block_challenge_reply? && turn.counteracting_player == player
            self.respond_to_challenge(game, player, position, turn.counteraction, turn.block_challenger)
          elsif turn.waiting_for_action_challenge_loser? && turn.action_challenger == player
            self.lose_challenge(game, player, position)
          elsif turn.waiting_for_block_challenge_loser? && turn.block_challenger == player
            self.lose_challenge(game, player, position)
          end
        end
      end

      # Couped, or assassinated
      def couped(game, player, position)
        character = player.flip_character_card(position.to_i)
        if character.nil?
          player.user.send "You have already flipped that card."
          return
        end

        Channel(game.channel_name).send "#{player.user} loses influence over a [#{character}]."
        self.check_player_status(game, player)
        # If I haven't started a new game, start a new turn
        self.start_new_turn(game) unless game.is_over?
      end

      def lose_challenge(game, player, position)
        pos = position.to_i
        unless pos == 1 || pos == 2
          player.user.send("#{pos} is not a valid option to reveal.")
          return
        end

        character = player.flip_character_card(pos)
        if character.nil?
          player.user.send "You have already flipped that card."
          return
        end

        Channel(game.channel_name).send "#{player.user} loses influence over a [#{character}]."

        self.check_player_status(game, player)

        turn = game.current_turn

        if turn.waiting_for_action_challenge_loser?
          # The action challenge fails. The original action holds.
          # We now need to ask for the blocker, if any.
          if turn.action.blockable?
            # In a double-kill, losing challenge may kill the blocker.
            # If he's dead, just skip to processing turn.
            if turn.target_player.has_influence?
              turn.wait_for_block
              self.prompt_blocker(game)
            else
              self.process_turn(game)
            end
          else
            self.process_turn(game)
          end
        elsif turn.waiting_for_block_challenge_loser?
          # The block challenge fails. The block holds.
          # Finish the turn.
          self.process_turn(game)
        else
          raise "lose_challenge in #{turn.state}"
        end
      end


      def respond_to_challenge(game, player, position, action, challenger)
        pos = position.to_i
        unless pos == 1 || pos == 2
          player.user.send("#{pos} is not a valid option to reveal.")
          return
        end

        revealed = player.characters[pos - 1]
        unless revealed.face_down?
          player.user.send('You have already flipped that card.')
          return
        end

        turn = game.current_turn

        if revealed.to_s == action.character_required.to_s.upcase
          Channel(game.channel_name).send "#{player} reveals a [#{action.character_required.to_s.upcase}] and replaces it with a new card from the Court Deck."
          game.replace_character_with_new(player, action.character_required)
          Channel(game.channel_name).send "#{challenger} loses influence for losing the challenge!"
          self.tell_characters_to(player, false)
          turn.wait_for_challenge_loser
          if challenger.influence == 2
            self.prompt_to_flip(challenger)
          else
            i = challenger.characters.index { |c| c.face_down? }
            self.lose_challenge(game, challenger, i + 1)
          end
        else
          Channel(game.channel_name).send "#{player} reveals a [#{revealed}]. That's not a #{action.character_required.to_s.upcase}! #{player} loses the challenge!"
          Channel(game.channel_name).send "#{player} loses influence over the [#{revealed}] and cannot use the #{action.character_required.to_s.upcase}."
          revealed.flip_up
          self.check_player_status(game, player)
          if turn.waiting_for_action_challenge_reply?
            # The action challenge succeeds, interrupting the action.
            # We don't need to ask for a block. Just finish the turn.
            turn.action_challenge_successful = true
            self.process_turn(game)
          elsif turn.waiting_for_block_challenge_reply?
            # The block challenge succeeds, interrupting the block.
            # That means the original action holds. Finish the turn.
            turn.block_challenge_successful = true
            self.process_turn(game)
          else
            raise "respond_to_challenge in #{turn.state}"
          end
        end
      end

      def prompt_to_switch(game, target, cards = 2)
        game.ambassador_cards = game.draw_cards(cards)
        card_names = game.ambassador_cards.collect { |c| c.to_s }.join(' and ')
        User(target.user).send "You drew #{card_names} from the Court Deck."

        fmt = "%#{LONGEST_NAME + 2}s"
        if target.influence == 2 || target.influence == 1
          game.ambassador_options = get_switch_options(target, game.ambassador_cards)
          User(target.user).send "Choose an option for a new hand; \"!switch #\""
          game.ambassador_options.each_with_index do |option, i|
            User(target.user).send "#{i+1} - " + option.map{ |o|
              fmt % ["(#{o})"]
            }.join(" ")
          end
        else 
          raise "Invalid target influence #{target.influence}"
        end
      end

      def switch_cards(m, choice)
        game = self.game_of(m)
        return unless game

        if game.started? && game.has_player?(m.user)
          player = game.find_player(m.user)
          turn = game.current_turn

          if turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :switch_cards
            facedown_indices = [0, 1].select { |i|
              player.characters[i].face_down?
            }
            facedowns = facedown_indices.collect { |i| player.characters[i] }
            cards_to_return = facedowns + game.ambassador_cards

            choice = choice.to_i
            if 1 <= choice && choice <= game.ambassador_options.size
              card_ids = Hash.new(0)
              new_hand = game.ambassador_options[choice - 1]
              # Remove the new hand from cards_to_return
              new_hand.each { |c|
                card_index = cards_to_return.index(c)
                cards_to_return.delete_at(card_index)
                card_ids[c.id] += 1
              }

              # Sanity check to make sure all cards are unique (no shared references)
              cards_to_return.each { |c| card_ids[c.id] += 1 }

              all_unique = card_ids.to_a.all? { |c| c[1] == 1 }
              unless all_unique
                Channel(game.channel_name).send("WARNING!!! Card IDs not unique. Game will probably be bugged. See console output.")
                puts card_ids
              end

              facedown_indices.each_with_index { |i, j|
                # If they have two facedowns, this will switch both.
                # If they have one facedown,
                # this will switch their one facedown with the card they picked
                player.switch_character(new_hand[j], i)
              }

              game.shuffle_into_deck(*cards_to_return)
              num_cards = cards_to_return.size == 1 ? 'a card' : 'two cards'
              Channel(game.channel_name).send "#{m.user.nick} shuffles #{num_cards} into the Court Deck."
              returned_names = cards_to_return.collect { |c| "(#{c})" }.join(' and ')
              m.user.send("You returned #{returned_names} to the Court Deck.")

              self.start_new_turn(game)
            else
              User(player.user).send "#{choice} is not a valid choice"
            end
          end
        end
      end

      def get_switch_options(target, new_cards)
        if target.influence == 2
          (target.characters + new_cards).combination(2).to_a.uniq{ |p| p || p.reverse }.shuffle
        elsif target.influence == 1
          facedown = target.characters.select { |c| c.face_down? }
          (facedown + new_cards).collect { |c| [c] }
        else
          raise "Invalid target influence #{target.influence}"
        end
      end

      def prompt_to_show_inquisitor(target, inquisitor)
        if target.influence == 2
          character_1, character_2 = target.characters
          User(target.user).send "Choose a character to show to #{inquisitor}: 1 - (#{character_1}) or 2 - (#{character_2}); \"!show 1\" or \"!show 2\""
        else
          character = target.characters.find { |c| c.face_down? }
          i = target.characters.index(character)
          User(target.user).send "You only have one character left. #{i+1} - (#{character}); \"!show #{i+1}\""
        end
      end

      def show_to_inquisitor(m, position)
        game = self.game_of(m)
        return unless game && game.started? && game.has_player?(m.user)

        pos = position.to_i
        unless pos == 1 || pos == 2
          player.user.send("#{pos} is not a valid option to reveal.")
          return
        end

        player = game.find_player(m.user)

        revealed = player.characters[pos - 1]
        unless revealed.face_down?
          player.user.send('You have already flipped that card.')
          return
        end

        turn = game.current_turn

        return unless turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :show_to_inquisitor

        _show_to_inquisitor(game, turn.decider, pos, turn.active_player)
      end

      def _show_to_inquisitor(game, target, position, inquisitor)
        Channel(game.channel_name).send("#{target} passes a card to #{inquisitor}. Should #{target} be allowed to keep this card (\"!keep\") or not (\"!discard\")?")
        revealed = target.characters[position - 1]
        inquisitor.user.send("#{target} shows you a #{revealed}.")

        game.inquisitor_shown_card = revealed
        turn = game.current_turn
        turn.make_decider(inquisitor)
        turn.decision_type = :keep_or_discard
      end

      def inquisitor_keep(m)
        game = self.game_of(m)
        return unless game && game.started? && game.has_player?(m.user)
        player = game.find_player(m.user)
        turn = game.current_turn
        return unless turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :keep_or_discard

        Channel(game.channel_name).send("The card is returned to #{turn.target_player}.")
        self.start_new_turn(game)
      end

      def inquisitor_discard(m)
        game = self.game_of(m)
        return unless game && game.started? && game.has_player?(m.user)
        player = game.find_player(m.user)
        turn = game.current_turn
        return unless turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :keep_or_discard

        Channel(game.channel_name).send("#{turn.target_player} is forced to discard that card and replace it with another from the Court Deck.")
        game.replace_character_with_new(turn.target_player, game.inquisitor_shown_card.name)
        self.tell_characters_to(turn.target_player, false)
        self.start_new_turn(game)
      end

      def pick_card(m, choice)
        game = self.game_of(m)
        return unless game && game.started? && game.has_player?(m.user)
        player = game.find_player(m.user)
        return if player.characters.size == 2

        choice = choice.to_i
        if 1 <= choice && choice <= player.side_cards.size
          player.select_side_character(choice)
          Channel(game.channel_name).send("#{player} has selected a character.")

          if game.all_characters_selected?
            Channel(game.channel_name).send "FIRST TURN. Player: #{game.current_player}. Please choose an action."
            game.current_turn.wait_for_action
          end
        else
          m.user.send("#{choice} is not a valid choice")
        end
      end

      def show_table(m, channel_name = nil)
        if m.channel
          # If in a channel, must be for that channel.
          game = @games[m.channel.name]
        elsif channel_name
          # If in private and channel specified, show that channel.
          game = @games[channel_name]
        else
          # If in private and channel not specified, show the game the player is in.
          game = @user_games[m.user]
          # and advise them if they aren't in any
          m.reply('To see a game via PM you must specify the channel: ' +
                  '!table #channel') unless game
        end

        return unless game
        m.reply(table_info(game).join("\n"))
      end

      def table_info(game, cheating = false)
        info = game.players.collect { |p|
          character_1, character_2 = p.characters

          char1_str = character_1.face_down? && !cheating ? '########' : character_1.to_s
          char1_str = character_1.face_down? ? "(#{char1_str})" : "[#{char1_str}]"
          if character_2
            char2_str = character_2.face_down? && !cheating ? '########' : character_2.to_s
            char2_str = character_2.face_down? ? " (#{char2_str})" : " [#{char2_str}]"
          else
            char2_str = ''
          end

          if cheating && !p.side_cards.empty?
            chars = p.side_cards.collect { |c| "(#{c.to_s})" }.join(' ')
            side_str = ' - Set aside: ' + chars
          else
            side_str = ''
          end

          "#{dehighlight_nick(p.to_s)}: #{char1_str}#{char2_str} - Coins: #{p.coins}#{side_str}"
        }
        unless game.discard_pile.empty?
          discards = game.discard_pile.map{ |c| "[#{c}]" }.join(" ")
          info << "Discard Pile: #{discards}"
        end
        info
      end

      def check_player_status(game, player)
        unless player.has_influence?
          Channel(game.channel_name).send "#{player} has no more influence, and is out of the game."
          game.discard_characters_for(player)
          remove_user_from_game(player.user, game, false)
          self.check_game_state(game)
        end
      end

      def process_turn(game)
        return if game.is_over?

        turn = game.current_turn
        if turn.counteracted? && !turn.block_challenge_successful
          game.pay_for_current_turn
          Channel(game.channel_name).send "#{turn.active_player}'s #{turn.action.action.upcase} was blocked by #{turn.counteracting_player} with #{turn.counteraction.action.upcase}."
          self.start_new_turn(game)
        elsif !turn.action_challenge_successful
          self_target = turn.active_player == turn.target_player
          target_msg = self_target || turn.target_player.nil? ? "" : ": #{turn.target_player}"
          effect = self_target ? turn.action.self_effect : turn.action.effect
          Channel(game.channel_name).send "#{game.current_player} proceeds with #{turn.action.action.upcase}. #{effect}#{target_msg}."
          game.pay_for_current_turn
          game.process_current_turn
          if turn.action.needs_decision?
            turn.wait_for_decision
            if turn.action.action == :coup || turn.action.action == :assassin
              # In a double-kill situation, the target may already be out.
              # If target is already out, just move on to next turn.
              if turn.target_player.influence == 2
                self.prompt_to_flip(turn.target_player)
              elsif turn.target_player.influence == 1
                i = turn.target_player.characters.index { |c| c.face_down? }
                self.couped(game, turn.target_player, i + 1)
              else
                self.start_new_turn(game)
              end
            elsif turn.action.action == :ambassador
              self.prompt_to_switch(game, turn.active_player)
            elsif turn.action.action == :inquisitor
              if turn.target_player == turn.active_player
                self.prompt_to_switch(game, turn.active_player, 1)
              elsif turn.target_player.influence == 2
                self.prompt_to_show_inquisitor(turn.target_player, turn.active_player)
              else
                i = turn.target_player.characters.index { |c| c.face_down? }
                self._show_to_inquisitor(game, turn.target_player, i + 1, turn.active_player)
              end
            end
          else
            self.start_new_turn(game)
          end
        else
          self.start_new_turn(game)
        end
      end

      def start_new_turn(game)
        game.next_turn
        Channel(game.channel_name).send "#{game.current_player}: It is your turn. Please choose an action."
      end


      def check_game_state(game)
        if game.is_over?
          self.do_end_game(game)
        end
      end

      def do_end_game(game)
        Channel(game.channel_name).send "Game is over! #{game.winner} wins!"
        self.start_new_game(game)
      end

      def start_new_game(game)
        Channel(game.channel_name).moderated = false
        game.players.each do |p|
          Channel(game.channel_name).devoice(p.user)
          @user_games.delete(p.user)
        end
        @games[game.channel_name] = Game.new(game.channel_name)
        @idle_timers[game.channel_name].start
      end



      def list_players(m)
        game = self.game_of(m)
        return unless game

        if game.players.empty?
          m.reply "No one has joined the game yet."
        else
          m.reply game.players.map{ |p| dehighlight_nick(p.to_s) }.join(' ')
        end
      end

      def devoice_channel(channel)
        channel.voiced.each do |user|
          channel.devoice(user)
        end
      end

      def remove_user_from_game(user, game, announce = true)
        left = game.remove_player(user)
        unless left.nil?
          Channel(game.channel_name).send "#{user.nick} has left the game (#{game.players.count}/#{Game::MAX_PLAYERS})" if announce
          Channel(game.channel_name).devoice(user)
          @user_games.delete(user)
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

      def reset_game(m, channel_name)
        if self.is_mod? m.user.nick
          channel = channel_name ? Channel(channel_name) : m.channel
          game = @games[channel.name]

          # Show everyone's cards.
          channel.send(table_info(game, true).join("\n"))

          game.players.each do |p|
            @user_games.delete(p.user)
          end

          @games[channel.name] = Game.new(channel.name)
          self.devoice_channel(channel)
          channel.send "The game has been reset."
          @idle_timers[channel.name].start
        end
      end

      def kick_user(m, channel_name, nick)
        if self.is_mod? m.user.nick
          channel = channel_name ? Channel(channel_name) : m.channel
          game = @games[channel.name]

          if game.not_started?
            user = User(nick)
            self.remove_user_from_game(user, game)
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

          # Find game based on user 1
          game = @user_games[user1]

          # replace the users for the players
          player = game.find_player(user1)
          player.user = user2

          # devoice/voice the players
          Channel(game.channel_name).devoice(user1)
          Channel(game.channel_name).voice(user2)

          @user_games.delete(user1)
          @user_games[user2] = game

          # inform channel
          Channel(game.channel_name).send "#{user1.nick} has been replaced with #{user2.nick}"

          # tell characters to new player
          User(player.user).send "="*40
          self.tell_characters_to(player)
        end
      end

      def room_mode(m, channel_name, mode)
        channel = channel_name ? Channel(channel_name) : m.channel
        if self.is_mod? m.user.nick
          case mode
          when "silent"
            Channel(channel.name).moderated = true
          when "vocal"
            Channel(channel.name).moderated = false
          end
        end
      end

      def who_chars(m, channel_name)
        return unless self.is_mod? m.user.nick
        channel = channel_name ? Channel(channel_name) : m.channel
        game = @games[channel.name]

        return unless game

        if game.started?
          if game.has_player?(m.user)
            m.user.send('Cheater!!!')
          else
            m.user.send(table_info(game, true).join("\n"))
          end
        else
          m.user.send('There is no game going on.')
        end
      end

      #--------------------------------------------------------------------------------
      # Game Settings
      #--------------------------------------------------------------------------------

      def get_game_settings(m, channel_name = nil)
        if m.channel
          # If in a channel, must be for that channel.
          game = @games[m.channel.name]
        elsif channel_name
          # If in private and channel specified, show that channel.
          game = @games[channel_name]
        else
          # If in private and channel not specified, show the game the player is in.
          game = @user_games[m.user]
          # and advise them if they aren't in any
          m.reply('To see settings via PM you must specify the channel: ' +
                  '!settings #channel') unless game
        end

        return unless game
        m.reply("Game settings: #{game_settings(game)}.")
      end

      def set_game_settings(m, channel_name = nil, options = "")
        if m.channel
          # If in a channel, must be for that channel.
          game = @games[m.channel.name]
        elsif channel_name
          # If in private and channel specified, show that channel.
          game = @games[channel_name]
        else
          # If in private and channel not specified, show the game the player is in.
          game = @user_games[m.user]
          # and advise them if they aren't in any
          m.reply('To change settings via PM you must specify the channel: ' +
                  '!settings #channel') unless game
        end

        return unless game && !game.started?

        unrecognized = []
        settings = []
        options.split.each { |opt|
          case opt.downcase
          when 'base'
            settings.clear
          when 'inquisitor'
            settings << :inquisitor
          when 'reformation'
            settings << :reformation
          end
        }

        game.settings = settings.uniq

        change_prefix = m.channel ? "The game has been changed" :  "#{m.user.nick} has changed the game"

        Channel(game.channel_name).send("#{change_prefix} to #{game_settings(game)}.")
      end

      def game_settings(game)
        game.settings.empty? ? 'Base' : game.settings.collect { |s| s.to_s.capitalize }.join(', ')
      end

      #--------------------------------------------------------------------------------
      # Helpers
      #--------------------------------------------------------------------------------

      def game_of(m)
        m.channel ? @games[m.channel.name] : @user_games[m.user]
      end

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

      def status(m)
        game = self.game_of(m)
        return unless game

        if game.started?
          turn = game.current_turn

          action = "#{dehighlight_nick(turn.active_player.user.nick)}'s #{turn.action.to_s.upcase}" if turn.action
          block = "#{dehighlight_nick(turn.counteracting_player.user.nick)}'s #{turn.counteraction.to_s.upcase} blocking #{action}" if turn.counteraction

          if turn.waiting_for_action?
            status = "Waiting on #{turn.active_player} to take an action"
          elsif turn.waiting_for_action_challenge?
            players = game.not_reacted.map(&:user).join(", ")
            status = "Waiting on players to PASS or CHALLENGE #{action}: #{players}"
          elsif turn.waiting_for_action_challenge_reply?
            status = "Waiting on #{turn.active_player} to respond to challenge against #{action}"
          elsif turn.waiting_for_action_challenge_loser?
            status = "Waiting on #{turn.action_challenger} to pick character to lose"
          elsif turn.waiting_for_block?
            if turn.action.needs_target
              players = turn.target_player.to_s
            else
              players = game.not_reacted.map(&:user).join(", ")
            end
            status = "Waiting on players to PASS or BLOCK #{action}: #{players}"
          elsif turn.waiting_for_block_challenge?
            players = game.not_reacted.map(&:user).join(", ")
            status = "Waiting on players to PASS or CHALLENGE #{block}: #{players}"
          elsif turn.waiting_for_block_challenge_reply?
            status = "Waiting on #{turn.counteracting_player} to respond to challenge against #{block}"
          elsif turn.waiting_for_block_challenge_loser?
            status = "Waiting on #{turn.block_challenger} to pick character to lose"
          elsif turn.waiting_for_decision?
            status = "Waiting on #{turn.decider} to make decision on #{turn.action.to_s.upcase}"
          elsif turn.waiting_for_initial_characters?
            players = game.not_selected_initial_character.map(&:user).join(", ")
            status = 'Waiting on players to pick character: ' + players
          else
            status = "Unknown status #{turn.state}"
          end
        else
          if game.player_count.zero?
            status = "No game in progress."
          else
            status = "Game being started. #{game.player_count} players have joined: #{game.players.map(&:user).join(", ")}"
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
        game = self.game_of(m)
        return unless game

        if game.accepting_players?
          if game.invitation_sent?
            m.reply "An invitation cannot be sent out again so soon."
          else      
            game.mark_invitation_sent
            User("BG3PO").send "!invite_to_coup_game"
            User(m.user).send "Invitation has been sent."

            settings = load_settings || {}
            subscribers = settings["subscribers"]
            current_players = game.players.map{ |p| p.user.nick }
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
              game.reset_invitation
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
