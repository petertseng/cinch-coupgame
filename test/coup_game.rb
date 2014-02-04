require File.expand_path(File.dirname(__FILE__)) + '/../lib/cinch/plugins/coup_game'

TURN_ORDER_REGEX3 = /^Turn order is: (p[1-3]) (p[1-3]) (p[1-3])$/
TURN_ORDER_REGEX6 = /^Turn order is: (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6])$/
CHOICE_REGEX = /^Choose a character to turn face up: 1 - \([A-Z]+\) or 2 - \([A-Z]+\); "!lose 1" or "!lose 2"$/

CHANNAME = '#playcoup'
CHANNAME2 = '#otherchannel'
BOGUS_CHANNEL = '#blahblahblah'

CHALLENGE_PROMPT = 'All other players: Would you like to challenge ("!challenge") or not ("!pass")?'

class Message
  attr_reader :user, :channel
  def initialize(user, channel)
    @user = user
    @channel = channel
  end

  def reply(msg, prefix = false)
    if @channel
      pre = prefix ? (@user.name + ': ') : ''
      @channel.send(pre + msg)
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
  alias :to_s :name

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
  alias :moderated= :voice
end

describe Cinch::Plugins::CoupGame do
  def message_from(username, channel = nil)
    Message.new(@players[username], channel || @chan)
  end
  def pm_from(username)
    Message.new(@players[username], nil)
  end

  before :each do
    b = Cinch::Bot.new do
      configure do |c|
        c.plugins.options[Cinch::Plugins::CoupGame] = {
          :channels => [
            CHANNAME,
            CHANNAME2,
          ],
        }
      end
    end
    b.loggers.stub('debug') { nil }

    @player_names = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'npc']
    @players = Hash.new { |h, x| raise 'Nonexistent player ' + x }

    @player_names.each { |n|
      @players[n] = MyUser.new(n)
    }

    @chan = MyChannel.new(CHANNAME, @players)
    @chan2 = MyChannel.new(CHANNAME2, @players)

    @game = Cinch::Plugins::CoupGame.new(b)
    @game.stub('sleep') { |x| nil }
    @game.stub('Channel') { |x|
      if x == CHANNAME
        @chan
      elsif x == CHANNAME2
        @chan2
      elsif x == BOGUS_CHANNEL
        MyChannel.new(BOGUS_CHANNEL, [])
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
      expect(@chan.messages).to be == ['p1: Need at least 3 to start a game.']
    end

    it 'reports that game is empty in status' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ['No game in progress.']
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
      expect(@chan.messages).to be == ['p1: Need at least 3 to start a game.']
    end

    it 'reports that p1 is in game in status' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ['Game being started. 1 players have joined: p1']
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
      expect(@chan.messages).to be == ['p4: You are not in the game.']
    end

    it 'lets p1 start' do
      @game.start_game(message_from('p1'))
      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      expect(@chan.messages[-2]).to be =~ TURN_ORDER_REGEX3
      expect(@chan.messages[-1]).to be =~ /^FIRST TURN\. Player: p[1-3]\. Please choose an action\./
    end
  end

  describe 'Multiple channels' do
    it 'prompts for a channel if a player joins via PM without arg' do
      @game.join(pm_from('p1'))
      expect(@players['p1'].messages).to be == [
        'To join a game via PM you must specify the channel: !join #channel',
      ]
      expect(@chan.messages).to be == []
      expect(@chan2.messages).to be == []
    end

    it 'lets a player join via PM with arg' do
      @game.join(pm_from('p1'), CHANNAME)
      expect(@chan.messages).to be == ['p1 has joined the game (1/6)']
    end

    it 'lets a player join a different channel publicly with arg' do
      @game.join(pm_from('p1'), CHANNAME2)
      expect(@chan.messages).to be == []
      expect(@chan2.messages).to be == ['p1 has joined the game (1/6)']
    end

    it 'forbids joining the game of an unknown channel' do
      @game.join(message_from('p1'), BOGUS_CHANNEL)
      expect(@chan.messages).to be == ["p1: #{BOGUS_CHANNEL} is not a valid channel to join"]
    end

    context 'when p1 joins channel 1 and p2 joins channel 2' do
      before :each do
        @game.join(message_from('p1', @chan))
        @game.join(message_from('p2', @chan2))
        expect(@chan.messages).to be == ['p1 has joined the game (1/6)']
        expect(@chan2.messages).to be == ['p2 has joined the game (1/6)']
        @chan.messages.clear
        @chan2.messages.clear
      end

      it 'forbids p1 from publicly joining channel 2 as well' do
        @game.join(message_from('p1', @chan2))
        expect(@chan2.messages).to be == ["p1: You are already in the #{CHANNAME} game"]
      end

      it 'forbids p1 from privately joining channel 2 as well' do
        @game.join(pm_from('p1'), CHANNAME2)
        expect(@chan2.messages).to be == []
        expect(@players['p1'].messages).to be == ["You are already in the #{CHANNAME} game"]
      end

      it 'makes p1 leave channel 1 when p1 leaves in PM' do
        @game.leave(pm_from('p1'))
        expect(@chan.messages).to be == ['p1 has left the game (0/6)']
        expect(@chan2.messages).to be == []
      end

      it 'makes p2 leave channel 2 when p2 leaves in PM' do
        @game.leave(pm_from('p2'))
        expect(@chan.messages).to be == []
        expect(@chan2.messages).to be == ['p2 has left the game (0/6)']
      end

      it 'lets p1 leave channel 1 publicly' do
        @game.leave(message_from('p1', @chan))
        expect(@chan.messages).to be == ['p1 has left the game (0/6)']
        expect(@chan2.messages).to be == []
      end

      it 'does nothing when p1 tries to leave channel 2 publicly' do
        @game.leave(message_from('p1', @chan2))
        expect(@chan.messages).to be == []
        expect(@chan2.messages).to be == []
      end
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

    it 'reports waiting on action in status' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ["Waiting on #{@order[1]} to take an action"]
    end

    # ===== Income =====

    it 'lets player take income without reactions' do
      @game.do_action(message_from(@order[1]), 'income')
      expect(@chan.messages).to be == [
        "#{@order[1]} uses INCOME",
        "#{@order[1]} proceeds with INCOME. Take 1 coin.",
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@order[1])).to be == 3
    end

    # ===== Foreign Aid =====

    context 'when player takes foreign aid' do
      before :each do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        expect(@chan.messages).to be == [
          "#{@order[1]} uses FOREIGN_AID",
          "All other players: Would you like to block the FOREIGN_AID (\"!block duke\") or not (\"!pass\")?",
        ]
        @chan.messages.clear
      end

      it 'does not let a captain block' do
        @game.do_block(message_from(@order[2]), 'captain')
        expect(@chan.messages).to be == []
        expect(@players[@order[2]].messages[-1]).to be == 'CAPTAIN does not block that FOREIGN_AID.'
      end

      it 'gives player two coins if nobody blocks' do
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

        expect(@game.coins(@order[1])).to be == 4
      end

      it 'blocks aid if a player blocks with duke unchallenged' do
        @game.do_block(message_from(@order[2]), 'duke')
        expect(@chan.messages).to be == [
          "#{@order[2]} uses DUKE",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

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

        expect(@game.coins(@order[1])).to be == 2
      end

      context 'when duke blocks and is challenged' do
        before :each do
          @game.force_characters(@order[2], :duke, :assassin)

          @game.do_block(message_from(@order[2]), 'duke')
          expect(@chan.messages).to be == [
            "#{@order[2]} uses DUKE",
            CHALLENGE_PROMPT,
          ].compact
          @chan.messages.clear

          @game.react_challenge(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} challenges #{@order[2]} on DUKE!",
          ]
          @chan.messages.clear
        end

        it 'continues to block if player shows duke' do
          @game.flip_card(message_from(@order[2]), '1')

          expect(@chan.messages).to be == [
            "#{@order[2]} reveals a [DUKE]. #{@order[1]} loses an influence.",
            "#{@order[2]} switches the character card with one from the deck.",
          ]
          @chan.messages.clear

          @game.flip_card(message_from(@order[1]), '1')

          expect(@chan.messages.shift).to be =~ /^#{@order[1]} turns a [A-Z]+ face up\.$/
          expect(@chan.messages).to be == [
            "#{@order[1]}'s FOREIGN_AID was blocked by #{@order[2]} with DUKE.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          expect(@game.coins(@order[1])).to be == 2
        end

        it 'no longer blocks if player does not show duke' do
          @game.flip_card(message_from(@order[2]), '2')
          expect(@chan.messages).to be == [
            "#{@order[2]} turns a ASSASSIN face up, losing an influence.",
            "#{@order[1]} proceeds with FOREIGN_AID. Take 2 coins.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
          expect(@game.coins(@order[1])).to be == 4
        end
      end
    end

    it 'allows foreign aid instead of foreign_aid' do
      @game.do_action(message_from(@order[1]), 'foreign aid')
      @game.do_action(message_from(@order[2]), 'foreign aid')
      (2..NUM_PLAYERS).each { |i|
        @game.react_pass(message_from(@order[i]))
      }
      expect(@game.coins(@order[1])).to be == 4
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

    context 'when a player with 7 coins uses coup' do
      before :each do
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
        @chan.messages.clear

        expect(p.messages.size).to be == 1
        expect(p.messages[-1]).to be =~ CHOICE_REGEX
      end

      it 'deducts 7 coins from the player' do
        expect(@game.coins(@order[1])).to be == 0
      end

      it 'lets target flip' do
        @game.flip_card(message_from(@order[2]), '1')
        expect(@chan.messages.size).to be == 2
        expect(@chan.messages[-2]).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages[-1]).to be == "#{@order[2]}: It is your turn. Please choose an action."
      end

      it 'does not let target switch instead of flip' do
        # 2 will now... switch?!
        @game.switch_cards(message_from(@order[2]), '1')
        expect(@chan.messages).to be == []
      end
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

    it 'does not let player flip an already-flipped card' do
      # Have each player take income to bump them up to 7 coins
      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end

      # 1 uses coup on 3
      @game.do_action(message_from(@order[1]), 'coup', @order[3])

      # 3 flips card 1
      @game.flip_card(message_from(@order[3]), '1')

      # 2 uses coup on 3
      @game.do_action(message_from(@order[2]), 'coup', @order[3])

      @chan.messages.clear
      p = @players[@order[3]]
      p.messages.clear

      # 3 flips card 1 again
      @game.flip_card(message_from(@order[3]), '1')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You have already flipped that card.']
    end

    # ===== Ambassador =====

    context 'when player with 2 influence uses ambassador unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'ambassador')
        expect(@chan.messages).to be == [
          "#{@order[1]} uses AMBASSADOR",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        p = @players[@order[1]]
        p.messages.clear

        # Have everyone pass
        (2...NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }
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

    context 'when player with 1 influence uses ambassador unchallenged' do
      before :each do
        # Have each player take income to bump them up to 7 coins
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # 1 uses coup on 2
        @game.do_action(message_from(@order[1]), 'coup', @order[2])

        # 2 flips card 1
        @game.flip_card(message_from(@order[2]), '1')
        @chan.messages.clear

        @game.do_action(message_from(@order[2]), 'ambassador')
        expect(@chan.messages).to be == [
          "#{@order[2]} uses AMBASSADOR",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        p = @players[@order[2]]
        p.messages.clear

        # Have everyone pass
        (3..NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }
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

    context 'when ambassador switches and is challenged' do
      before :each do
        @game.force_characters(@order[1], :ambassador, :duke)

        @game.do_action(message_from(@order[1]), 'ambassador')
        expect(@chan.messages).to be == [
          "#{@order[1]} uses AMBASSADOR",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          "#{@order[2]} challenges #{@order[1]} on AMBASSADOR!",
        ]
        @chan.messages.clear
      end

      it 'continues to switch if player shows ambassador' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == [
          "#{@order[1]} reveals a [AMBASSADOR]. #{@order[2]} loses an influence.",
          "#{@order[1]} switches the character card with one from the deck.",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[1]} proceeds with AMBASSADOR. Exchange cards with Court Deck.",
        ]
      end

      it 'no longer switches if player does not show ambassador' do
        @game.flip_card(message_from(@order[1]), '2')
        expect(@chan.messages).to be == [
          "#{@order[1]} turns a DUKE face up, losing an influence.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
      end
    end


    # ===== Assassin =====

    it 'does not let a player with 2 coins use assassin' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'assassin', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You need 3 coins to use ASSASSIN, but you only have 2 coins.']
    end

    context 'when player uses assassin unchallenged' do
      before :each do
        # Have each player take income to bump them up to 3 coins
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
          expect(@chan.messages.size).to be == 3 * i
        }
        @chan.messages.clear

        # Now first player uses assassin action
        @game.do_action(message_from(@order[1]), 'assassin', @order[2])
        expect(@chan.messages).to be == [
          "#{@order[1]} uses ASSASSIN on #{@order[2]}",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        # Have everyone pass
        (2...NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }
        @game.react_pass(message_from(@order[NUM_PLAYERS]))

        expect(@chan.messages).to be == [
          "#{@order[NUM_PLAYERS]} passes.",
          "#{@order[2]}: Would you like to block the ASSASSIN (\"!block contessa\") or not (\"!pass\")?",
        ]
        @chan.messages.clear
      end

      context 'when target does not block' do
        before :each do
          p = @players[@order[2]]
          p.messages.clear

          @game.react_pass(message_from(@order[2]))

          expect(@chan.messages).to be == [
            "#{@order[2]} passes.",
            "#{@order[1]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[2]}.",
          ]

          expect(p.messages.size).to be == 1
          expect(p.messages[-1]).to be =~ CHOICE_REGEX
          @chan.messages.clear
        end

        it 'deducts 3 gold from assassin' do
          expect(@game.coins(@order[1])).to be == 0
        end

        it 'lets target flip a card' do
          @game.flip_card(message_from(@order[2]), '1')
          expect(@chan.messages.size).to be == 2
          expect(@chan.messages[-2]).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
          expect(@chan.messages[-1]).to be == "#{@order[2]}: It is your turn. Please choose an action."
        end

        it 'does not lets target switch' do
          @game.switch_cards(message_from(@order[2]), '1')
          expect(@chan.messages).to be == []
        end
      end

      it 'does not let unrelated player block with contessa' do
        p = @players[@order[3]]
        p.messages.clear

        @game.do_block(message_from(@order[3]), 'contessa')
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['You can only block with CONTESSA if you are the target.']
      end

      it 'blocks assassination if target blocks with contessa unchallenged' do
        @game.do_block(message_from(@order[2]), 'contessa')
        expect(@chan.messages).to be == [
          "#{@order[2]} uses CONTESSA",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

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

        # But assassin still pays
        expect(@game.coins(@order[1])).to be == 0
      end

      context 'when contessa blocks and is challenged' do
        before :each do
          @game.force_characters(@order[2], :contessa, :captain)

          @game.do_block(message_from(@order[2]), 'contessa')
          expect(@chan.messages).to be == [
            "#{@order[2]} uses CONTESSA",
            CHALLENGE_PROMPT,
          ].compact
          @chan.messages.clear

          @game.react_challenge(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} challenges #{@order[2]} on CONTESSA!",
          ]
          @chan.messages.clear
        end

        it 'continues to block if player shows contessa' do
          @game.flip_card(message_from(@order[2]), '1')

          expect(@chan.messages).to be == [
            "#{@order[2]} reveals a [CONTESSA]. #{@order[1]} loses an influence.",
            "#{@order[2]} switches the character card with one from the deck.",
          ]
          @chan.messages.clear

          @game.flip_card(message_from(@order[1]), '1')

          expect(@chan.messages.shift).to be =~ /^#{@order[1]} turns a [A-Z]+ face up\.$/
          expect(@chan.messages).to be == [
            "#{@order[1]}'s ASSASSIN was blocked by #{@order[2]} with CONTESSA.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          # But assassin still pays
          expect(@game.coins(@order[1])).to be == 0
        end

        it 'no longer blocks if player does not show contessa' do
          @game.flip_card(message_from(@order[2]), '2')
          expect(@chan.messages).to be == [
            "#{@order[2]} turns a CAPTAIN face up, losing an influence.",
            "#{@order[1]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[2]}.",
          ]

          # And assassin still pays
          expect(@game.coins(@order[1])).to be == 0
        end
      end
    end

    context 'when assassin kills and is challenged' do
      before :each do
        @game.force_characters(@order[1], :assassin, :contessa)

        # Have each player take income to bump them up to 3 coins
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
          expect(@chan.messages.size).to be == 3 * i
        }
        @chan.messages.clear

        @game.do_action(message_from(@order[1]), 'assassin', @order[2])
        expect(@chan.messages).to be == [
          "#{@order[1]} uses ASSASSIN on #{@order[2]}",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          "#{@order[2]} challenges #{@order[1]} on ASSASSIN!",
        ]
        @chan.messages.clear
      end

      it 'continues to kill if player shows assassin' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == [
          "#{@order[1]} reveals a [ASSASSIN]. #{@order[2]} loses an influence.",
          "#{@order[1]} switches the character card with one from the deck.",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[2]}: Would you like to block the ASSASSIN (\"!block contessa\") or not (\"!pass\")?",
        ]

        @game.react_pass(message_from(@order[2]))

        expect(@game.coins(@order[1])).to be == 0
      end

      context 'when player does not show assassin' do
        before :each do
          @game.flip_card(message_from(@order[1]), '2')
        end

        it 'does not kill' do
          expect(@chan.messages).to be == [
            "#{@order[1]} turns a CONTESSA face up, losing an influence.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        it 'refunds the cost' do
          expect(@game.coins(@order[1])).to be == 3
        end
      end
    end

    # ===== Assassin Double Kills =====

    context 'when target with 2 influence bluffs contessa' do
      before :each do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }

        @game.force_characters(@order[2], :assassin, :assassin)

        # 1st uses assassin on 2nd
        @game.do_action(message_from(@order[1]), 'assassin', @order[2])

        # Players pass challenge
        @game.react_pass(message_from(@order[2]))
        @game.react_pass(message_from(@order[3]))

        # Target claims contessa
        @game.do_block(message_from(@order[2]), 'contessa')
        # Assassin challenges
        @game.react_challenge(message_from(@order[1]))

        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')
        expect(@chan.messages).to be == [
          "#{@order[2]} turns a ASSASSIN face up, losing an influence.",
          "#{@order[1]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[2]}.",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '2')
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages).to be == [
          "#{@order[2]} turns a ASSASSIN face up.",
          "#{@order[2]} has no more influence, and is out of the game.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
      end

      it 'deducts money from assassin' do
        expect(@game.coins(@order[1])).to be == 0
      end
    end

    context 'when target with 1 influence bluffs contessa' do
      before :each do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        @game.force_characters(@order[3], :assassin, :assassin)

        # 1st uses coup on 3rd
        @game.do_action(message_from(@order[1]), 'coup', @order[3])
        @game.flip_card(message_from(@order[3]), '1')

        # 2nd uses assassin on 3rd
        @game.do_action(message_from(@order[2]), 'assassin', @order[3])

        # Players pass challenge
        @game.react_pass(message_from(@order[1]))
        @game.react_pass(message_from(@order[3]))

        # Target claims contessa
        @game.do_block(message_from(@order[3]), 'contessa')

        @chan.messages.clear

        # Assassin challenges
        @game.react_challenge(message_from(@order[2]))
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages).to be == [
          "#{@order[2]} challenges #{@order[3]} on CONTESSA!",
          "#{@order[3]} turns a ASSASSIN face up, losing an influence.",
          "#{@order[3]} has no more influence, and is out of the game.",
          "#{@order[2]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[3]}.",
          "#{@order[1]}: It is your turn. Please choose an action.",
        ]
      end

      it 'deducts money from assassin' do
        expect(@game.coins(@order[2])).to be == 4
      end
    end

    context 'when target with 2 influence challenges assassin' do
      before :each do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }

        @game.force_characters(@order[1], :assassin, :assassin)

        # 1st uses assassin on 2nd
        @game.do_action(message_from(@order[1]), 'assassin', @order[2])

        # 2nd challenges
        @game.react_challenge(message_from(@order[2]))

        # assassin wins challenge
        @game.flip_card(message_from(@order[1]), '1')

        @chan.messages.clear

        # target dies from challenge
        @game.flip_card(message_from(@order[2]), '2')
        expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[2]}: Would you like to block the ASSASSIN (\"!block contessa\") or not (\"!pass\")?",
        ]

        # target passes block
        @game.react_pass(message_from(@order[2]))

        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[2]} has no more influence, and is out of the game.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
      end

      it 'deducts money from assassin' do
        expect(@game.coins(@order[1])).to be == 0
      end
    end

    context 'when target with 1 influence challenges assassin' do
      before :each do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        @game.force_characters(@order[2], :assassin, :assassin)

        # 1st uses coup on 3rd
        @game.do_action(message_from(@order[1]), 'coup', @order[3])
        @game.flip_card(message_from(@order[3]), '1')

        # 2nd uses assassin on 3rd
        @game.do_action(message_from(@order[2]), 'assassin', @order[3])

        # 1st challenges
        @game.react_challenge(message_from(@order[3]))

        # assassin wins challenge
        @game.flip_card(message_from(@order[2]), '1')

        @chan.messages.clear

        # target dies from challenge
        @game.flip_card(message_from(@order[3]), '2')
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages.shift).to be =~ /^#{@order[3]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[3]} has no more influence, and is out of the game.",
          "#{@order[2]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[3]}.",
          "#{@order[1]}: It is your turn. Please choose an action.",
        ]
      end

      it 'deducts money from assassin' do
        expect(@game.coins(@order[2])).to be == 4
      end
    end

    it 'double kills two separate players' do
      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end

      # two players coup each other
      @game.do_action(message_from(@order[1]), 'coup', @order[2])
      @game.flip_card(message_from(@order[2]), '1')
      @game.do_action(message_from(@order[2]), 'coup', @order[1])
      @game.flip_card(message_from(@order[1]), '1')

      @game.force_characters(@order[3], :assassin, :assassin)
      @game.do_action(message_from(@order[3]), 'assassin', @order[1])
      @game.react_challenge(message_from(@order[2]))
      @game.flip_card(message_from(@order[3]), '1')

      @chan.messages.clear

      @game.flip_card(message_from(@order[2]), '2')

      expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
      expect(@chan.messages).to be == [
        "#{@order[2]} has no more influence, and is out of the game.",
        "#{@order[1]}: Would you like to block the ASSASSIN (\"!block contessa\") or not (\"!pass\")?",
      ]
      @chan.messages.clear

      @game.react_pass(message_from(@order[1]))
      expect(@chan.messages).to be == [
        "#{@order[1]} passes.",
        "#{@order[3]} proceeds with ASSASSIN. Pay 3 coins, choose player to lose influence: #{@order[1]}.",
      ]
      @chan.messages.clear

      @game.flip_card(message_from(@order[1]), '2')
      expect(@chan.messages.shift).to be =~ /^#{@order[1]} turns a [A-Z]+ face up\.$/
      expect(@chan.messages).to be == [
        "#{@order[1]} has no more influence, and is out of the game.",
        "Game is over! #{@order[3]} wins!",
      ]
    end

    # ===== Captain =====

    context 'when player uses captain unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages).to be == [
          "#{@order[1]} uses CAPTAIN on #{@order[2]}",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        p = @players[@order[2]]
        p.messages.clear

        # Have everyone pass
        (2...NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }
        @game.react_pass(message_from(@order[NUM_PLAYERS]))

        expect(@chan.messages).to be == [
          "#{@order[NUM_PLAYERS]} passes.",
          "#{@order[2]}: Would you like to block the CAPTAIN (\"!block captain\" or \"!block ambassador\") or not (\"!pass\")?",
        ]
        @chan.messages.clear
      end

      it 'steals two coins if target does not block' do
        @game.react_pass(message_from(@order[2]))

        expect(@chan.messages).to be == [
          "#{@order[2]} passes.",
          "#{@order[1]} proceeds with CAPTAIN. Take 2 coins from another player: #{@order[2]}.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])) == 4
        expect(@game.coins(@order[2])) == 0
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

      it 'blocks steal if target blocks with ambassador' do
        @game.do_block(message_from(@order[2]), 'ambassador')
        expect(@chan.messages).to be == [
          "#{@order[2]} uses AMBASSADOR",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

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

        expect(@game.coins(@players[@order[1]])).to be == 2
        expect(@game.coins(@players[@order[2]])).to be == 2
      end

      context 'when ambassador blocks and is challenged' do
        before :each do
          @game.force_characters(@order[2], :ambassador, :duke)

          @game.do_block(message_from(@order[2]), 'ambassador')
          expect(@chan.messages).to be == [
            "#{@order[2]} uses AMBASSADOR",
            CHALLENGE_PROMPT,
          ].compact
          @chan.messages.clear

          @game.react_challenge(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} challenges #{@order[2]} on AMBASSADOR!",
          ]
          @chan.messages.clear
        end

        it 'continues to block if player shows ambassador' do
          @game.flip_card(message_from(@order[2]), '1')

          expect(@chan.messages).to be == [
            "#{@order[2]} reveals a [AMBASSADOR]. #{@order[1]} loses an influence.",
            "#{@order[2]} switches the character card with one from the deck.",
          ]
          @chan.messages.clear

          @game.flip_card(message_from(@order[1]), '1')

          expect(@chan.messages.shift).to be =~ /^#{@order[1]} turns a [A-Z]+ face up\.$/
          expect(@chan.messages).to be == [
            "#{@order[1]}'s CAPTAIN was blocked by #{@order[2]} with AMBASSADOR.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          expect(@game.coins(@order[1])).to be == 2
          expect(@game.coins(@order[2])).to be == 2
        end

        it 'no longer blocks if player does not show ambassador' do
          @game.flip_card(message_from(@order[2]), '2')
          expect(@chan.messages).to be == [
            "#{@order[2]} turns a DUKE face up, losing an influence.",
            "#{@order[1]} proceeds with CAPTAIN. Take 2 coins from another player: #{@order[2]}.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          expect(@game.coins(@order[1])).to be == 4
          expect(@game.coins(@order[2])).to be == 0
        end
      end

      it 'blocks steal if target blocks with captain unchallenged' do
        @game.do_block(message_from(@order[2]), 'captain')
        expect(@chan.messages).to be == [
          "#{@order[2]} uses CAPTAIN",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

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

        expect(@game.coins(@players[@order[1]])).to be == 2
        expect(@game.coins(@players[@order[2]])).to be == 2
      end

      context 'when captain blocks and is challenged' do
        before :each do
          @game.force_characters(@order[2], :captain, :ambassador)

          @game.do_block(message_from(@order[2]), 'captain')
          expect(@chan.messages).to be == [
            "#{@order[2]} uses CAPTAIN",
            CHALLENGE_PROMPT,
          ].compact
          @chan.messages.clear

          @game.react_challenge(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "#{@order[1]} challenges #{@order[2]} on CAPTAIN!",
          ]
          @chan.messages.clear
        end

        it 'continues to block if player shows captain' do
          @game.flip_card(message_from(@order[2]), '1')

          expect(@chan.messages).to be == [
            "#{@order[2]} reveals a [CAPTAIN]. #{@order[1]} loses an influence.",
            "#{@order[2]} switches the character card with one from the deck.",
          ]
          @chan.messages.clear

          @game.flip_card(message_from(@order[1]), '1')

          expect(@chan.messages.shift).to be =~ /^#{@order[1]} turns a [A-Z]+ face up\.$/
          expect(@chan.messages).to be == [
            "#{@order[1]}'s CAPTAIN was blocked by #{@order[2]} with CAPTAIN.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          expect(@game.coins(@order[1])).to be == 2
          expect(@game.coins(@order[2])).to be == 2
        end

        it 'no longer blocks if player does not show captain' do
          @game.flip_card(message_from(@order[2]), '2')
          expect(@chan.messages).to be == [
            "#{@order[2]} turns a AMBASSADOR face up, losing an influence.",
            "#{@order[1]} proceeds with CAPTAIN. Take 2 coins from another player: #{@order[2]}.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          expect(@game.coins(@order[1])).to be == 4
          expect(@game.coins(@order[2])).to be == 0
        end
      end

    end

    context 'when captain steals and is challenged' do
      before :each do
        @game.force_characters(@order[1], :captain, :ambassador)

        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages).to be == [
          "#{@order[1]} uses CAPTAIN on #{@order[2]}",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          "#{@order[2]} challenges #{@order[1]} on CAPTAIN!",
        ]
        @chan.messages.clear
      end

      it 'continues to steal if player shows captain' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == [
          "#{@order[1]} reveals a [CAPTAIN]. #{@order[2]} loses an influence.",
          "#{@order[1]} switches the character card with one from the deck.",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[2]}: Would you like to block the CAPTAIN (\"!block captain\" or \"!block ambassador\") or not (\"!pass\")?",
        ]
      end

      it 'no longer steals if player does not show captain' do
        @game.flip_card(message_from(@order[1]), '2')
        expect(@chan.messages).to be == [
          "#{@order[1]} turns a AMBASSADOR face up, losing an influence.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[1])).to be == 2
        expect(@game.coins(@order[2])).to be == 2
      end
    end

    it 'takes 0 coins from a player with 0 coins' do
      # 1 uses captain on 3
      @game.do_action(message_from(@order[1]), 'captain', @order[3])

      # 2, 3 pass challenge
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))

      # 3 passes block
      @game.react_pass(message_from(@order[3]))

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 2
      expect(@game.coins(@players[@order[3]])).to be == 0

      # 2 uses captain on 3
      @game.do_action(message_from(@order[2]), 'captain', @order[3])

      # 1, 3 pass challenge
      @game.react_pass(message_from(@order[1]))
      @game.react_pass(message_from(@order[3]))

      # 3 passes block
      @game.react_pass(message_from(@order[3]))

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 2
      expect(@game.coins(@players[@order[3]])).to be == 0
    end

    it 'takes 1 coin from a player with 1 coin' do
      # 1 uses captain on 2
      @game.do_action(message_from(@order[1]), 'captain', @order[2])

      # 2, 3 pass challenge
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))

      # 2 passes block
      @game.react_pass(message_from(@order[2]))

      # 2 uses income
      @game.do_action(message_from(@order[2]), 'income')

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 1
      expect(@game.coins(@players[@order[3]])).to be == 2

      # 3 uses captain on 2
      @game.do_action(message_from(@order[3]), 'captain', @order[2])

      # 1, 2 pass challenge
      @game.react_pass(message_from(@order[1]))
      @game.react_pass(message_from(@order[2]))

      # 2 passes block
      @game.react_pass(message_from(@order[2]))

      expect(@game.coins(@players[@order[1]])).to be == 4
      expect(@game.coins(@players[@order[2]])).to be == 0
      expect(@game.coins(@players[@order[3]])).to be == 3
    end

    it 'steals coins from a player who dies due to a challenge' do
      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end

      # 1 coups 3
      @game.do_action(message_from(@order[1]), 'coup', @order[3])
      @game.flip_card(message_from(@order[3]), '1')

      expect(@game.coins(@players[@order[2]])).to be == 7
      expect(@game.coins(@players[@order[3]])).to be == 7

      @game.force_characters(@order[2], :captain, :captain)
      @game.do_action(message_from(@order[2]), 'captain', @order[3])
      @game.react_challenge(message_from(@order[3]))
      @game.flip_card(message_from(@order[2]), '1')
      @game.flip_card(message_from(@order[3]), '2')

      expect(@game.coins(@players[@order[2]])).to be == 9

      # We don't care what third player's coins are. He's dead.
    end

    # ===== Duke =====

    it 'gives 3 coins if player uses duke unchallenged' do
      @game.do_action(message_from(@order[1]), 'duke')
      expect(@chan.messages).to be == [
        "#{@order[1]} uses DUKE",
        CHALLENGE_PROMPT,
      ].compact
      @chan.messages.clear

      p = @players[@order[1]]
      p.messages.clear

      (2...NUM_PLAYERS).each { |i|
        @game.react_pass(message_from(@order[i]))
        expect(@chan.messages).to be == ["#{@order[i]} passes."]
        @chan.messages.clear
      }
      @game.react_pass(message_from(@order[NUM_PLAYERS]))

      expect(@chan.messages).to be == [
        "#{@order[NUM_PLAYERS]} passes.",
        "#{@order[1]} proceeds with DUKE. Take 3 coins.",
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@players[@order[1]])).to be == 5
    end

    context 'when duke taxes and is challenged' do
      before :each do
        @game.force_characters(@order[1], :duke, :assassin)

        @game.do_action(message_from(@order[1]), 'duke')
        expect(@chan.messages).to be == [
          "#{@order[1]} uses DUKE",
          CHALLENGE_PROMPT,
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          "#{@order[2]} challenges #{@order[1]} on DUKE!",
        ]
        @chan.messages.clear
      end

      it 'continues to tax if player shows duke' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == [
          "#{@order[1]} reveals a [DUKE]. #{@order[2]} loses an influence.",
          "#{@order[1]} switches the character card with one from the deck.",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ /^#{@order[2]} turns a [A-Z]+ face up\.$/
        expect(@chan.messages).to be == [
          "#{@order[1]} proceeds with DUKE. Take 3 coins.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])).to be == 5
      end

      it 'no longer taxes if player does not show duke' do
        @game.flip_card(message_from(@order[1]), '2')
        expect(@chan.messages).to be == [
          "#{@order[1]} turns a ASSASSIN face up, losing an influence.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[1])).to be == 2
      end
    end

    describe 'status' do
      it 'reports waiting on action challenge' do
        @game.do_action(message_from(@order[1]), 'ambassador')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == ["Waiting on players to PASS or CHALLENGE action: #{@order[2]}, #{@order[3]}"]
      end

      it 'reports waiting on action challenge response' do
        @game.do_action(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == ["Waiting on #{@order[1]} to respond to action challenge"]
      end

      it 'reports waiting on action challenge loser' do
        @game.do_action(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @game.force_characters(@order[1], :ambassador, :ambassador)
        @game.flip_card(message_from(@order[1]), '1')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        expect(@chan.messages).to be == ["Waiting on #{@order[2]} to pick character to lose"]
      end

      it 'reports waiting on single block' do
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        @game.react_pass(message_from(@order[2]))
        @game.react_pass(message_from(@order[3]))
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        expect(@chan.messages).to be == ["Waiting on players to PASS or BLOCK action: #{@order[2]}"]
      end

      it 'reports waiting on multi block' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == ["Waiting on players to PASS or BLOCK action: #{@order[2]}, #{@order[3]}"]
      end

      it 'reports waiting on block challenge' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @game.do_block(message_from(@order[2]), 'duke')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == ["Waiting on players to PASS or CHALLENGE block: #{@order[1]}, #{@order[3]}"]
      end

      it 'reports waiting on block challenge response' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @game.do_block(message_from(@order[2]), 'duke')
        @game.react_challenge(message_from(@order[3]))
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == ["Waiting on #{@order[2]} to respond to block challenge"]
      end

      it 'reports waiting on block challenge loser' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @game.do_block(message_from(@order[2]), 'duke')
        @game.react_challenge(message_from(@order[3]))
        @game.force_characters(@order[2], :duke, :duke)
        @game.flip_card(message_from(@order[2]), '1')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == ["Waiting on #{@order[3]} to pick character to lose"]
      end

      it 'reports waiting on ambassador decision' do
        @game.do_action(message_from(@order[1]), 'ambassador')
        @game.react_pass(message_from(@order[2]))
        @game.react_pass(message_from(@order[3]))
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        expect(@chan.messages).to be == ["Waiting on #{@order[1]} to make decision on AMBASSADOR"]
      end

      it 'reports waiting on coup decision' do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end
        @game.do_action(message_from(@order[1]), 'coup', @order[2])
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        expect(@chan.messages).to be == ["Waiting on #{@order[2]} to make decision on COUP"]
      end
    end

    describe 'ending the game' do
      before :each do
        # Have each player take income to bump them up to 7 coins
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # 1 uses coup on 3
        @game.do_action(message_from(@order[1]), 'coup', @order[3])
        # 3 flips card 1
        @game.flip_card(message_from(@order[3]), '1')

        # 2 uses coup on 3
        @game.do_action(message_from(@order[2]), 'coup', @order[3])
        # 3 flips card 2
        @game.flip_card(message_from(@order[3]), '2')

        # Get back up to 7 coins!
        7.times do
          (1..NUM_PLAYERS-1).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # 1 uses coup on 2
        @game.do_action(message_from(@order[1]), 'coup', @order[2])
        # 2 flips card 1
        @game.flip_card(message_from(@order[2]), '1')

        @chan.messages.clear
      end

      it 'ends the game if player with 1 influence gets challenged on an action' do
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'ambassador')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))

        expect(@chan.messages).to be == [
          "#{@order[1]} challenges #{@order[2]} on AMBASSADOR!",
          "#{@order[2]} turns a ASSASSIN face up, losing an influence.",
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ]
      end

      it 'ends the game if player with 1 influence gets challenged on a block' do
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'income')
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        @game.react_pass(message_from(@order[2]))
        @game.do_block(message_from(@order[2]), 'ambassador')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))

        expect(@chan.messages).to be == [
          "#{@order[1]} challenges #{@order[2]} on AMBASSADOR!",
          "#{@order[2]} turns a ASSASSIN face up, losing an influence.",
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ]
      end

      it 'ends the game if player with 1 influence wrongly challenges an action' do
        @game.force_characters(@order[1], :ambassador, :ambassador)
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'income')
        @game.do_action(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @game.flip_card(message_from(@order[1]), '1')
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '2')

        expect(@chan.messages).to be == [
          "#{@order[2]} turns a ASSASSIN face up.",
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ]
      end

      it 'ends the game if player with 1 influence wrongly challenges a block' do
        @game.force_characters(@order[1], :ambassador, :ambassador)
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'captain', @order[1])
        @game.react_pass(message_from(@order[1]))
        @game.do_block(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @game.flip_card(message_from(@order[1]), '1')
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '2')

        expect(@chan.messages).to be == [
          "#{@order[2]} turns a ASSASSIN face up.",
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ]
      end

    end

  end
end
