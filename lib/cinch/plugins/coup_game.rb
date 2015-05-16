require 'cinch'
require 'cinch/plugins/game_bot'

require File.expand_path(File.dirname(__FILE__)) + '/core/action'
require File.expand_path(File.dirname(__FILE__)) + '/core/game'
require File.expand_path(File.dirname(__FILE__)) + '/core/turn'
require File.expand_path(File.dirname(__FILE__)) + '/core/player'
require File.expand_path(File.dirname(__FILE__)) + '/core/character'

module Cinch
  module Plugins
    class CoupGame < GameBot
      include Cinch::Plugin

      ACTION_ALIASES = {
        'foreign aid' => 'foreign_aid',
        'foreignaid' => 'foreign_aid',
        'tax' => 'duke',
        'assassinate' => 'assassin',
        'kill' => 'assassin',
        'steal' => 'captain',
        'extort' => 'captain',
        'exchange' => 'ambassador',
        'recant' => 'apostatize',
        'repent' => 'apostatize',
        'betray' => 'defect',
      }

      # Length of the longest character's name (Ambassador / Inquisitor)
      LONGEST_NAME = 10

      def initialize(*args)
        super
        @forced_id = 16
      end

      # game    
      match /(?:action )?(duke|tax|ambassador|exchange|income|foreign(?: |_)?aid)/i, :method => :do_action
      match /(?:action )?(recant|repent|apostatize|defect|betray|embezzle)/i, :method => :do_action
      match /(?:action )?(assassin(?:ate)?|kill|captain|steal|extort|coup)(?: (.+))?/i, :method => :do_action
      match /(?:action )?(inquisitor|convert|bribe)(?: (.+))?/i, :method => :do_action

      match /block (duke|contessa|captain|ambassador|inquisitor)/i, :method => :do_block
      match /pass/i,                 :method => :react_pass
      match /challenge/i,            :method => :react_challenge
      match /bs/i,                   :method => :react_challenge

      match /(?:flip|lose)\s*(1|2|all)/i, :method => :flip_card
      match /(?:switch|keep|pick|swap)\s*([1-6])/i, :method => :pick_cards

      match /show (1|2)/i,           :method => :show_to_inquisitor
      match /keep/i,                 :method => :inquisitor_keep
      match /discard/i,              :method => :inquisitor_discard

      match /me$/i,                  :method => :whoami
      match /table(?:\s*(##?\w+))?/i,:method => :show_table

      # other
      match /help ?(.+)?/i,          :method => :help
      match /rules ?(.+)?/i,         :method => :rules

      match /settings(?:\s+(##?\w+))?$/i,     :method => :get_game_settings
      match /settings(?:\s+(##?\w+))? (.+)/i, :method => :set_game_settings

      # mod only commands
      match /chars(?:\s+(##?\w+))?/i,        :method => :who_chars

      add_common_commands

      #--------------------------------------------------------------------------------
      # Implementing classes should override these
      #--------------------------------------------------------------------------------

      def min_players; Game::MIN_PLAYERS end
      def max_players; Game::MAX_PLAYERS end
      def game_name; Game::GAME_NAME end

      def do_start_game(m, channel_name, players, settings, start_args)
        if start_args && !start_args.empty?
          args_settings, unrecognized = self.class.parse_game_settings(start_args)
          unless unrecognized.empty?
            ur = unrecognized.collect { |x| '"' + x + '"' }.join(', ')
            m.reply('Unrecognized game types: ' + ur, true)
            return false
          end

          if (settings[:coup_modes] || []) != args_settings
            settings[:coup_modes] = args_settings
            change_prefix = m.channel ? "The game has been changed" : "#{m.user.nick} has changed the game"
            Channel(channel_name).send("#{change_prefix} to #{format_settings(args_settings)}.")
          end
        elsif players.size == 2
          m.reply('To start a two-player game you must choose to play with base rules ("!start base") or two-player variant rules ("!start twoplayer").')
          return false
        end

        game = Game.new(channel_name, players.map(&:user), settings[:coup_modes] || [])

        Channel(game.channel_name).send("The game has started.")

        self.pass_out_characters(game)

        Channel(game.channel_name).send("Turn order is: #{game.players.map { |p| p.user.nick }.join(' ')}")

        if game.players.size == 2 && game.settings.include?(:twoplayer)
          Channel(game.channel_name).send('This is a two-player variant game. The starting player receives only 1 coin. Both players are picking their first character.')
          game.current_turn.wait_for_initial_characters
        else
          Channel(game.channel_name).send('This is a two-player game. The starting player receives only 1 coin.') if game.players.size == 2
          Channel(game.channel_name).send("FIRST TURN. Player: #{game.current_player}. Please choose an action.")
        end

        game
      end

      def do_reset_game(game)
        # Show everyone's cards.
        Channel(game.channel_name).send(self.table_info(game, cheating: true).join("\n"))
      end

      def do_replace_user(game, replaced_user, replacing_user)
        # tell characters to new player
        replacing_user.send("=" * 40)
        self.tell_characters_to(game, game.find_player(replacing_user))
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
          if game.players.size == 2 && game.settings.include?(:twoplayer)
            chars = p.side_cards.each_with_index.map { |char, i|
              "#{i + 1} - (#{char.to_s})"
            }.join(' ')
            p.user.send(chars)
            p.user.send('Choose your first character card with "!pick #". The other four characters will not be used this game, and only you will know what they are.')
          else
            self.tell_characters_to(game, p, show_side: false)
          end
        end
      end

      def whoami(m)
        game = self.game_of(m)
        return unless game

        if game.has_player?(m.user)
          player = game.find_player(m.user)
          self.tell_characters_to(game, player)
        end
      end

      def character_info(c, opts = {})
        cname = c.face_down? && !opts[:show_secret] ? '########' : c.to_s
        c.face_down? ? "(#{cname})" : "[#{cname}]"
      end

      def player_info(game, player, opts)
        character_1, character_2 = player.characters

        char1_str = character_info(character_1, opts)
        char2_str = character_2 ? ' ' + character_info(character_2, opts) : ''

        coins_str = opts[:show_coins] ? " - Coins: #{player.coins}" : ""

        side_str = ''
        if opts[:show_side] && !player.side_cards.empty?
          chars = player.side_cards.collect { |c| "(#{c.to_s})" }.join(' ')
          side_str = ' - Set aside: ' + chars
        end

        faction_str = game.has_factions? ? " - #{game.factions[player.faction]}" : ''

        chars = player.characters.size == 2 ? char1_str + char2_str : 'Character not selected'

        "#{chars}#{coins_str}#{faction_str}#{side_str}"
      end

      def tell_characters_to(game, player, opts = {})
        opts = { :show_coins => true, :show_side => true, :show_secret => true }.merge(opts)
        player.user.send(player_info(game, player, opts))
      end

      def check_action(m, game, action)
        if (mf = Game::ACTIONS[action.to_sym].mode_forbidden) && game.settings.include?(mf)
          m.user.send("#{action.upcase} may not be used if the game type is #{mf.to_s.capitalize}.")
          return false
        end
        if (mrs = Game::ACTIONS[action.to_sym].mode_required) && mrs.all? { |mr| !game.settings.include?(mr) }
          modes = mrs.collect { |mr| mr.to_s.capitalize }.join(', ')
          m.user.send("#{action.upcase} may only be used if the game type is one of the following: #{modes}.")
          return false
        end
        true
      end

      def do_action(m, action, target = "")
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)

        if game.current_turn.waiting_for_action? && game.current_player.user == m.user

          action = ACTION_ALIASES[action.downcase] || action.downcase

          if game.current_player.coins >= 10 && action.upcase != "COUP"
            m.user.send "Since you have 10 coins, you must use COUP. !action coup <target>"
            return
          end

          game_action = Game::ACTIONS[action.to_sym]

          return unless check_action(m, game, action)

          if target.nil? || target.empty?
            target_msg = ""

            if game_action.needs_target
              m.user.send("You must specify a target for #{action.upcase}: !action #{action} <playername>")
              return
            end
          else
            target_player = game.find_player(target)

            # No self-targeting!
            if target_player == game.current_player && !game_action.self_targettable
              m.user.send("You may not target yourself with #{action.upcase}.")
              return
            end

            if target_player.nil?
              User(m.user).send "\"#{target}\" is an invalid target."
              return
            end

            target_msg = " on #{target}"

            unless game_action.can_target_friends || game.is_enemy?(game.current_player, target_player)
              us = game.factions[game.current_player.faction]
              them = game.factions[1 - game.current_player.faction]
              m.user.send("You cannot target a fellow #{us} with #{action.upcase} while the #{them} exist!")
              return
            end
          end

          cost = game_action.cost
          if game.current_player.coins < cost
            coins = game.current_player.coins
            m.user.send "You need #{cost} coins to use #{action.upcase}, but you only have #{coins} coins."
            return
          end

          Channel(game.channel_name).send "#{m.user.nick} would like to use #{game_action.to_s_full(game, game.current_player, target_player)}#{target_msg}"
          game.current_turn.add_action(game_action, target_player)
          if game.current_turn.action.challengeable?
            game.current_turn.wait_for_action_challenge
            self.prompt_challengers(game)
          elsif game.current_turn.action.blockable?
            game.current_turn.wait_for_block
            self.prompt_blocker(game)
          else
            self.process_turn(game)
          end
        else
          User(m.user).send "You are not the current player."
        end
      end

      def prompt_challengers(game)
        turn = game.current_turn
        challenged = turn.challengee_action

        char = challenged.character_forbidden? ? challenged.character_forbidden : challenged.character_required
        haveornot = challenged.character_forbidden? ? 'NOT have' : 'have'
        challengeable = "#{dehighlight_nick(turn.challengee_player.user.nick)} claims to #{haveornot} influence over #{char.upcase}"

        if turn.counteraction
          why_char = "Blocking #{dehighlight_nick(turn.active_player.user.nick)}'s #{turn.action.name}"
        else
          why_char = "Using #{turn.action.name}#{turn.target_player && " on #{dehighlight_nick(turn.target_player.user.nick)}"}"
        end

        list = game.reacting_players.collect(&:to_s).join(', ')

        Channel(game.channel_name).send("All other players (#{list}): #{challengeable} (#{why_char}). Would you like to challenge (\"!challenge\") or not (\"!pass\")?")
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
          enemies = game.reacting_players

          if game.has_factions?
            active_faction = game.current_turn.active_player.faction
            faction_enemies = game.players.select { |p| p.faction != active_faction }
            unless faction_enemies.empty?
              enemies = faction_enemies
              prefix = "All #{game.factions[1 - active_faction]} players"
            end
          end
          prefix << " (#{enemies.collect(&:to_s).join(', ')})"
        end
        act_str = "#{dehighlight_nick(game.current_turn.active_player.user.nick)}'s #{action.name}"
        Channel(game.channel_name).send("#{prefix}: Would you like to block #{act_str} (#{blockers}) or not (\"!pass\")?")
      end

      def do_block(m, action)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)

        player = game.find_player(m.user)
        turn = game.current_turn

        return unless turn.waiting_for_block? && game.reacting_players.include?(player)
        action.downcase!
        game_action = Game::ACTIONS[action.to_sym]
        return unless check_action(m, game, action)

        unless game.is_enemy?(player, turn.active_player)
          us = game.factions[game.current_player.faction]
          them = game.factions[1 - game.current_player.faction]
          m.user.send("You cannot block a fellow #{us}'s #{turn.action.name} while the #{them} exist!")
          return
        end

        if game_action.blocks == turn.action.action
          if turn.action.needs_target && m.user != turn.target_player.user
            m.user.send "You can only block with #{action.upcase} if you are the target."
            return
          end
          turn.add_counteraction(game_action, player)
          blocked = "#{dehighlight_nick(game.current_turn.active_player.user.nick)}'s #{turn.action.name}"
          Channel(game.channel_name).send("#{player} would like to use #{action.upcase} to block #{blocked}")
          self.prompt_challengers(game)
          turn.wait_for_block_challenge
        else
          User(m.user).send "#{action.upcase} does not block #{turn.action.name}."
        end
      end

      def react_pass(m)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)

        player = game.find_player(m.user)
        turn = game.current_turn

        return unless game.reacting_players.include?(player)

        if turn.waiting_for_challenges?
          success = turn.pass(player)
          Channel(game.channel_name).send "#{m.user.nick} passes." if success

          if game.all_reactions_in?
            if turn.waiting_for_action_challenge? && turn.action.blockable?
              # Nobody wanted to challenge the actor.
              # If action is blockable, ask for block now.
              turn.wait_for_block
              self.prompt_blocker(game)
            else
              # If action is unblockable or if nobody is challenging the blocker, proceed.
              self.process_turn(game)
            end
          end
        elsif turn.waiting_for_block?
          if turn.action.needs_target && turn.target_player == player
            # Blocker didn't want to block. Process turn.
            Channel(game.channel_name).send "#{m.user.nick} passes."
            self.process_turn(game)
          elsif !turn.action.needs_target && game.is_enemy?(player, turn.active_player)
            # This blocker didn't want to block, but maybe someone else will
            success = game.current_turn.pass(player)
            Channel(game.channel_name).send "#{m.user.nick} passes." if success
            # So we wait until all reactions are in.
            all_in = game.has_factions? ? game.all_enemy_reactions_in? : game.all_reactions_in?
            self.process_turn(game) if all_in
          end
        end
      end

      def react_challenge(m)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)
        player = game.find_player(m.user)

        turn = game.current_turn

        return unless turn.waiting_for_challenges? && game.reacting_players.include?(player)
        defendant = turn.challengee_player
        chall_action = turn.challengee_action

        char = chall_action.character_forbidden? ? chall_action.character_forbidden : chall_action.character_required
        haveornot = chall_action.character_forbidden? ? 'NOT having' : 'having'

        Channel(game.channel_name).send "#{m.user.nick} challenges #{defendant} on #{haveornot} influence over #{char.upcase}!"

        # Prompt player if he has a choice
        self.prompt_challenge_defendant(defendant, m.user.nick, chall_action, "#{haveornot} influence over #{char.upcase}") if defendant.influence == 2

        if turn.waiting_for_action_challenge?
          turn.wait_for_action_challenge_reply
          turn.action_challenger = player
        elsif game.current_turn.waiting_for_block_challenge?
          turn.wait_for_block_challenge_reply
          turn.block_challenger = player
        end

        return unless defendant.influence == 1

        # If defendant has 1 influence, we can auto-respond, but we'll wait 3 seconds for suspense.
        expected_state = turn.state
        sleep(3)
        i = defendant.characters.index { |c| c.face_down? }
        # Make sure the defendant didn't manually respond (which is allowed) before we auto-respond, though.
        self.respond_to_challenge(game, defendant, i + 1, chall_action, player) if turn.state == expected_state
      end

      def defendant_reveal_and_win(game, defendant, chars, challenger)
        revealed = chars.collect { |c| "[#{c}]" }.join(' and ')
        raise "defendant reveals #{chars.size} cards?!" unless chars.size == 2 || chars.size == 1
        pronoun = chars.size == 2 ? 'both' : 'it'
        replacement = chars.size == 2 ? 'new cards' : 'a new card'
        revealed = 'a ' + revealed if chars.size == 1

        Channel(game.channel_name).send(
          "#{defendant} reveals #{revealed} and replaces #{pronoun} with #{replacement} from the Court Deck."
        )

        # Give defendant his new characters and tell him about them.
        chars.each { |c| game.replace_character_with_new(defendant, c.name) }
        self.tell_characters_to(game, defendant, show_coins: false)

        Channel(game.channel_name).send("#{challenger} loses influence for losing the challenge!")
        game.current_turn.wait_for_challenge_loser

        if challenger.influence == 2
          self.prompt_to_flip(challenger)
        else
          i = challenger.characters.index { |c| c.face_down? }
          self.lose_challenge(game, challenger, i + 1)
        end
      end

      def defendant_reveal_and_lose(game, defendant, revealed, action)
        Channel(game.channel_name).send(
          "#{defendant} loses influence over the [#{revealed}] and cannot use #{action.name} this turn."
        )
        revealed.flip_up
        self.check_player_status(game, defendant)

        turn = game.current_turn
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
          raise "defendant_reveal_and_lose in #{turn.state}"
        end
      end

      def prompt_to_pick_card(target, what, cmd)
        user = User(target.user)
        raise "#{target} has no choice to #{what}" unless target.influence == 2
        character_1, character_2 = target.characters
        user.send("Choose a character to #{what}: 1 - (#{character_1}) or 2 - (#{character_2}); \"!#{cmd} 1\" or \"!#{cmd} 2\"")
      end

      def prompt_challenge_defendant(target, challenger, action, what_challenged)
        user = User(target.user)
        user.send("#{challenger} challenges your claim of #{what_challenged}")
        if action.character_forbidden? && !target.has_character?(action.character_forbidden)
          user.send('You can reveal both your cards with "!flip all" to win the challenge, or you can choose to lose by revealing only one:')
        end
        prompt_to_pick_card(target, 'reveal', 'flip')
      end

      def prompt_to_flip(target)
        prompt_to_pick_card(target, 'turn face up', 'lose')
      end

      def flip_card(m, position)
        game = self.game_of(m)
        return unless game

        if game.has_player?(m.user)
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
          # In a double-kill, losing challenge may kill the blocker.
          # If he's dead, just skip to processing turn.
          if turn.action.blockable? && turn.target_player.has_influence?
            turn.wait_for_block
            self.prompt_blocker(game)
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
        if position.to_s.downcase == 'all' && player.influence == 2
          respond_to_challenge_all(game, player, action, challenger)
          return
        end

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

        if action.character_required?
          if revealed.name == action.character_required
            defendant_reveal_and_win(game, player, [revealed], challenger)
          else
            Channel(game.channel_name).send "#{player} reveals a [#{revealed}]. That's not a #{action.character_required.to_s.upcase}! #{player} loses the challenge!"
            defendant_reveal_and_lose(game, player, revealed, action)
          end
        elsif action.character_forbidden?
          # If I have 2 influence and I am flipping one character, I'm losing it no matter what. I can't win.
          # If I have 1 influence, I win if it's not the character, I lose if it is.
          if player.influence == 1 && revealed.name != action.character_forbidden
            defendant_reveal_and_win(game, player, [revealed], challenger)
          else
            Channel(game.channel_name).send("#{player} reveals a [#{revealed}]. #{player} loses the challenge!")
            defendant_reveal_and_lose(game, player, revealed, action)
          end
        else
          raise "respond_to_challenge for an unchallengeable action?"
        end
      end

      def respond_to_challenge_all(game, player, action, challenger)
        unless action.character_forbidden?
          player.user.send('You may only flip all cards in response to a challenge of NOT having influence over a character.')
          return
        end

        if player.influence <= 1
          player.user.send("You can only flip all cards when you have more than one.")
          return
        end

        if player.has_character?(action.character_forbidden)
          player.user.send("You cannot flip all cards because you have a #{action.character_forbidden.to_s.upcase}.")
          return
        end

        # Do NOT have a forbidden character, so win the challenge.
        chars = player.characters.select { |c| c.face_down? }
        defendant_reveal_and_win(game, player, chars, challenger)
      end

      def prompt_to_switch(game, target, cards = 2)
        game.ambassador_cards = game.draw_cards(cards)
        card_names = game.ambassador_cards.collect { |c| c.to_s }.join(' and ')
        User(target.user).send "You drew #{card_names} from the Court Deck."

        fmt = "%#{LONGEST_NAME + 2}s"
        game.ambassador_options = get_switch_options(target, game.ambassador_cards)
        User(target.user).send "Choose an option for a new hand; \"!switch #\""
        game.ambassador_options.each_with_index do |option, i|
          User(target.user).send "#{i+1} - " + option.map{ |o|
            fmt % ["(#{o})"]
          }.join(" ")
        end
      end

      def switch_cards(m, game, player, choice)
        turn = game.current_turn

        return unless turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :switch_cards
        facedown_indices = [0, 1].select { |i| player.characters[i].face_down? }
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

      def show_to_inquisitor(m, position)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)

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
        Channel(game.channel_name).send("#{target} passes a card to #{inquisitor}.")
        Channel(game.channel_name).send("#{inquisitor}: Should #{target} be allowed to keep this card (\"!keep\") or not (\"!discard\")?")
        revealed = target.characters[position - 1]
        inquisitor.user.send("#{target} shows you a #{revealed}.")

        game.inquisitor_shown_card = revealed
        turn = game.current_turn
        turn.make_decider(inquisitor, :keep_or_discard)
      end

      def inquisitor_keep(m)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)
        player = game.find_player(m.user)
        turn = game.current_turn
        return unless turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :keep_or_discard

        Channel(game.channel_name).send("The card is returned to #{turn.target_player}.")
        self.start_new_turn(game)
      end

      def inquisitor_discard(m)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)
        player = game.find_player(m.user)
        turn = game.current_turn
        return unless turn.waiting_for_decision? && turn.decider == player && turn.decision_type == :keep_or_discard

        Channel(game.channel_name).send("#{turn.target_player} is forced to discard that card and replace it with another from the Court Deck.")
        game.replace_character_with_new(turn.target_player, game.inquisitor_shown_card.name, draw_first: true)
        self.tell_characters_to(game, turn.target_player, show_coins: false)
        self.start_new_turn(game)
      end

      def pick_cards(m, choice)
        game = self.game_of(m)
        return unless game && game.has_player?(m.user)
        player = game.find_player(m.user)

        if game.current_turn.waiting_for_initial_characters?
          self.pick_initial_card(m, game, player, choice)
        else
          self.switch_cards(m, game, player, choice)
        end
      end

      def pick_initial_card(m, game, player, choice)
        return if player.characters.size == 2

        choice = choice.to_i
        if 1 <= choice && choice <= player.side_cards.size
          player.select_side_character(choice)
          Channel(game.channel_name).send("#{player} has selected a character.")
          self.tell_characters_to(game, player, show_side: false)

          if game.all_characters_selected?
            Channel(game.channel_name).send "FIRST TURN. Player: #{game.current_player}. Please choose an action."
            game.current_turn.wait_for_action
          end
        else
          m.user.send("#{choice} is not a valid choice")
        end
      end

      def show_table(m, channel_name = nil)
        game = self.game_of(m, channel_name, ['see a game', '!table'])

        return unless game
        m.reply(table_info(game).join("\n"))
      end

      def table_info(game, opts = {})
        info = game.players.collect { |p|
          i = player_info(game, p, show_coins: true, show_side: opts[:cheating], show_secret: opts[:cheating])
          "#{dehighlight_nick(p.to_s)}: #{i}"
        }
        if opts[:cheating]
          court_cards = game.deck.map { |c| "(#{c})" }.join(' ')
          info << "Court Deck: #{court_cards}"
        else
          info << "Court Deck: (#{game.deck.size} cards)"
        end
        unless game.discard_pile.empty?
          discards = game.discard_pile.map{ |c| "[#{c}]" }.join(" ")
          info << "Discard Pile: #{discards}"
        end
        if game.has_factions?
          info << "#{game.bank_name}: #{game.bank} coin#{game.bank == 1 ? '' : 's'}"
        end
        info
      end

      def check_player_status(game, player)
        unless player.has_influence?
          channel = Channel(game.channel_name)
          channel.send "#{player} has no more influence, and is out of the game."
          game.discard_characters_for(player)
          game.remove_player(player.user)
          channel.devoice(player.user)
          @user_games.delete(player.user)

          if game.is_over?
            Channel(game.channel_name).send "Game is over! #{game.winner} wins!"
            Channel(game.channel_name).send "#{game.winner} was #{player_info(game, game.winner, show_secret: true)}."
            self.start_new_game(game)
          end
        end
      end

      def process_turn(game)
        return if game.is_over?

        turn = game.current_turn
        if turn.counteracted? && !turn.block_challenge_successful
          game.pay_for_current_turn
          Channel(game.channel_name).send "#{turn.active_player}'s #{turn.action.name} was blocked by #{turn.counteracting_player} with #{turn.counteraction.character_required.upcase}."
          self.start_new_turn(game)
        elsif !turn.action_challenge_successful
          self_target = turn.active_player == turn.target_player
          target_msg = self_target || turn.target_player.nil? ? "" : ": #{turn.target_player}"
          effect = self_target ? turn.action.self_effect : turn.action.effect
          effect = turn.action.effect_f.call(game) if turn.action.effect_f
          Channel(game.channel_name).send "#{game.current_player} proceeds with #{turn.action.name}. #{effect}#{target_msg}."
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
                self.prompt_to_pick_card(turn.target_player, "show to #{turn.active_player}", 'show')
              elsif turn.target_player.influence == 1
                i = turn.target_player.characters.index { |c| c.face_down? }
                self._show_to_inquisitor(game, turn.target_player, i + 1, turn.active_player)
              else
                self.start_new_turn(game)
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

      #--------------------------------------------------------------------------------
      # Mod commands
      #--------------------------------------------------------------------------------

      def who_chars(m, channel_name)
        return unless self.is_mod?(m.user)
        game = self.game_of(m, channel_name, ['see a game', '!chars'])

        unless game
          m.user.send('There is no game going on.')
          return
        end

        if game.has_player?(m.user)
          m.user.send('Cheater!!!')
        else
          m.user.send(table_info(game, cheating: true).join("\n"))
        end
      end

      #--------------------------------------------------------------------------------
      # Game Settings
      #--------------------------------------------------------------------------------

      def self.parse_game_settings(options)
        unrecognized = []
        settings = []
        options.split.each { |opt|
          case opt.downcase
          when 'base'
            settings.clear
          when 'twoplayer'
            settings << :twoplayer
          when 'inquisitor', 'inquisition'
            settings << :inquisitor
          when 'reformation'
            settings << :reformation
            settings.delete(:incorporation)
          when 'incorporation'
            settings << :incorporation
            settings.delete(:reforation)
          else
            unrecognized << opt
          end
        }

        [settings.uniq, unrecognized]
      end

      def get_game_settings(m, channel_name = nil)
        if (game = self.game_of(m, channel_name))
          m.reply("Game settings: #{format_settings(game.settings)}.")
          return
        end

        waiting_room = self.waiting_room_of(m, channel_name, ['see settings', '!settings'])
        return unless waiting_room
        m.reply("Next game settings: #{format_settings(waiting_room.settings[:coup_modes])}.")
      end

      def set_game_settings(m, channel_name = nil, options = "")
        waiting_room = self.waiting_room_of(m, channel_name, ['change settings', '!settings'])
        return unless waiting_room

        unless Channel(waiting_room.channel_name).has_user?(m.user)
          m.user.send("You need to be in #{waiting_room.channel_name} to change the settings.")
          return
        end

        settings, _ = self.class.parse_game_settings(options)
        waiting_room.settings[:coup_modes] = settings

        change_prefix = m.channel ? "The game has been changed" :  "#{m.user.nick} has changed the game"

        Channel(waiting_room.channel_name).send("#{change_prefix} to #{format_settings(settings)}.")
      end

      def format_settings(settings)
        return 'Base' if !settings || settings.empty?
        settings.collect { |s| s.to_s.capitalize }.join(', ')
      end

      #--------------------------------------------------------------------------------
      # Helpers
      #--------------------------------------------------------------------------------

      def help(m, page)
        if page.to_s.downcase == "mod" && self.is_mod?(m.user)
          User(m.user).send "--- HELP PAGE MOD ---"
          User(m.user).send "!reset - completely resets the game to brand new"
          User(m.user).send "!replace nick1 nick1 - replaces a player in-game with a player out-of-game"
          User(m.user).send "!kick nick1 - removes a presumably unresponsive user from an unstarted game"
          User(m.user).send "!room silent|vocal - switches the channel from voice only users and back"
          m.user.send('!chars - the obligatory cheating command - NOT to be used while you are a participant of the game')
        else 
          case page
          when "2"
            User(m.user).send "--- HELP PAGE 2/3 ---"
            m.user.send('!me - PMs you your current character cards')
            m.user.send('!table - examines the table, showing any face-up cards and how many coins each player has')
            m.user.send('!who - shows a list of players in turn order')
            m.user.send('!status - shows which phase the game is in, and who currently needs to take an action')
          when "3"
            User(m.user).send "--- HELP PAGE 3/3 ---"
            m.user.send('!rules (actions|inquisitor|reformation) - provides rules for the game; when provided with an argument, provides specified rules')
            m.user.send('!settings (modes) - changes the game to the specified game type. modes may be "twoplayer" and/or "inquisitor" plus one of ("reformation" or "incorporation"), or blank to see current settings')

            User(m.user).send "!subscribe - subscribe your current nick to receive PMs when someone calls !invite"
            User(m.user).send "!unsubscribe - remove your nick from the invitation list"
            m.user.send('!notice (on|off) - controls whether CoupBot will use NOTICE or PRIVMSG to communicate private information')
            User(m.user).send "!invite - invites #boardgames and subscribers to join the game"
            User(m.user).send "!changelog (#) - shows changelog for the bot, when provided a number it showed details"
          else
            User(m.user).send "--- HELP PAGE 1/3 ---"
            User(m.user).send "!join - joins the game"
            User(m.user).send "!leave - leaves the game"
            User(m.user).send "!start - starts the game"

            m.user.send('!action actionname - uses an action on your turn. actionname may be: income, foreign aid, duke, ambassador')
            m.user.send('!action actionname targetname - uses an action on your turn against the specified target. actionname may be: coup, assassin, captain')
            m.user.send('!block character - uses the specified character (duke, ambassador, captain, contessa) to block an opponent\'s action')
            m.user.send('!challenge - challenge an opponent\'s claim of influence over a given character')
            m.user.send('!pass - pass on either a chance to challenge or a chance to block an opponent\'s action')
            m.user.send('!flip 1|2 - flip one of your character cards in response to a challenge')

            m.user.send('!help (#) - when provided a number, pulls up specified page. Page 2 lists commands that show information about the current game. Page 3 lists commands to give information about CoupBot or about variants of Coup')
          end
        end
      end

      def rules(m, section)
        case section.to_s.downcase
        when 'inquisition', 'inquisitor'
          m.user.send('http://boardgamegeek.com/image/1825161/coup')
          m.user.send('The Inquisitor is a new role that replaces the Ambassador.')
          m.user.send('Like the Ambassador, the Inquisitor blocks the Captain from stealing coins from you.')
          m.user.send('Target yourself with the Inquisitor action to draw one card from the Court Deck. You may exchange this card with one of your face-down characters. The card you choose not to keep is returned to the Court Deck.')
          m.user.send('Target an opponent with the Inquisitor to force that opponent to show you one of their character cards (their choice which). You may then allow them to keep that card, or discard it and draw a new one from the Court Deck.')
        when 'reformation'
          m.user.send('In Reformation, each player can belong to one of two factions: the Protestants or the Catholics. The initial faction distribution alternates around the table.')
          m.user.send('While there are members of the opposite faction in the game, you may not target your factionmates with Captain, Assassin, Inquisitor, Coup, nor may you block their Foreign Aid. You may still challenge your factionmates.')
          m.user.send('There are now three new actions available:')
          m.user.send("* Apostatize: Pay one coin to the Almshouse to change your own faction.")
          m.user.send("* Convert: Pay two coins to the Almshouse to change another player's faction.")
          m.user.send("* Embezzle: Take all coins from the Almshouse. You must NOT have influence over the Duke to perform this action--if challenged, you must reveal both of your face-down characters to prove it.")
          m.user.send('When only one faction exists, that faction descends into in-fighting and anyone can be targeted. Of course, someone may be converted to the opposite faction again....')
        when 'actions'
          m.user.send('http://boardgamegeek.com/image/1812508/coup')
          m.user.send('General actions: Always available')
          m.user.send('* Income: Take one coin from the treasury.')
          m.user.send('* Foreign Aid: Take two coin from the treasury (blockable by Duke).')
          m.user.send('* Coup: Pay seven coins and launch a coup against an opponent, forcing that player to lose an influence. If you have ten coins, you must take this action.')
          m.user.send('Character actions: Anyone may perform these actions, but if challenged they must show that they influence that character.')
          m.user.send('* Duke: Take three coins from the treasury. Block someone from taking foreign aid.')
          m.user.send('* Assassin: Pay three coins and try to assassinate another player\'s character (blockable by Contessa).')
          m.user.send('* Contessa: Block an assassination attempt against yourself.')
          m.user.send('* Captain: Take two coins from another player (blockable by Captain or Ambassador). Block someone from stealing coins from you.')
          m.user.send('* Ambassador: Draw two character cards from the Court Deck, choose which (if any) to exchange with your face-down characters, then return two. Block someone from stealing coins from you.')
        else
          m.user.send 'Each player starts the game with two coins and two influence - i.e., two face-down character cards; the fifteen card deck consists of three copies of five different characters, each with a unique set of powers.'
          m.user.send('You can see all possible actions with the command "!rules actions", or by consulting the player aid at http://boardgamegeek.com/image/1812508/coup')
          m.user.send('On your turn, you can take any character\'s action, regardless of which characters you actually have in front of you, or you can take one three actions that require no character: Income, Foreign Aid, or Coup (if you have ten coins, you must Coup).')
          m.user.send('When you take one of the character actions - whether actively on your turn, or defensively in response to someone else\'s action - that character\'s action automatically succeeds unless an opponent challenges you.')
          m.user.send('When challenged to show a character, if you can\'t reveal the character (or choose not to), you lose an influence, turning one of your characters face-up. Face-up characters cannot be used, and if both of your characters are face-up, you\'re out of the game.')
          m.user.send('If you do have the character in question and choose to reveal it, the opponent loses an influence, then you shuffle that character into the deck and draw a new one, perhaps getting the same character again and perhaps not.')
          m.user.send('The last player to still have influence - that is, a face-down character - wins the game!')
        end
      end

      def game_status(game)
        turn = game.current_turn

        action = "#{dehighlight_nick(turn.active_player.user.nick)}'s #{turn.action.name}" if turn.action
        action = "#{action} on #{dehighlight_nick(turn.target_player.user.nick)}" if turn.target_player
        block = "#{dehighlight_nick(turn.counteracting_player.user.nick)}'s #{turn.counteraction.character_required.upcase} blocking #{action}" if turn.counteraction

        if turn.waiting_for_action?
          "Waiting on #{turn.active_player} to take an action"
        elsif turn.waiting_for_action_challenge?
          players = game.not_reacted.map(&:user).join(", ")
          "Waiting on players to PASS or CHALLENGE #{action}: #{players}"
        elsif turn.waiting_for_action_challenge_reply?
          "Waiting on #{turn.active_player} to respond to challenge against #{action}"
        elsif turn.waiting_for_action_challenge_loser?
          "Waiting on #{turn.action_challenger} to pick character to lose"
        elsif turn.waiting_for_block?
          if turn.action.needs_target
            players = turn.target_player.to_s
          else
            players = game.not_reacted.map(&:user).join(", ")
          end
          "Waiting on players to PASS or BLOCK #{action}: #{players}"
        elsif turn.waiting_for_block_challenge?
          players = game.not_reacted.map(&:user).join(", ")
          "Waiting on players to PASS or CHALLENGE #{block}: #{players}"
        elsif turn.waiting_for_block_challenge_reply?
          "Waiting on #{turn.counteracting_player} to respond to challenge against #{block}"
        elsif turn.waiting_for_block_challenge_loser?
          "Waiting on #{turn.block_challenger} to pick character to lose"
        elsif turn.waiting_for_decision?
          "Waiting on #{turn.decider} to make decision on #{turn.action.name}"
        elsif turn.waiting_for_initial_characters?
          players = game.not_selected_initial_character.map(&:user).join(", ")
          'Waiting on players to pick character: ' + players
        else
          "Unknown status #{turn.state}"
        end
      end
    end
  end
end
