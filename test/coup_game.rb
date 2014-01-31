require File.expand_path(File.dirname(__FILE__)) + '/../lib/cinch/plugins/coup_game'

TURN_ORDER_REGEX3 = /^Turn order is: (p[1-3]) (p[1-3]) (p[1-3])$/
TURN_ORDER_REGEX6 = /^Turn order is: (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6])$/
CHOICE_REGEX = /^Choose a character to turn face up: 1 - \([A-Z]+\) or 2 - \([A-Z]+\); "!lose 1" or "!lose 2"$/

CHANNAME = '#playcoup'

class Message
  attr_reader :user, :channel
  def initialize(user, channel)
    @user = user
    @channel = channel
  end

  def reply(msg, _)
    if @channel
      @channel.send(msg)
    else
      @user.send(msg)
    end
  end
end

class MyUser
  attr_reader :name, :messages
  def initialize(name)
    @name = name
    @messages = []
  end

  alias :nick :name

  def ==(that)
    return false if that.nil?
    # IS THIS RIGHT?! Does this work in irc?!?!
    if that.is_a?(String)
      @name == that
    else
      @name == that.name
    end
  end

  def send(msg)
    @messages << msg
  end
end

class MyChannel
  attr_reader :name
  attr_reader :messages

  def initialize(name, users)
    @name = name
    @users = users
    @messages = []
  end

  def has_user?(user)
    @users.has_key?(user.name)
  end

  def send(msg)
    @messages << msg
  end

  def voice(_)
    nil
  end
  alias :devoice :voice
end

describe Cinch::Plugins::CoupGame do
  def message_from(username)
    Message.new(@players[username], @chan)
  end
  def pm_from(username)
    Message.new(@players[username], nil)
  end

  before :each do
    b = Cinch::Bot.new do
      configure do |c|
        c.plugins.options[Cinch::Plugins::CoupGame] = {
          :channel => '#playcoup',
        }
      end
    end

    @player_names = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'npc']
    @players = Hash.new { |h, x| raise 'Nonexistent player ' + x }

    @player_names.each { |n|
      @players[n] = MyUser.new(n)
    }

    @chan = MyChannel.new(CHANNAME, @players)
    @game = Cinch::Plugins::CoupGame.new(b)
    @game.stub('sleep') { |x| puts "Slept for #{x} seconds" }
    @game.stub('Channel') { |x|
      if x == CHANNAME
        @chan
      else
        raise 'Asked for channel ' + x
      end
    }
    @game.stub('User') { |x|
      if x.is_a?(String)
        @players[x]
      elsif x.is_a?(MyUser)
        x
      else
        raise 'Unrecognized User arg'
      end
    }

  end

  context 'when game is empty' do
    it 'lets p1 join' do
      @game.join(message_from('p1'))
      expect(@chan.messages).to be == ['p1 has joined the game (1/6)']
    end

    it 'does not let p1 leave' do
      @game.leave(message_from('p1'))
      expect(@chan.messages).to be == []
    end

    it 'does not let p1 start' do
      @game.start_game(message_from('p1'))
      expect(@chan.messages).to be == ['Need at least 3 to start a game.']
    end
  end

  context 'when p1 has joined the game' do
    before :each do
      @game.join(message_from('p1'))
      expect(@chan.messages).to be == ['p1 has joined the game (1/6)']
      @chan.messages.clear
    end

    it 'lets p2 join' do
      @game.join(message_from('p2'))
      expect(@chan.messages).to be == ['p2 has joined the game (2/6)']
    end

    it 'lets p1 leave' do
      @game.leave(message_from('p1'))
      expect(@chan.messages).to be == ['p1 has left the game (0/6)']
    end

    it 'does not let p1 start' do
      @game.start_game(message_from('p1'))
      expect(@chan.messages).to be == ['Need at least 3 to start a game.']
    end
  end

  context 'when p1, p2, p3 have joined the game' do
    before :each do
      @game.join(message_from('p1'))
      @game.join(message_from('p2'))
      @game.join(message_from('p3'))
      expect(@chan.messages).to be == [
        'p1 has joined the game (1/6)',
        'p2 has joined the game (2/6)',
        'p3 has joined the game (3/6)',
      ]
      @chan.messages.clear
    end

    it 'does not let p4 start' do
      @game.start_game(message_from('p4'))
      expect(@chan.messages).to be == ['You are not in the game.']
    end

    it 'lets p1 start' do
      @game.start_game(message_from('p1'))
      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      expect(@chan.messages[-2]).to be =~ TURN_ORDER_REGEX3
      expect(@chan.messages[-1]).to be =~ /^FIRST TURN\. Player: p[1-3]\. Please choose an action\./
    end
  end

  context 'when p1..3 are playing a game' do
    NUM_PLAYERS = 3
    before :each do
      (1..NUM_PLAYERS).each { |i|
        p = "p#{i}"
        @game.join(message_from(p))
        expect(@chan.messages.size).to be == i
        expect(@chan.messages[-1]).to be == "#{p} has joined the game (#{i}/6)"
      }
      @chan.messages.clear
      @game.start_game(message_from('p1'))

      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX3.match(@chan.messages[-2]))
      @order = match
      expect(@chan.messages[-1]).to be == "FIRST TURN. Player: #{@order[1]}. Please choose an action."
      @chan.messages.clear
    end

    it 'does nothing if p1 starts again' do
      @game.start_game(message_from('p1'))
      expect(@chan.messages).to be == []
    end

    # ===== Income =====

    it 'lets player take income without reactions' do
      @game.do_action(message_from(@order[1]), 'income')
      expect(@chan.messages).to be == [
        "#{@order[1]} uses INCOME",
        "#{@order[1]} proceeds with INCOME. Take 1 coin.",
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]
    end

    # ===== Foreign Aid =====

    context 'when player takes foreign aid' do
      before :each do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        expect(@chan.messages).to be == ["#{@order[1]} uses FOREIGN_AID"]
        @chan.messages.clear
      end

      it 'does not let a captain block' do
        @game.do_block(message_from(@order[2]), 'captain')
        expect(@chan.messages).to be == []
        expect(@players[@order[2]].messages[-1]).to be == 'CAPTAIN does not block that FOREIGN_AID.'
      end

      it 'gives player two coins if nobody challenges' do
        (2...NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }

        @game.react_pass(message_from(@order[NUM_PLAYERS]))
        expect(@chan.messages).to be == [
          "#{@order[NUM_PLAYERS]} passes.",
          "#{@order[1]} proceeds with FOREIGN_AID. Take 2 coins.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
      end

      context 'when a player blocks with duke' do
        before :each do
          @game.do_block(message_from(@order[2]), 'duke')
          expect(@chan.messages).to be == ["#{@order[2]} uses DUKE"]
          @chan.messages.clear
        end

        it 'blocks aid if nobody challenges' do
          (3..NUM_PLAYERS).each { |i|
            @game.react_pass(message_from(@order[i]))
            expect(@chan.messages).to be == ["#{@order[i]} passes."]
            @chan.messages.clear
          }

          @game.react_pass(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} passes.",
            "#{@order[1]}'s FOREIGN_AID was blocked by #{@order[2]} with DUKE.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        # TODO foreign aid block challenged
        # If challenger wins, duke loses influence and player gets foreign aid
        # If challenger loses, challenger loses influence
      end
    end

    # ===== Coup =====

    it 'does not let a player with 6 coins use coup' do
      4.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end
      @chan.messages.clear

      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'coup', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You need 7 coins to use COUP, but you only have 6 coins.']
    end

    it 'lets a player with 7 coins use coup' do
      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end
      @chan.messages.clear

      p = @players[@order[2]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'coup', @order[2])
      expect(@chan.messages).to be == [
        "#{@order[1]} uses COUP on #{@order[2]}",
        "#{@order[1]} proceeds with COUP. Pay 7 coins, choose player to lose influence: #{@order[2]}.",
      ]

      expect(p.messages.size).to be == 1
      expect(p.messages[-1]).to be =~ CHOICE_REGEX
    end

    it 'does not let player switch instead of flip when couped' do
      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end

      # 1 uses coup on 2
      @game.do_action(message_from(@order[1]), 'coup', @order[2])

      @chan.messages.clear

      # 2 will now... switch?!
      @game.switch_cards(message_from(@order[2]), '1')
      expect(@chan.messages).to be == []
    end

    context 'when a player has 10 coins' do
      before :each do
        8.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end
        @chan.messages.clear
      end

      it 'does not let that player use income' do
        p = @players[@order[1]]
        p.messages.clear

        @game.do_action(message_from(@order[1]), 'income')
        expect(@chan.messages).to be == []

        expect(p.messages).to be == ['Since you have 10 coins, you must use COUP. !action coup <target>']
      end

      it 'lets that player use coup' do
        p = @players[@order[2]]
        p.messages.clear

        @game.do_action(message_from(@order[1]), 'coup', @order[2])
        expect(@chan.messages).to be == [
          "#{@order[1]} uses COUP on #{@order[2]}",
          "#{@order[1]} proceeds with COUP. Pay 7 coins, choose player to lose influence: #{@order[2]}.",
        ]

        expect(p.messages.size).to be == 1
        expect(p.messages[-1]).to be =~ CHOICE_REGEX
      end
    end

    # ===== Ambassador =====

    context 'when player with 2 influence uses ambassador' do
      before :each do
        @game.do_action(message_from(@order[1]), 'ambassador')
        expect(@chan.messages).to be == ["#{@order[1]} uses AMBASSADOR"]
        @chan.messages.clear
      end

      context 'when nobody challenges' do
        before :each do
          (2...NUM_PLAYERS).each { |i|
            @game.react_pass(message_from(@order[i]))
            expect(@chan.messages).to be == ["#{@order[i]} passes."]
            @chan.messages.clear
          }

          p = @players[@order[1]]
          p.messages.clear
          @game.react_pass(message_from(@order[NUM_PLAYERS]))
          expect(@chan.messages).to be == [
            "#{@order[NUM_PLAYERS]} passes.",
            "#{@order[1]} proceeds with AMBASSADOR. Exchange cards with Court Deck.",
          ]
          @chan.messages.clear

          expect(p.messages.size).to be == 8

          expect(p.messages[-8]).to be =~ /You drew [A-Z]+ and [A-Z]+ from the Court Deck./
          expect(p.messages[-7]).to be == "Choose an option for a new hand; \"!switch #\""
          choices = Array.new(7)
          (1..6).each { |i|
            index = -7 + i
            match = /^#{i} - \[(\w+)\] \[(\w+)\]$/.match(p.messages[index])
            expect(match).to_not be_nil
            choices[i] = match
          }
        end

        it 'lets player switch' do
          @game.switch_cards(message_from(@order[1]), '1')
          expect(@chan.messages).to be == [
            "#{@order[1]} shuffles two cards into the Court Deck.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        it 'does not let player flip card' do
          @game.flip_card(message_from(@order[1]), '1')
          expect(@chan.messages).to be == []
        end
      end

      # TODO ambassador switch challenged
      # If challenger wins, ambassador loses influence
      # If challenger loses, challenger loses influence AND ambassador still switches (in either order is possible?!)
    end

    # ===== Assassin =====

    it 'does not let a player with 2 coins use assassin' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'assassin', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You need 3 coins to use ASSASSIN, but you only have 2 coins.']
    end

    context 'when player uses assassin' do
      before :each do
        # Have each player take income to bump them up to 3 coins
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
          expect(@chan.messages.size).to be == 3 * i
        }
        @chan.messages.clear

        # Now first player uses assassin action
        @game.do_action(message_from(@order[1]), 'assassin', @order[2])
        expect(@chan.messages).to be == ["#{@order[1]} uses ASSASSIN on #{@order[2]}"]
        @chan.messages.clear
      end

      context 'when nobody challenges' do
        before :each do
          (2...NUM_PLAYERS).each { |i|
            @game.react_pass(message_from(@order[i]))
            expect(@chan.messages).to be == ["#{@order[i]} passes."]
            @chan.messages.clear
          }

          p = @players[@order[2]]
          p.messages.clear

          @game.react_pass(message_from(@order[NUM_PLAYERS]))
          expect(@chan.messages).to be == [
            "#{@order[NUM_PLAYERS]} passes.",
            "#{@order[1]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[2]}.",
          ]
          @chan.messages.clear

          expect(p.messages.size).to be == 1
          expect(p.messages[-1]).to be =~ CHOICE_REGEX

          @game.flip_card(message_from(@order[2]), '1')
          expect(@chan.messages.size).to be == 2
          expect(@chan.messages[-2]).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
          expect(@chan.messages[-1]).to be == "#{@order[2]}: It is your turn. Please choose an action."
          @chan.messages.clear
        end

        it 'makes second player flip a card' do
          # It's already in the before
        end

        context 'when player with 1 influence uses ambassador' do
          before :each do
            @game.do_action(message_from(@order[2]), 'ambassador')
            expect(@chan.messages).to be == ["#{@order[2]} uses AMBASSADOR"]
            @chan.messages.clear
          end

          context 'when nobody challenges' do
            before :each do
              (3..NUM_PLAYERS).each { |i|
                @game.react_pass(message_from(@order[i]))
                expect(@chan.messages).to be == ["#{@order[i]} passes."]
                @chan.messages.clear
              }

              p = @players[@order[2]]
              p.messages.clear
              @game.react_pass(message_from(@order[1]))
              expect(@chan.messages).to be == [
                "#{@order[1]} passes.",
                "#{@order[2]} proceeds with AMBASSADOR. Exchange cards with Court Deck.",
              ]
              @chan.messages.clear

              expect(p.messages.size).to be == 5

              expect(p.messages[-5]).to be =~ /You drew [A-Z]+ and [A-Z]+ from the Court Deck./
              expect(p.messages[-4]).to be == "Choose an option for a new hand; \"!switch #\""
              choices = Array.new(3)
              (1..3).each { |i|
                index = -4 + i
                match = /^#{i} - \[(\w+)\]$/.match(p.messages[index])
                expect(match).to_not be_nil
                choices[i] = match
              }

            end

            it 'lets player switch' do
              @game.switch_cards(message_from(@order[2]), '1')
              expect(@chan.messages).to be == [
                "#{@order[2]} shuffles two cards into the Court Deck.",
                "#{@order[3]}: It is your turn. Please choose an action.",
              ]
            end

            it 'does not let player flip card' do
              @game.flip_card(message_from(@order[2]), '1')
              expect(@chan.messages).to be == []
            end
          end
        end
      end

      # TODO assassin kill challenged
      # If challenger wins, only assassin loses influence.
      # If target challenges and loses, target is out of the game!
      # If an unrelated player challenges and loses, target and challenger each lose influence!
      # (In either order is possible?!)

      it 'does not let unrelated player block with contessa' do
        p = @players[@order[3]]
        p.messages.clear

        @game.do_block(message_from(@order[3]), 'contessa')
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['You can only block with CONTESSA if you are the target.']
      end

      context 'when target blocks with contessa' do
        before :each do
          @game.do_block(message_from(@order[2]), 'contessa')
          expect(@chan.messages).to be == ["#{@order[2]} uses CONTESSA"]
          @chan.messages.clear
        end

        it 'blocks assassination if nobody challenges' do
          (3..NUM_PLAYERS).each { |i|
            @game.react_pass(message_from(@order[i]))
            expect(@chan.messages).to be == ["#{@order[i]} passes."]
            @chan.messages.clear
          }

          @game.react_pass(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} passes.",
            "#{@order[1]}'s ASSASSIN was blocked by #{@order[2]} with CONTESSA.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        # TODO assassin kill block challenged
        # If target does have contessa, only challenger loses influence.
        # If target does not have contessa, they are out of the game!
      end
    end

    it 'does not let player flip a flipped card' do
      # Have each player take income to bump them up to 3 coins
      (1..NUM_PLAYERS).each { |i|
        @game.do_action(message_from(@order[i]), 'income')
      }

      # 1 uses assassin on 3
      @game.do_action(message_from(@order[1]), 'assassin', @order[3])

      # 2, 3 pass
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))

      # 3 flips card 1
      @game.flip_card(message_from(@order[3]), '1')

      # 2 uses assassin on 3
      @game.do_action(message_from(@order[2]), 'assassin', @order[3])

      # 1, 3 pass
      @game.react_pass(message_from(@order[1]))
      @game.react_pass(message_from(@order[3]))

      @chan.messages.clear
      p = @players[@order[3]]
      p.messages.clear

      # 3 flips card 1 again
      @game.flip_card(message_from(@order[3]), '1')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You have already flipped that card.']
    end

    it 'does not let player switch instead of flip when assassinated' do
      # Have each player take income to bump them up to 3 coins
      (1..NUM_PLAYERS).each { |i|
        @game.do_action(message_from(@order[i]), 'income')
      }

      # 1 uses assassin on 2
      @game.do_action(message_from(@order[1]), 'assassin', @order[2])

      # 2, 3 pass
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))

      @chan.messages.clear

      # 2 will now... switch?!
      @game.switch_cards(message_from(@order[2]), '1')
      expect(@chan.messages).to be == []
    end

    # ===== Captain =====

    context 'when player uses captain' do
      before :each do
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages).to be == ["#{@order[1]} uses CAPTAIN on #{@order[2]}"]
        @chan.messages.clear
      end

      it 'steals two coins if nobody challenges' do
        (2...NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }

        p = @players[@order[2]]
        p.messages.clear

        @game.react_pass(message_from(@order[NUM_PLAYERS]))
        expect(@chan.messages).to be == [
          "#{@order[NUM_PLAYERS]} passes.",
          "#{@order[1]} proceeds with CAPTAIN. Take 2 coins from another player: #{@order[2]}.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
        @chan.messages.clear
      end

      it 'does not let unrelated player block with ambassador' do
        p = @players[@order[3]]
        p.messages.clear

        @game.do_block(message_from(@order[3]), 'ambassador')
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['You can only block with AMBASSADOR if you are the target.']
      end

      it 'does not let unrelated player block with captain' do
        p = @players[@order[3]]
        p.messages.clear

        @game.do_block(message_from(@order[3]), 'captain')
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['You can only block with CAPTAIN if you are the target.']
      end

      # TODO captain steal challenged
      # If challenger wins, only captain loses influence.
      # If challenger loses, challenger loses influence and captain steals.

      context 'when target blocks with ambassador' do
        before :each do
          @game.do_block(message_from(@order[2]), 'ambassador')
          expect(@chan.messages).to be == ["#{@order[2]} uses AMBASSADOR"]
          @chan.messages.clear
        end

        it 'blocks steal if nobody challenges' do
          (3..NUM_PLAYERS).each { |i|
            @game.react_pass(message_from(@order[i]))
            expect(@chan.messages).to be == ["#{@order[i]} passes."]
            @chan.messages.clear
          }

          @game.react_pass(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} passes.",
            "#{@order[1]}'s CAPTAIN was blocked by #{@order[2]} with AMBASSADOR.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        # TODO captain steal block challenged
        # If target does have ambassador, only challenger loses influence.
        # If target does not have ambassador, they lose influence and money.
      end

      context 'when target blocks with captain' do
        before :each do
          @game.do_block(message_from(@order[2]), 'captain')
          expect(@chan.messages).to be == ["#{@order[2]} uses CAPTAIN"]
          @chan.messages.clear
        end

        it 'blocks steal if nobody challenges' do
          (3..NUM_PLAYERS).each { |i|
            @game.react_pass(message_from(@order[i]))
            expect(@chan.messages).to be == ["#{@order[i]} passes."]
            @chan.messages.clear
          }

          @game.react_pass(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} passes.",
            "#{@order[1]}'s CAPTAIN was blocked by #{@order[2]} with CAPTAIN.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        # TODO captain steal block challenged
        # If target does have captain, only challenger loses influence.
        # If target does not have captain, they lose influence and money.
      end
    end

    it 'takes 0 coins from a player with 0 coins' do
      # 1 uses captain on 3
      @game.do_action(message_from(@order[1]), 'captain', @order[3])

      # 2, 3 pass
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 2
      expect(@game.coins(@players[@order[3]])).to be == 0

      # 2 uses captain on 3
      @game.do_action(message_from(@order[1]), 'captain', @order[3])

      # 1, 3 pass
      @game.react_pass(message_from(@order[1]))
      @game.react_pass(message_from(@order[3]))

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 2
      expect(@game.coins(@players[@order[3]])).to be == 0
    end

    it 'takes 1 coin from a player with 1 coin' do
      # 1 uses captain on 2
      @game.do_action(message_from(@order[1]), 'captain', @order[2])

      # 2, 3 pass
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))

      # 2 uses income
      @game.do_action(message_from(@order[1]), 'income', @order[2])

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 1
      expect(@game.coins(@players[@order[3]])).to be == 2

      # 3 uses captain on 2
      @game.do_action(message_from(@order[3]), 'captain', @order[2])

      # 1, 2 pass
      @game.react_pass(message_from(@order[1]))
      @game.react_pass(message_from(@order[2]))

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 0
      expect(@game.coins(@players[@order[3]])).to be == 3
    end

    # ===== Duke =====

    context 'when player uses duke' do
      before :each do
        @game.do_action(message_from(@order[1]), 'duke')
        expect(@chan.messages).to be == ["#{@order[1]} uses DUKE"]
        @chan.messages.clear
      end

      it 'gives duke 3 coins if nobody challenges' do
        (2...NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }

        p = @players[@order[1]]
        p.messages.clear
        @game.react_pass(message_from(@order[NUM_PLAYERS]))
        expect(@chan.messages).to be == [
          "#{@order[NUM_PLAYERS]} passes.",
          "#{@order[1]} proceeds with DUKE. Take 3 coins.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
      end

      # TODO duke tax challenged
      # If challenger wins, duke loses influence
      # If challenger loses, challenger loses influence and duke collects money
    end
  end
end
