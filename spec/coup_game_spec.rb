require 'simplecov'
SimpleCov.start { add_filter '/spec/' }
require File.expand_path(File.dirname(__FILE__)) + '/../lib/cinch/plugins/coup_game'

TURN_ORDER_REGEX3 = /^Turn order is: (p[1-3]) (p[1-3]) (p[1-3])$/
TURN_ORDER_REGEX6 = /^Turn order is: (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6]) (p[1-6])$/
CHOICE_REGEX = /^Choose a character to turn face up: 1 - \([A-Z]+\) or 2 - \([A-Z]+\); "!lose 1" or "!lose 2"$/

CHANNAME = '#playcoup'
CHANNAME2 = '#otherchannel'
BOGUS_CHANNEL = '#blahblahblah'

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
  alias :authname :name

  def ==(that)
    return false if that.nil?
    # IS THIS RIGHT?! Does this work in irc?!?!
    if that.is_a?(String)
      @name == that
    elsif that.is_a?(MyUser)
      @name == that.name
    else
      false
    end
  end

  def send(msg)
    msg.split("\n").each { |line| @messages << line }
  end

  def authed?
    true
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
    msg.split("\n").each { |line| @messages << line }
  end

  def voice(_)
    nil
  end
  alias :devoice :voice
  alias :moderated= :voice

  def voiced
    []
  end
end

def use_action(player, action, target = nil, settings = nil)
  targ = target ? " on #{target}" : ''

  # TODO hmm, this is pretty bad
  game = Game.new('blah')
  game.settings = settings if settings

  action = Game::ACTIONS[action].to_s_full(game, player, target)
  return "#{player} would like to use #{action}#{targ}"
end

def use_block(player, blocker, blocked_name, blocked_action)
  blocked_action = Game::ACTIONS[blocked_action]
  return "#{player} would like to use #{blocker.upcase} to block #{dehighlight(blocked_name)}'s #{blocked_action.name}"
end

def blocked_by(actor, action, blocker, block_action)
  blocked_action = Game::ACTIONS[action]
  return "#{actor}'s #{blocked_action.name} was blocked by #{blocker} with #{block_action.upcase}."
end

def proceed_with(actor, action, str)
  action = Game::ACTIONS[action]
  return "#{actor} proceeds with #{action.name}. #{str}"
end

def challenge_on(challenger, challengee, role, extra = nil)
  return "#{challenger} challenges #{challengee} on #{extra && "#{extra} "}having influence over #{role.upcase}!"
end

def challenged_win(player, char, challenger)
  [
    "#{player} reveals a [#{char.to_s.upcase}] and replaces it with a new card from the Court Deck.",
    "#{challenger} loses influence for losing the challenge!",
  ]
end
def challenged_loss(player, expected_char, char)
  ability = Game::ACTIONS[expected_char].name
  [
    "#{player} reveals a [#{char.to_s.upcase}]. That's not a #{expected_char.to_s.upcase}! #{player} loses the challenge!",
    "#{player} loses influence over the [#{char.to_s.upcase}] and cannot use #{ability} this turn.",
  ]
end
def lose_card(player, char = nil)
  if char
    "#{player} loses influence over a [#{char.to_s.upcase}]."
  else
    /#{player} loses influence over a \[[A-Z]+\]\./
  end
end

def winner_regex(playername, char1, char2, hidden1, hidden2)
  c1 = char1.nil? ? '\w+' : char1.to_s.upcase
  c2 = char2.nil? ? '\w+' : char2.to_s.upcase
  c1 = hidden1 ? "\\(#{c1}\\)" : "\\[#{c1}\\]"
  c2 = hidden2 ? "\\(#{c2}\\)" : "\\[#{c2}\\]"
  /^#{playername} was #{c1} #{c2}\.$/
end

def dehighlight(nickname)
  nickname.chars.to_a.join(8203.chr('UTF-8'))
end

def challenge_prompt(players, actor, action, target = nil, blocker = nil, counteraction = nil)
  # DOH, super duplicated code from prompt_challengers in CoupGame
  challenged_sym = counteraction || action
  challengee = blocker || actor
  challenged = Game::ACTIONS[challenged_sym]

  char = challenged.character_forbidden? ? challenged.character_forbidden : challenged.character_required
  haveornot = challenged.character_forbidden? ? 'NOT have' : 'have'
  challengeable = "#{dehighlight(challengee)} claims to #{haveornot} influence over #{char.upcase}"

  if counteraction
    why_char = "Blocking #{dehighlight(actor)}'s #{Game::ACTIONS[action].name}"
  else
    why_char = "Using #{challenged.name}#{target && " on #{dehighlight(target)}"}"
  end

  list = players.join(', ')

  return "All other players (#{list}): #{challengeable} (#{why_char}). Would you like to challenge (\"!challenge\") or not (\"!pass\")?"
end

def block_foreign_aid(blocker_names, aided, blocker_group = "other")
  list = blocker_names.join(', ')
  "All #{blocker_group} players (#{list}): Would you like to block #{dehighlight(aided)}'s Foreign Aid (\"!block duke\") or not (\"!pass\")?"
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
          :mods => ['p1', 'npmod'],
          # Upon init, we try to load the settings file to get the PM users.
          # I'll just load /dev/null, but I'd rather the file read get mocked out...
          :settings => '/dev/null',
        }
      end
    end
    b.loggers.first.level = :warn

    @player_names = ['p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'npc', 'npmod']
    @players = Hash.new { |h, x| raise 'Nonexistent player ' + x }

    @player_names.each { |n|
      @players[n] = MyUser.new(n)
    }

    @chan = MyChannel.new(CHANNAME, @players)
    @chan2 = MyChannel.new(CHANNAME2, @players)

    @game = Cinch::Plugins::CoupGame.new(b)
    allow(@game).to receive('sleep').and_return(nil)
    allow(@game).to receive('Channel') { |x|
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
    allow(@game).to receive('User') { |x|
      if x.is_a?(String)
        @players[x]
      elsif x.is_a?(MyUser)
        x
      else
        raise 'Unrecognized User arg'
      end
    }

  end

  after :each do
    # Kinda hacky, but without this may make too many threads.
    timers = @game.instance_variable_get('@idle_timers')
    timers.each_value(&:stop)
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
      expect(@chan.messages).to be == ['p1: Need at least 2 to start a game.']
    end

    it 'forbids outsiders from joining' do
      spammer = MyUser.new('spammer')
      @game.join(Message.new(spammer, nil), CHANNAME)
      expect(spammer.messages).to be == ["You need to be in #{CHANNAME} to join the game."]
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
      expect(@chan.messages).to be == ['p1: Need at least 2 to start a game.']
    end

    it 'reports that p1 is in game in status' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ['A game is forming. 1 players have joined: p1']
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

    it 'lets p1 start base' do
      @game.start_game(message_from('p1'), 'base')
      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      expect(@chan.messages[-2]).to be =~ TURN_ORDER_REGEX3
      expect(@chan.messages[-1]).to be =~ /^FIRST TURN\. Player: p[1-3]\. Please choose an action\./
    end

    it 'does not let p1 start nonexistent setting' do
      @game.start_game(message_from('p1'), 'asillygame')
      expect(@chan.messages).to be == ['p1: Unrecognized game types: "asillygame"']
    end

    it 'lets p1 start with options' do
      @game.start_game(message_from('p1'), 'reformation')
      expect(@chan.messages.size).to be == 4
      expect(@chan.messages[-4]).to be == 'The game has been changed to Reformation.'
      expect(@chan.messages[-3]).to be == 'The game has started.'
      expect(@chan.messages[-2]).to be =~ TURN_ORDER_REGEX3
      expect(@chan.messages[-1]).to be =~ /^FIRST TURN\. Player: p[1-3]\. Please choose an action\./
    end

    it 'lets mod kick p2 publicly' do
      @game.kick_user(message_from('npmod'), 'p2')
      expect(@chan.messages).to be == ['p2 has left the game (2/6)']
    end

    it 'lets participating mod kick p2 privately' do
      @game.kick_user(pm_from('p1'), 'p2')
      expect(@chan.messages).to be == ['p2 has left the game (2/6)']
    end

    it 'lets non-participating mod kick p2 privately' do
      @game.kick_user(pm_from('npmod'), 'p2')
      expect(@chan.messages).to be == ['p2 has left the game (2/6)']
    end

    context 'when mod replaces p3 with p4' do
      before :each do
        @game.replace_user(pm_from('p1'), 'p3', 'p4')
      end

      it 'no longers lets p3 start the game' do
        @chan.messages.clear
        @game.start_game(message_from('p3'))
        expect(@chan.messages).to be == ['p3: You are not in the game.']
      end

      it 'announces to the channel' do
        expect(@chan.messages).to be == ['p3 has been replaced with p4']
      end
    end
  end

  describe 'settings' do
    it 'reports settings publicly' do
      @game.get_game_settings(message_from('p1'))
      expect(@chan.messages).to be == ['Game settings: Base.']
    end

    it 'allows changing settings publicly' do
      @game.set_game_settings(message_from('p1'), nil, 'inquisitor')
      expect(@chan.messages).to be == ['The game has been changed to Inquisitor.']
    end

    it 'reports settings after they have been changed' do
      @game.set_game_settings(message_from('p1'), nil, 'inquisitor')
      @chan.messages.clear
      @game.get_game_settings(message_from('p1'))
      expect(@chan.messages).to be == ['Game settings: Inquisitor.']
    end

    it 'forbids outsiders from changing settings' do
      spammer = MyUser.new('spammer')
      @game.set_game_settings(Message.new(spammer, nil), CHANNAME, 'inquisitor')
      expect(spammer.messages).to be == ["You need to be in #{CHANNAME} to change the settings."]
    end

    it 'asks for channel if non-player asks for settings privately' do
      p = @players['p1']
      p.messages.clear
      @game.get_game_settings(pm_from('p1'))
      expect(@chan.messages).to be == []
      expect(p.messages).to be == [
        'To see settings via PM you must specify the channel: !settings #channel'
      ]
    end

    it 'asks for channel if non-player changes settings privately' do
      p = @players['p1']
      p.messages.clear
      @game.set_game_settings(pm_from('p1'), nil, 'inquisitor')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == [
        'To change settings via PM you must specify the channel: !settings #channel'
      ]
    end

    it 'reports settings if non-player asks for settings privately specifying channel' do
      p = @players['p1']
      p.messages.clear
      @game.get_game_settings(pm_from('p1'), CHANNAME)
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['Game settings: Base.']
    end

    it 'changes settings if non-player changes settings privately specifying channel' do
      p = @players['p1']
      p.messages.clear
      @game.set_game_settings(pm_from('p1'), CHANNAME, 'inquisitor')
      expect(@chan.messages).to be == ['p1 has changed the game to Inquisitor.']
      expect(p.messages).to be == []
    end

    context 'when player has joined game' do
      before :each do
        @game.join(message_from('p1'))
        @chan.messages.clear
        @players['p1'].messages.clear
      end

      it 'reports settings to player privately without channel argument' do
        p = @players['p1']
        @game.get_game_settings(pm_from('p1'), nil)
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['Game settings: Base.']
      end

      it 'lets a player change settings privately without channel argument' do
        p = @players['p1']
        @game.set_game_settings(pm_from('p1'), nil, 'inquisitor')
        expect(@chan.messages).to be == ['p1 has changed the game to Inquisitor.']
        expect(p.messages).to be == []
      end
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

  shared_examples 'a role that blocks captain' do
    it 'does not let unrelated player block' do
      p = @players[@order[3]]
      p.messages.clear

      @game.do_block(message_from(@order[3]), rolename)
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ["You can only block with #{rolename.upcase} if you are the target."]
    end

    it 'blocks steal if target blocks unchallenged' do
      @game.do_block(message_from(@order[2]), rolename)
      expect(@chan.messages).to be == [
        use_block(@order[2], rolename, @order[1], :captain),
        challenge_prompt([@order[1], @order[3]], @order[1], :captain, @order[2], @order[2], rolesym),
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
        blocked_by(@order[1], :captain, @order[2], rolename),
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@players[@order[1]])).to be == 2
      expect(@game.coins(@players[@order[2]])).to be == 2
    end

    context 'when block is challenged' do
      before :each do
        @game.force_characters(@order[2], rolesym, :duke)

        @game.do_block(message_from(@order[2]), rolename)
        expect(@chan.messages).to be == [
          use_block(@order[2], rolename, @order[1], :captain),
          challenge_prompt([@order[1], @order[3]], @order[1], :captain, @order[2], @order[2], rolesym),
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))
        expect(@chan.messages).to be == [
          challenge_on(@order[1], @order[2], rolename),
        ]
        @chan.messages.clear
      end

      it 'continues to block if player shows role' do
        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages).to be == challenged_win(@order[2], rolesym, @order[1])
        @chan.messages.clear

        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[1])
        expect(@chan.messages).to be == [
          blocked_by(@order[1], :captain, @order[2], rolename),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])).to be == 2
        expect(@game.coins(@order[2])).to be == 2
      end

      it 'no longer blocks if player does not show role' do
        @game.flip_card(message_from(@order[2]), '2')
        expect(@chan.messages).to be == [
          challenged_loss(@order[2], rolesym, :duke),
          proceed_with(@order[1], :captain, "Take 2 coins from another player: #{@order[2]}."),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ].flatten

        expect(@game.coins(@order[1])).to be == 4
        expect(@game.coins(@order[2])).to be == 0
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

    it 'forbids p4 from joining' do
      @game.join(message_from('p4'))
      expect(@chan.messages).to be == ["p4: Game has already started."]
    end

    it 'reports waiting on action in status' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ["Waiting on #{@order[1]} to take an action"]
    end

    # ===== Income =====

    it 'lets player take income without reactions' do
      @game.do_action(message_from(@order[1]), 'income')
      expect(@chan.messages).to be == [
        use_action(@order[1], :income),
        proceed_with(@order[1], :income, 'Take 1 coin.'),
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@order[1])).to be == 3
    end

    # ===== Foreign Aid =====

    context 'when player takes foreign aid' do
      before :each do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        expect(@chan.messages).to be == [
          use_action(@order[1], :foreign_aid),
          block_foreign_aid([@order[2], @order[3]], @order[1]),
        ]
        @chan.messages.clear
      end

      it 'does not let a captain block' do
        @game.do_block(message_from(@order[2]), 'captain')
        expect(@chan.messages).to be == []
        expect(@players[@order[2]].messages[-1]).to be == 'CAPTAIN does not block Foreign Aid.'
      end

      it 'does nothing if player passes himself' do
        @game.react_pass(message_from(@order[1]))
        expect(@chan.messages).to be == []
      end

      it 'only lets each player pass once' do
        @game.react_pass(message_from(@order[2]))
        expect(@chan.messages).to be == ["#{@order[2]} passes."]
        @chan.messages.clear
        @game.react_pass(message_from(@order[2]))
        expect(@chan.messages).to be == []
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
          proceed_with(@order[1], :foreign_aid, 'Take 2 coins.'),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])).to be == 4
      end

      it 'blocks aid if a player blocks with duke unchallenged' do
        @game.do_block(message_from(@order[2]), 'duke')
        expect(@chan.messages).to be == [
          use_block(@order[2], :duke, @order[1], :foreign_aid),
          challenge_prompt([@order[1], @order[3]], @order[1], :foreign_aid, nil, @order[2], :duke),
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
          blocked_by(@order[1], :foreign_aid, @order[2], :duke),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])).to be == 2
      end

      context 'when duke blocks and is challenged' do
        before :each do
          @game.force_characters(@order[2], :duke, :assassin)

          @game.do_block(message_from(@order[2]), 'duke')
          expect(@chan.messages).to be == [
            use_block(@order[2], :duke, @order[1], :foreign_aid),
            challenge_prompt([@order[1], @order[3]], @order[1], :foreign_aid, nil, @order[2], :duke),
          ].compact
          @chan.messages.clear

          @game.react_challenge(message_from(@order[1]))
          expect(@chan.messages).to be == [
            challenge_on(@order[1], @order[2], :duke),
          ]
          @chan.messages.clear
        end

        it 'continues to block if player shows duke' do
          @game.flip_card(message_from(@order[2]), '1')

          expect(@chan.messages).to be == challenged_win(@order[2], :duke, @order[1])
          @chan.messages.clear

          @game.flip_card(message_from(@order[1]), '1')

          expect(@chan.messages.shift).to be =~ lose_card(@order[1])
          expect(@chan.messages).to be == [
            blocked_by(@order[1], :foreign_aid, @order[2], :duke),
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          expect(@game.coins(@order[1])).to be == 2
        end

        it 'no longer blocks if player does not show duke' do
          @game.flip_card(message_from(@order[2]), '2')
          expect(@chan.messages).to be == [
            challenged_loss(@order[2], :duke, :assassin),
            proceed_with(@order[1], :foreign_aid, 'Take 2 coins.'),
            "#{@order[2]}: It is your turn. Please choose an action.",
          ].flatten
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

    it 'forbids self-targeting coup' do
      p = @players[@order[1]]
      p.messages.clear

      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end
      @chan.messages.clear

      @game.do_action(message_from(@order[1]), 'coup', @order[1])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You may not target yourself with COUP.']
    end

    it 'prompts coup for target if player forgets' do
      p = @players[@order[1]]
      p.messages.clear

      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end
      @chan.messages.clear

      @game.do_action(message_from(@order[1]), 'coup')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You must specify a target for COUP: !action coup <playername>']
    end

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
          use_action(@order[1], :coup, @order[2]),
          proceed_with(@order[1], :coup, "Pay 7 coins, choose player to lose influence: #{@order[2]}."),
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
        expect(@chan.messages[-2]).to be =~ lose_card(@order[2])
        expect(@chan.messages[-1]).to be == "#{@order[2]}: It is your turn. Please choose an action."
      end

      it 'does not let target switch instead of flip' do
        # 2 will now... switch?!
        @game.pick_cards(message_from(@order[2]), '1')
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
          use_action(@order[1], :coup, @order[2]),
          proceed_with(@order[1], :coup, "Pay 7 coins, choose player to lose influence: #{@order[2]}."),
        ]

        expect(p.messages.size).to be == 1
        expect(p.messages[-1]).to be =~ CHOICE_REGEX
      end
    end

    context 'when a player with duplicates and 1 influence is falsely challenged' do
      before :each do
        @game.force_characters(@order[2], :duke, :duke)

        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # 1 coups 2 and 2 flips card 1 (a duke)
        @game.do_action(message_from(@order[1]), 'coup', @order[2])
        @game.flip_card(message_from(@order[2]), '1')

        # 2 uses duke, and 1 challenges. 2 should auto-flip card 2.
        @game.do_action(message_from(@order[2]), 'duke')
        @game.react_challenge(message_from(@order[1]))
        @game.flip_card(message_from(@order[1]), '1')
        @chan.messages.clear

        # So if 3 coups 2 now, 2 should die!
        @game.do_action(message_from(@order[3]), 'coup', @order[2])
        expect(@chan.messages.shift(2)).to be == [
          use_action(@order[3], :coup, @order[2]),
          proceed_with(@order[3], :coup, "Pay 7 coins, choose player to lose influence: #{@order[2]}."),
        ]
      end

      it 'knocks out the player' do
        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          "#{@order[2]} has no more influence, and is out of the game.",
          "#{@order[1]}: It is your turn. Please choose an action.",
        ]
      end

      it 'does not let the player flip card 1 again' do
        @chan.messages.clear
        @game.flip_card(message_from(@order[2]), '1')
        expect(@chan.messages).to be == []
      end
    end

    # ===== Ambassador =====

    context 'when player with 2 influence uses ambassador unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'ambassador')
        expect(@chan.messages).to be == [
          use_action(@order[1], :ambassador),
          challenge_prompt([@order[2], @order[3]], @order[1], :ambassador),
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
          proceed_with(@order[1], :ambassador, 'Exchange cards with Court Deck.'),
        ]
        @chan.messages.clear

        expect(p.messages.size).to be == 8

        expect(p.messages[-8]).to be =~ /You drew [A-Z]+ and [A-Z]+ from the Court Deck./
        expect(p.messages[-7]).to be == "Choose an option for a new hand; \"!switch #\""
        choices = Array.new(7)
        (1..6).each { |i|
          index = -7 + i
          match = /^#{i} -\s+\((\w+)\)\s+\((\w+)\)$/.match(p.messages[index])
          expect(match).to_not be_nil
          choices[i] = match
        }
      end

      it 'lets player switch' do
        @game.pick_cards(message_from(@order[1]), '1')
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
          use_action(@order[2], :ambassador),
          challenge_prompt([@order[3], @order[1]], @order[2], :ambassador),
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
          proceed_with(@order[2], :ambassador, 'Exchange cards with Court Deck.'),
        ]
        @chan.messages.clear

        expect(p.messages.size).to be == 5

        expect(p.messages[-5]).to be =~ /You drew [A-Z]+ and [A-Z]+ from the Court Deck./
        expect(p.messages[-4]).to be == "Choose an option for a new hand; \"!switch #\""
        choices = Array.new(3)
        (1..3).each { |i|
          index = -4 + i
          match = /^#{i} -\s+\((\w+)\)$/.match(p.messages[index])
          expect(match).to_not be_nil
          choices[i] = match
        }
      end

      it 'lets player switch' do
        @game.pick_cards(message_from(@order[2]), '1')
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
          use_action(@order[1], :ambassador),
          challenge_prompt([@order[2], @order[3]], @order[1], :ambassador),
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          challenge_on(@order[2], @order[1], :ambassador),
        ]
        @chan.messages.clear
      end

      it 'continues to switch if player shows ambassador' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == challenged_win(@order[1], :ambassador, @order[2])
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          proceed_with(@order[1], :ambassador, 'Exchange cards with Court Deck.'),
        ]
      end

      it 'no longer switches if player does not show ambassador' do
        @game.flip_card(message_from(@order[1]), '2')
        expect(@chan.messages).to be == [
          challenged_loss(@order[1], :ambassador, :duke),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ].flatten
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

    it 'forbids self-targeting assassin' do
      p = @players[@order[1]]
      p.messages.clear

      # Have each player take income to bump them up to 3 coins
      (1..NUM_PLAYERS).each { |i|
        @game.do_action(message_from(@order[i]), 'income')
      }
      @chan.messages.clear

      @game.do_action(message_from(@order[1]), 'assassin', @order[1])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You may not target yourself with ASSASSIN.']
    end

    it 'prompts assassin for target if player forgets' do
      p = @players[@order[1]]
      p.messages.clear

      # Have each player take income to bump them up to 3 coins
      (1..NUM_PLAYERS).each { |i|
        @game.do_action(message_from(@order[i]), 'income')
      }
      @chan.messages.clear

      @game.do_action(message_from(@order[1]), 'assassin')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You must specify a target for ASSASSIN: !action assassin <playername>']
    end

    def block_assassin(victim, assassin)
      "#{victim}: Would you like to block #{dehighlight(assassin)}'s Assassinate (\"!block contessa\") or not (\"!pass\")?"
    end

    context 'when player uses assassin unchallenged' do

      before :each do
        # Have each player take income to bump them up to 3 coins
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
        @chan.messages.clear

        # Now first player uses assassin action
        @game.do_action(message_from(@order[1]), 'assassin', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[1], :assassin, @order[2]),
          challenge_prompt([@order[2], @order[3]], @order[1], :assassin, @order[2]),
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
          block_assassin(@order[2], @order[1]),
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
            proceed_with(@order[1], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[2]}."),
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
          expect(@chan.messages[-2]).to be =~ lose_card(@order[2])
          expect(@chan.messages[-1]).to be == "#{@order[2]}: It is your turn. Please choose an action."
        end

        it 'does not lets target switch' do
          @game.pick_cards(message_from(@order[2]), '1')
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
          use_block(@order[2], :contessa, @order[1], :assassin),
          challenge_prompt([@order[1], @order[3]], @order[1], :assassin, @order[2], @order[2], :contessa),
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
          blocked_by(@order[1], :assassin, @order[2], :contessa),
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
            use_block(@order[2], :contessa, @order[1], :assassin),
            challenge_prompt([@order[1], @order[3]], @order[1], :assassin, @order[2], @order[2], :contessa),
          ].compact
          @chan.messages.clear

          @game.react_challenge(message_from(@order[1]))
          expect(@chan.messages).to be == [
            challenge_on(@order[1], @order[2], :contessa),
          ]
          @chan.messages.clear
        end

        it 'continues to block if player shows contessa' do
          @game.flip_card(message_from(@order[2]), '1')

          expect(@chan.messages).to be == challenged_win(@order[2], :contessa, @order[1])
          @chan.messages.clear

          @game.flip_card(message_from(@order[1]), '1')

          expect(@chan.messages.shift).to be =~ lose_card(@order[1])
          expect(@chan.messages).to be == [
            blocked_by(@order[1], :assassin, @order[2], :contessa),
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]

          # But assassin still pays
          expect(@game.coins(@order[1])).to be == 0
        end

        it 'no longer blocks if player does not show contessa' do
          @game.flip_card(message_from(@order[2]), '2')
          expect(@chan.messages).to be == [
            challenged_loss(@order[2], :contessa, :captain),
            proceed_with(@order[1], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[2]}."),
            lose_card(@order[2], :contessa),
            "#{@order[2]} has no more influence, and is out of the game.",
            "#{@order[3]}: It is your turn. Please choose an action.",
          ].flatten

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
        }
        @chan.messages.clear

        @game.do_action(message_from(@order[1]), 'assassin', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[1], :assassin, @order[2]),
          challenge_prompt([@order[2], @order[3]], @order[1], :assassin, @order[2]),
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          challenge_on(@order[2], @order[1], :assassin),
        ]
        @chan.messages.clear
      end

      it 'continues to kill if player shows assassin' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == challenged_win(@order[1], :assassin, @order[2])
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          block_assassin(@order[2], @order[1]),
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
            challenged_loss(@order[1], :assassin, :contessa),
            "#{@order[2]}: It is your turn. Please choose an action.",
          ].flatten
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
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages).to be == [
          challenged_loss(@order[2], :contessa, :assassin),
          proceed_with(@order[1], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[2]}."),
          lose_card(@order[2], :assassin),
          "#{@order[2]} has no more influence, and is out of the game.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ].flatten
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
          challenge_on(@order[2], @order[3], :contessa),
          challenged_loss(@order[3], :contessa, :assassin),
          "#{@order[3]} has no more influence, and is out of the game.",
          proceed_with(@order[2], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[3]}."),
          "#{@order[1]}: It is your turn. Please choose an action.",
        ].flatten
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
        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          block_assassin(@order[2], @order[1]),
        ]

        @chan.messages.clear

        @game.force_characters(@order[2], :duke, nil)

        # target passes block
        @game.react_pass(message_from(@order[2]))
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages).to be == [
          "#{@order[2]} passes.",
          proceed_with(@order[1], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[2]}."),
          lose_card(@order[2], :duke),
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
        @game.force_characters(@order[3], :duke, :duke)

        # 1st uses coup on 3rd
        @game.do_action(message_from(@order[1]), 'coup', @order[3])
        @game.flip_card(message_from(@order[3]), '1')

        # 2nd uses assassin on 3rd
        @game.do_action(message_from(@order[2]), 'assassin', @order[3])

        # 1st challenges
        @game.react_challenge(message_from(@order[3]))

        @chan.messages.clear

        # assassin wins challenge
        @game.flip_card(message_from(@order[2]), '1')
      end

      it 'moves on to the next turn after flip' do
        expect(@chan.messages).to be == [
          challenged_win(@order[2], :assassin, @order[3]),
          lose_card(@order[3], :duke),
          "#{@order[3]} has no more influence, and is out of the game.",
          proceed_with(@order[2], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[3]}."),
          "#{@order[1]}: It is your turn. Please choose an action.",
        ].flatten
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
      @game.force_characters(@order[2], nil, :duke)
      @game.force_characters(@order[1], nil, :duke)
      @game.do_action(message_from(@order[3]), 'assassin', @order[1])
      @game.react_challenge(message_from(@order[2]))

      @chan.messages.clear

      @game.flip_card(message_from(@order[3]), '1')

      expect(@chan.messages).to be == [
        challenged_win(@order[3], :assassin, @order[2]),
        lose_card(@order[2], :duke),
        "#{@order[2]} has no more influence, and is out of the game.",
        block_assassin(@order[1], @order[3]),
      ].flatten
      @chan.messages.clear

      @game.react_pass(message_from(@order[1]))
      expect(@chan.messages[0...-1]).to be == [
        "#{@order[1]} passes.",
        proceed_with(@order[3], :assassin, "Pay 3 coins, choose player to lose influence: #{@order[1]}."),
        lose_card(@order[1], :duke),
        "#{@order[1]} has no more influence, and is out of the game.",
        "Game is over! #{@order[3]} wins!",
      ]
      expect(@chan.messages[-1]).to be =~ winner_regex(@order[3], nil, :assassin, true, true)
    end

    # ===== Captain =====

    it 'forbids self-targeting captain' do
      p = @players[@order[1]]
      p.messages.clear

      @chan.messages.clear

      @game.do_action(message_from(@order[1]), 'captain', @order[1])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You may not target yourself with CAPTAIN.']
    end

    it 'prompts captain for target if player forgets' do
      p = @players[@order[1]]
      p.messages.clear

      @chan.messages.clear

      @game.do_action(message_from(@order[1]), 'captain')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You must specify a target for CAPTAIN: !action captain <playername>']
    end

    context 'when player uses captain unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[1], :captain, @order[2]),
          challenge_prompt([@order[2], @order[3]], @order[1], :captain, @order[2]),
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
          "#{@order[2]}: Would you like to block #{dehighlight(@order[1])}'s Steal (\"!block captain\" or \"!block ambassador\") or not (\"!pass\")?",
        ]
        @chan.messages.clear
      end

      it 'steals two coins if target does not block' do
        @game.react_pass(message_from(@order[2]))

        expect(@chan.messages).to be == [
          "#{@order[2]} passes.",
          proceed_with(@order[1], :captain, "Take 2 coins from another player: #{@order[2]}."),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])) == 4
        expect(@game.coins(@order[2])) == 0
      end

      context 'when blocking with ambassador' do
        let(:rolename) do 'ambassador' end
        let(:rolesym) do :ambassador end

        it_behaves_like 'a role that blocks captain'
      end

      context 'when blocking with captain' do
        let(:rolename) do 'captain' end
        let(:rolesym) do :captain end

        it_behaves_like 'a role that blocks captain'
      end
    end

    context 'when captain steals and is challenged' do
      before :each do
        @game.force_characters(@order[1], :captain, :ambassador)

        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[1], :captain, @order[2]),
          challenge_prompt([@order[2], @order[3]], @order[1], :captain, @order[2]),
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          challenge_on(@order[2], @order[1], :captain),
        ]
        @chan.messages.clear
      end

      it 'continues to steal if player shows captain' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == challenged_win(@order[1], :captain, @order[2])
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          "#{@order[2]}: Would you like to block #{dehighlight(@order[1])}'s Steal (\"!block captain\" or \"!block ambassador\") or not (\"!pass\")?",
        ]
      end

      it 'no longer steals if player does not show captain' do
        @game.flip_card(message_from(@order[1]), '2')
        expect(@chan.messages).to be == [
          challenged_loss(@order[1], :captain, :ambassador),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ].flatten
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
        use_action(@order[1], :duke),
        challenge_prompt([@order[2], @order[3]], @order[1], :duke),
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
        proceed_with(@order[1], :duke, 'Take 3 coins.'),
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@players[@order[1]])).to be == 5
    end

    context 'when duke taxes and is challenged' do
      before :each do
        @game.force_characters(@order[1], :duke, :assassin)

        @game.do_action(message_from(@order[1]), 'duke')
        expect(@chan.messages).to be == [
          use_action(@order[1], :duke),
          challenge_prompt([@order[2], @order[3]], @order[1], :duke),
        ].compact
        @chan.messages.clear

        @game.react_challenge(message_from(@order[2]))
        expect(@chan.messages).to be == [
          challenge_on(@order[2], @order[1], :duke),
        ]
        @chan.messages.clear
      end

      it 'continues to tax if player shows duke' do
        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages).to be == challenged_win(@order[1], :duke, @order[2])
        @chan.messages.clear

        @game.flip_card(message_from(@order[2]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          proceed_with(@order[1], :duke, 'Take 3 coins.'),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]

        expect(@game.coins(@order[1])).to be == 5
      end

      it 'no longer taxes if player does not show duke' do
        @game.flip_card(message_from(@order[1]), '2')
        expect(@chan.messages).to be == [
          challenged_loss(@order[1], :duke, :assassin),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ].flatten
        expect(@game.coins(@order[1])).to be == 2
      end
    end

    it 'advances the turn to the immediately-next player if the active player gets knocked out' do
      5.times do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
      end

      @game.do_action(message_from(@order[1]), 'coup', @order[2])
      @game.flip_card(message_from(@order[2]), '1')
      @game.force_characters(@order[2], nil, :ambassador)
      @game.do_action(message_from(@order[2]), 'duke')
      @chan.messages.clear

      @game.react_challenge(message_from(@order[1]))

      # It really should be the third player's turn, not the first player's.
      expect(@chan.messages[-1]).to be == "#{@order[3]}: It is your turn. Please choose an action."
    end

    # ===== Reformation =====

    it 'does not allow apostatize action in a base game' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'apostatize', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['APOSTATIZE may only be used if the game type is one of the following: Reformation.']
    end

    it 'does not allow convert action in a base game' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'convert', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['CONVERT may only be used if the game type is one of the following: Reformation.']
    end

    it 'does not allow embezzle action in a base game' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'embezzle', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['EMBEZZLE may only be used if the game type is one of the following: Reformation, Incorporation.']
    end

    it 'does not allow flip all in response to a character-required challenge' do
      @game.do_action(message_from(@order[1]), 'ambassador')
      @game.react_challenge(message_from(@order[2]))

      p = @players[@order[1]]
      p.messages.clear
      @chan.messages.clear

      @game.flip_card(message_from(@order[1]), 'all')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You may only flip all cards in response to a challenge of NOT having influence over a character.']
    end


    # ===== Inquisitor =====

    it 'does not allow inquisitor action in a base game' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'inquisitor', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['INQUISITOR may only be used if the game type is one of the following: Inquisitor.']
    end

    it 'does not allow inquisitor block in a base game' do
      @game.do_action(message_from(@order[1]), 'captain', @order[2])
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))
      @chan.messages.clear

      p = @players[@order[2]]
      p.messages.clear

      @game.do_block(message_from(@order[2]), 'inquisitor')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['INQUISITOR may only be used if the game type is one of the following: Inquisitor.']
    end

    describe 'status' do
      it 'reports waiting on action challenge' do
        @game.do_action(message_from(@order[1]), 'ambassador')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == [
          "Waiting on players to PASS or CHALLENGE #{dehighlight(@order[1])}'s Exchange: #{@order[2]}, #{@order[3]}"
        ]
      end

      it 'reports waiting on action challenge response' do
        @game.do_action(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == [
          "Waiting on #{@order[1]} to respond to challenge against #{dehighlight(@order[1])}'s Exchange"
        ]
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
        expect(@chan.messages).to be == [
          "Waiting on players to PASS or BLOCK #{dehighlight(@order[1])}'s Steal on #{dehighlight(@order[2])}: #{@order[2]}"
        ]
      end

      it 'reports waiting on multi block' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == [
          "Waiting on players to PASS or BLOCK #{dehighlight(@order[1])}'s Foreign Aid: #{@order[2]}, #{@order[3]}"
        ]
      end

      it 'reports waiting on block challenge' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @game.do_block(message_from(@order[2]), 'duke')
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        block = "#{dehighlight(@order[2])}'s DUKE blocking #{dehighlight(@order[1])}'s Foreign Aid"
        expect(@chan.messages).to be == [
          "Waiting on players to PASS or CHALLENGE #{block}: #{@order[1]}, #{@order[3]}"
        ]
      end

      it 'reports waiting on block challenge response' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        @game.do_block(message_from(@order[2]), 'duke')
        @game.react_challenge(message_from(@order[3]))
        @chan.messages.clear
        @game.status(message_from(@order[1]))
        block = "#{dehighlight(@order[2])}'s DUKE blocking #{dehighlight(@order[1])}'s Foreign Aid"
        # Hmm, I'm relying on this to be in turn order, but is that always correct?
        expect(@chan.messages).to be == [
          "Waiting on #{@order[2]} to respond to challenge against #{block}"
        ]
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
        expect(@chan.messages).to be == ["Waiting on #{@order[1]} to make decision on Exchange"]
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
        expect(@chan.messages).to be == ["Waiting on #{@order[2]} to make decision on Coup"]
      end
    end

    # ===== player info =====

    it 'tells players their start characters' do
      expect(@players['p1'].messages.shift).to be == '=' * 40
      expect(@players['p1'].messages.shift).to be =~ /^\(\w+\) \(\w+\) - Coins: 2$/
      expect(@players['p1'].messages).to be == []
    end

    it 'tells players their new character after defending a challenge' do
      @game.force_characters(@order[1], :ambassador, :duke)
      @game.do_action(message_from(@order[1]), 'ambassador')
      @game.react_challenge(message_from(@order[2]))

      p = @players[@order[1]]
      p.messages.clear

      @game.flip_card(message_from(@order[1]), '1')

      expect(p.messages.shift).to be =~ /^\(\w+\) \(DUKE\)$/
      expect(p.messages).to be == []
    end

    describe 'whoami' do
      it 'shows a player' do
        p = @players['p1']
        p.messages.clear
        @game.whoami(message_from('p1'))
        expect(@chan.messages).to be == []
        expect(p.messages.shift).to be =~ /^\(\w+\) \(\w+\) - Coins: 2$/
        expect(p.messages).to be == []
      end

      it 'does nothing to a non-player' do
        p = @players['npc']
        p.messages.clear
        @game.whoami(message_from('npc'))
        expect(@chan.messages).to be == []
        expect(p.messages).to be == []
      end
    end

    shared_examples 'information source' do
      it 'shows table publicly to player' do
        @game.send(method, message_from('p1'))
        expect(@chan.messages).to be == expected_table
      end

      it 'shows table publicly to non-player' do
        @game.send(method, message_from('npc'))
        expect(@chan.messages).to be == expected_table
      end

      it 'shows table privately to player without arguments' do
        p = @players['p1']
        p.messages.clear
        @game.send(method, pm_from('p1'))
        expect(@chan.messages).to be == []
        expect(p.messages).to be == expected_table
      end

      it 'asks for channel if non-player asks for table privately' do
        p = @players['npc']
        p.messages.clear
        @game.send(method, pm_from('npc'))
        expect(@chan.messages).to be == []
        expect(p.messages).to be == [expected_error]
      end

      it 'shows table if non-player asks for table privately and specifies channel' do
        p = @players['npc']
        p.messages.clear
        @game.send(method, pm_from('npc'), CHANNAME)
        expect(@chan.messages).to be == []
        expect(p.messages).to be == expected_table
      end
    end

    describe 'list_players' do
      let(:expected_table) do
        ["#{dehighlight(@order[1])} #{dehighlight(@order[2])} #{dehighlight(@order[3])}"]
      end

      let(:expected_error) do
        'To list players via PM you must specify the channel: !who #channel'
      end

      let(:method) do :list_players end

      it_behaves_like 'information source'
    end

    describe 'show_table' do
      let(:expected_table) do
        [
          "#{dehighlight(@order[1])}: (########) (########) - Coins: 2",
          "#{dehighlight(@order[2])}: (########) (########) - Coins: 2",
          "#{dehighlight(@order[3])}: (########) (########) - Coins: 2",
          'Court Deck: (9 cards)',
        ]
      end

      let(:expected_error) do
        'To see a game via PM you must specify the channel: !table #channel'
      end
      let(:method) do :show_table end

      it_behaves_like 'information source'
    end

    describe 'reset_game' do
      def expected(i)
        /^#{dehighlight(@order[i])}: \(\w+\) \(\w+\) - Coins: 2$/
      end

      # TODO resetting a game not in progress as well?

      it 'does nothing to non-mods' do
        p = @players['p2']
        p.messages.clear
        @game.reset_game(message_from('p2'), nil)
        expect(@chan.messages).to be == []
        expect(p.messages).to be == []
      end

      it 'publicly resets game in progress from participant' do
        @chan.messages.clear
        @game.reset_game(message_from('p1'), CHANNAME)
        (1..3).each { |i|
          expect(@chan.messages.shift).to be =~ expected(i)
        }
        expect(@chan.messages.shift).to be =~ /Court Deck:( \(\w+\)){9}/
        expect(@chan.messages).to be == ['The game has been reset.']
      end

      it 'publicly resets game in progress from non-participant' do
        @chan.messages.clear
        @game.reset_game(message_from('npmod'), nil)
        (1..3).each { |i|
          expect(@chan.messages.shift).to be =~ expected(i)
        }
        expect(@chan.messages.shift).to be =~ /Court Deck:( \(\w+\)){9}/
        expect(@chan.messages).to be == ['The game has been reset.']
      end

      it 'privately resets game in progress from participant' do
        @chan.messages.clear
        @game.reset_game(pm_from('p1'), nil)
        (1..3).each { |i|
          expect(@chan.messages.shift).to be =~ expected(i)
        }
        expect(@chan.messages.shift).to be =~ /Court Deck:( \(\w+\)){9}/
        expect(@chan.messages).to be == ['The game has been reset.']
      end

      it 'asks for channel if non-participant resets privately' do
        p = @players['npmod']
        p.messages.clear

        @chan.messages.clear
        @game.reset_game(pm_from('npmod'), nil)
        expect(p.messages).to be == ['To reset a game via PM you must specify the channel: !reset #channel']
        expect(@chan.messages).to be == []
      end

      it 'privately resets game in progress from non-participant specifying channel' do
        @chan.messages.clear
        @game.reset_game(pm_from('npmod'), CHANNAME)
        (1..3).each { |i|
          expect(@chan.messages.shift).to be =~ expected(i)
        }
        expect(@chan.messages.shift).to be =~ /Court Deck:( \(\w+\)){9}/
        expect(@chan.messages).to be == ['The game has been reset.']
      end
    end

    it 'does not allow kicking from game in progress' do
      p = @players['p1']
      p.messages.clear
      @game.kick_user(pm_from('p1'), 'p2')
      expect(p.messages).to be == ['You can\'t kick someone while a game is in progress.']
      expect(@chan.messages).to be == []
    end

    describe 'who_chars' do
      def expected(i)
        /^#{dehighlight(@order[i])}: \(\w+\) \(\w+\) - Coins: 2$/
      end

      it 'admonishes cheaters' do
        p = @players['p1']
        p.messages.clear
        @game.who_chars(message_from('p1'), nil)
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['Cheater!!!']
      end

      it 'does nothing to non-mods' do
        p = @players['p2']
        p.messages.clear
        @game.who_chars(message_from('p2'), nil)
        expect(@chan.messages).to be == []
        expect(p.messages).to be == []
      end

      it 'shows mods not in the game' do
        p = @players['npmod']
        p.messages.clear
        @game.who_chars(message_from('npmod'), nil)
        expect(@chan.messages).to be == []
        (1..3).each { |i|
          expect(p.messages.shift).to be =~ expected(i)
        }
        expect(p.messages.shift).to be =~ /Court Deck:( \(\w+\)){9}/
        expect(p.messages).to be == []
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

        expect(@chan.messages[0...-1]).to be == [
          challenge_on(@order[1], @order[2], :ambassador),
          challenged_loss(@order[2], :ambassador, :assassin),
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ].flatten
        expect(@chan.messages[-1]).to be =~ winner_regex(@order[1], nil, nil, true, true)
      end

      it 'ends the game if player with 1 influence gets challenged on a block' do
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'income')
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        @game.react_pass(message_from(@order[2]))
        @game.do_block(message_from(@order[2]), 'ambassador')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))

        expect(@chan.messages[0...-1]).to be == [
          challenge_on(@order[1], @order[2], :ambassador),
          challenged_loss(@order[2], :ambassador, :assassin),
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ].flatten
        expect(@chan.messages[-1]).to be =~ winner_regex(@order[1], nil, nil, true, true)
      end

      it 'ends the game if player with 1 influence wrongly challenges an action' do
        @game.force_characters(@order[1], :ambassador, :ambassador)
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'income')
        @game.do_action(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @chan.messages.clear

        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages[0...-1]).to be == [
          challenged_win(@order[1], :ambassador, @order[2]),
          lose_card(@order[2], :assassin),
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ].flatten
        expect(@chan.messages[-1]).to be =~ winner_regex(@order[1], nil, :ambassador, true, true)
      end

      it 'ends the game if player with 1 influence wrongly challenges a block' do
        @game.force_characters(@order[1], :ambassador, :ambassador)
        @game.force_characters(@order[2], nil, :assassin)
        @game.do_action(message_from(@order[2]), 'captain', @order[1])
        @game.react_pass(message_from(@order[1]))
        @game.do_block(message_from(@order[1]), 'ambassador')
        @game.react_challenge(message_from(@order[2]))
        @chan.messages.clear

        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages[0...-1]).to be == [
          challenged_win(@order[1], :ambassador, @order[2]),
          lose_card(@order[2], :assassin),
          "#{@order[2]} has no more influence, and is out of the game.",
          "Game is over! #{@order[1]} wins!",
        ].flatten
        expect(@chan.messages[-1]).to be =~ winner_regex(@order[1], nil, :ambassador, true, true)
      end

      context 'after game ends' do
        before :each do
          # 2 uses coup on 1
          @game.do_action(message_from(@order[2]), 'coup', @order[1])
          # 1 flips card 1
          @game.flip_card(message_from(@order[1]), '1')

          # Get back up to 7 coins!
          7.times do
            (1..NUM_PLAYERS-1).each { |i|
              @game.do_action(message_from(@order[i]), 'income')
            }
          end

          # 1 uses coup on 2, winning the game!!!
          @game.do_action(message_from(@order[1]), 'coup', @order[2])

          @chan.messages.clear
        end

        it 'lets the winner join the next game' do
          @game.join(message_from(@order[1]))
          expect(@chan.messages).to be == ["#{@order[1]} has joined the game (1/6)"]
        end

        it 'lets a non-winner join the next game' do
          @game.join(message_from(@order[2]))
          expect(@chan.messages).to be == ["#{@order[2]} has joined the game (1/6)"]
        end
      end

    end

  end

  TURN_ORDER_REGEX2 = /^Turn order is: (p[1-2]) (p[1-2])$/

  context 'when p1..2 have joined a game' do
    before :each do
      [1, 2].each { |i| @game.join(message_from("p#{i}")) }
      @chan.messages.clear
    end

    it 'lets p1 start base' do
      @game.start_game(message_from('p1'), 'base')
      expect(@chan.messages[0]).to be == 'The game has started.'
    end

    it 'lets p1 start variant' do
      @game.start_game(message_from('p1'), 'twoplayer')
      expect(@chan.messages[0]).to be == 'The game has been changed to Twoplayer.'
      expect(@chan.messages[1]).to be == 'The game has started.'
    end

    it 'does not let p1 start without args' do
      @game.start_game(message_from('p1'))
      expect(@chan.messages).to be == [
        'To start a two-player game you must choose to play with base rules ("!start base") or two-player variant rules ("!start twoplayer").'
      ]
    end
  end

  context 'when p1..2 are playing a two-player normal game' do
    INITIAL_CHARS = /^\((\w+)\) \((\w+)\) - Coins: (1|2)$/

    before :each do
      [1, 2].each { |i| @game.join(message_from("p#{i}")) }
      @chan.messages.clear
      @game.start_game(message_from('p1'), 'base')

      expect(@chan.messages.size).to be == 4
      expect(@chan.messages[-4]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX2.match(@chan.messages[-3]))
      @order = match

      expect(@chan.messages[-2]).to be == 'This is a two-player game. The starting player receives only 1 coin.'
      @chan.messages.clear

      @initial_chars = Array.new(3)

      [1, 2].each { |i|
        p = @players[@order[i]]
        expect(p.messages.size).to be == 2

        match = (INITIAL_CHARS.match(p.messages[-1]))
        expect(match).to_not be_nil
        @initial_chars[i] = match[1]
      }
    end

    it 'gives first player one coin' do
      expect(@game.coins(@order[1])).to be == 1
    end

    it 'gives second player two coins' do
      expect(@game.coins(@order[2])).to be == 2
    end

    it 'reports status' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ["Waiting on #{@order[1]} to take an action"]
    end
  end

  context 'when p1..2 are playing a two-player variant game' do
    INITIAL_CHAR = /^\((\w+)\) - Coins: (1|2)$/
    SIDE_CHARS = /^1 - \((\w+)\) 2 - \((\w+)\) 3 - \((\w+)\) 4 - \((\w+)\) 5 - \((\w+)\)$/

    before :each do
      [1, 2].each { |i| @game.join(message_from("p#{i}")) }
      @chan.messages.clear
      @game.start_game(message_from('p1'), 'twoplayer')

      expect(@chan.messages.size).to be == 4
      expect(@chan.messages[-4]).to be == 'The game has been changed to Twoplayer.'
      expect(@chan.messages[-3]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX2.match(@chan.messages[-2]))
      @order = match
      expect(@chan.messages[-1]).to be == "This is a two-player variant game. The starting player receives only 1 coin. Both players are picking their first character."
      @chan.messages.clear

      @sides = Array.new(3)

      [1, 2].each { |i|
        p = @players[@order[i]]
        expect(p.messages.size).to be == 3

        match = (SIDE_CHARS.match(p.messages[-2]))
        expect(match).to_not be_nil
        @sides[i] = match

        expect(p.messages[-1]).to be ==
          'Choose your first character card with "!pick #". The other four characters will not be used this game, and only you will know what they are.'
      }
    end

    it 'gives first player one coin' do
      expect(@game.coins(@order[1])).to be == 1
    end

    it 'gives second player two coins' do
      expect(@game.coins(@order[2])).to be == 2
    end

    it 'reports status if neither player has picked' do
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ["Waiting on players to pick character: #{@order[1]}, #{@order[2]}"]
    end

    it 'tells a player his second character after he selects' do
      p = @players[@order[1]]
      p.messages.clear
      @game.pick_cards(message_from(@order[1]), '1')
      expect(p.messages.shift).to be =~ /\([A-Z]+\) \(#{@sides[1][1]}\)/
      expect(p.messages).to be == []
    end

    it 'reports status if only first player has picked' do
      @game.pick_cards(message_from(@order[1]), '1')
      expect(@chan.messages).to be == ["#{@order[1]} has selected a character."]
      @chan.messages.clear
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ["Waiting on players to pick character: #{@order[2]}"]
    end

    it 'reports status if only second player has picked' do
      @game.pick_cards(message_from(@order[2]), '1')
      expect(@chan.messages).to be == ["#{@order[2]} has selected a character."]
      @chan.messages.clear
      @game.status(message_from('p1'))
      expect(@chan.messages).to be == ["Waiting on players to pick character: #{@order[1]}"]
    end

    it 'starts the game if first picks and then second picks' do
      @game.pick_cards(message_from(@order[1]), '1')
      @game.pick_cards(message_from(@order[2]), '1')
      expect(@chan.messages).to be == [
        "#{@order[1]} has selected a character.",
        "#{@order[2]} has selected a character.",
        "FIRST TURN. Player: #{@order[1]}. Please choose an action.",
      ]
    end

    it 'starts the game if second picks and then first picks' do
      @game.pick_cards(message_from(@order[2]), '1')
      @game.pick_cards(message_from(@order[1]), '1')
      expect(@chan.messages).to be == [
        "#{@order[2]} has selected a character.",
        "#{@order[1]} has selected a character.",
        "FIRST TURN. Player: #{@order[1]}. Please choose an action.",
      ]
    end

    it 'does not let the first player use income before both players pick' do
      p = @players[@order[1]]
      p.messages.clear
      @game.do_action(message_from(@order[1]), 'income')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['You are not the current player.']
    end

    it 'remembers the cards both players picked' do
      [1, 2].each { |i|
        @game.pick_cards(message_from(@order[i]), '1')

        p = @players[@order[i]]
        p.messages.clear
        @game.whoami(message_from(@order[i]))

        set_aside = [2, 3, 4, 5].collect { |j|
          "\\(#{@sides[i][j]}\\)"
        }.join(' ')

        expect(p.messages.shift).to be =~
          /\([A-Z]+\) \(#{@sides[i][1]}\) - Coins: #{i} - Set aside: #{set_aside}/
        expect(p.messages).to be == []
      }
    end

    it 'does nothing the second time if a player picks twice' do
      @game.pick_cards(message_from(@order[1]), '1')

      p = @players[@order[1]]
      p.messages.clear
      @chan.messages.clear

      @game.pick_cards(message_from(@order[1]), '1')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == []
    end

    it 'shows table publicly to player' do
      @game.show_table(message_from('p1'))
      expect(@chan.messages).to be == [
        "#{dehighlight(@order[1])}: Character not selected - Coins: 1",
        "#{dehighlight(@order[2])}: Character not selected - Coins: 2",
        "Court Deck: (3 cards)",
      ]
    end

    describe 'who_chars' do
      def expected(i)
        set_aside = [1, 2, 3, 4, 5].collect { |j|
          "(#{@sides[i][j]})"
        }.join(' ')
        "#{dehighlight(@order[i])}: Character not selected - Coins: #{i} - Set aside: #{set_aside}"
      end

      it 'shows mods not in the game' do
        p = @players['npmod']
        p.messages.clear
        @game.who_chars(message_from('npmod'), nil)
        expect(@chan.messages).to be == []
        (1..2).each { |i|
          expect(p.messages.shift).to be == expected(i)
        }
        expect(p.messages.shift).to be =~ /Court Deck:( \(\w+\)){3}/
        expect(p.messages).to be == []
      end
    end

  end

  context 'when p1..3 are playing an inquisitor game' do
    before :each do
      (1..NUM_PLAYERS).each { |i| @game.join(message_from("p#{i}")) }
      @game.set_game_settings(message_from('p1'), nil, 'inquisitor')
      @chan.messages.clear
      @game.start_game(message_from('p1'))

      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX3.match(@chan.messages[-2]))
      @order = match
      expect(@chan.messages[-1]).to be == "FIRST TURN. Player: #{@order[1]}. Please choose an action."
      @chan.messages.clear
    end

    it 'does not allow ambassador action' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'ambassador', @order[2])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['AMBASSADOR may not be used if the game type is Inquisitor.']
    end

    it 'does not allow ambassador block' do
      @game.do_action(message_from(@order[1]), 'captain', @order[2])
      @game.react_pass(message_from(@order[2]))
      @game.react_pass(message_from(@order[3]))
      @chan.messages.clear

      p = @players[@order[2]]
      p.messages.clear

      @game.do_block(message_from(@order[2]), 'ambassador')
      expect(@chan.messages).to be == []
      expect(p.messages).to be == ['AMBASSADOR may not be used if the game type is Inquisitor.']
    end

    context 'when player with 2 influence uses self-inquisitor unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'inquisitor', @order[1])
        expect(@chan.messages).to be == [
          use_action(@order[1], :inquisitor, @order[1]),
          challenge_prompt([@order[2], @order[3]], @order[1], :inquisitor, @order[1]),
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
          proceed_with(@order[1], :inquisitor, 'Exchange card with Court Deck.'),
        ]
        @chan.messages.clear

        expect(p.messages.size).to be == 5

        expect(p.messages[-5]).to be =~ /You drew [A-Z]+ from the Court Deck./
        expect(p.messages[-4]).to be == "Choose an option for a new hand; \"!switch #\""
        choices = Array.new(4)
        (1..3).each { |i|
          index = -4 + i
          match = /^#{i} -\s+\((\w+)\)\s+\((\w+)\)$/.match(p.messages[index])
          expect(match).to_not be_nil
          choices[i] = match
        }
      end

      it 'lets player switch' do
        @game.pick_cards(message_from(@order[1]), '1')
        expect(@chan.messages).to be == [
          "#{@order[1]} shuffles a card into the Court Deck.",
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
      end

      it 'does not let player flip card' do
        @game.flip_card(message_from(@order[1]), '1')
        expect(@chan.messages).to be == []
      end
    end

    context 'when player with 1 influence uses self-inquisitor unchallenged' do
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

        @game.do_action(message_from(@order[2]), 'inquisitor', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[2], :inquisitor, @order[2]),
          challenge_prompt([@order[3], @order[1]], @order[2], :inquisitor, @order[2]),
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
          proceed_with(@order[2], :inquisitor, 'Exchange card with Court Deck.'),
        ]
        @chan.messages.clear

        expect(p.messages.size).to be == 4

        expect(p.messages[-4]).to be =~ /You drew [A-Z]+ from the Court Deck./
        expect(p.messages[-3]).to be == "Choose an option for a new hand; \"!switch #\""
        choices = Array.new(3)
        (1..2).each { |i|
          index = -3 + i
          match = /^#{i} -\s+\((\w+)\)$/.match(p.messages[index])
          expect(match).to_not be_nil
          choices[i] = match
        }
      end

      it 'lets player switch' do
        @game.pick_cards(message_from(@order[2]), '1')
        expect(@chan.messages).to be == [
          "#{@order[2]} shuffles a card into the Court Deck.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
      end

      it 'does not let player flip card' do
        @game.flip_card(message_from(@order[2]), '1')
        expect(@chan.messages).to be == []
      end
    end

    context 'when player uses captain unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[1], :captain, @order[2]),
          challenge_prompt([@order[2], @order[3]], @order[1], :captain, @order[2]),
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
          "#{@order[2]}: Would you like to block #{dehighlight(@order[1])}'s Steal (\"!block captain\" or \"!block inquisitor\") or not (\"!pass\")?",
        ]
        @chan.messages.clear
      end

      context 'when blocking with inquisitor' do
        let(:rolename) do 'inquisitor' end
        let(:rolesym) do :inquisitor end

        it_behaves_like 'a role that blocks captain'
      end
    end

    context 'when player with uses offensive inquisitor unchallenged' do
      before :each do
        @game.do_action(message_from(@order[1]), 'inquisitor', @order[2])
        expect(@chan.messages).to be == [
          use_action(@order[1], :inquisitor, @order[2]),
          challenge_prompt([@order[2], @order[3]], @order[1], :inquisitor, @order[2]),
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
          proceed_with(@order[1], :inquisitor, "Examine opponent's card: #{@order[2]}."),
        ]
        @chan.messages.clear

        @players[@order[1]].messages.clear

        inq_regex = /^Choose a character to show to #{@order[1]}: 1 - \(([A-Z]+)\) or 2 - \(([A-Z]+)\); "!show 1" or "!show 2"$/
        match = inq_regex.match(p.messages.shift)
        expect(match).to_not be_nil
        @targets_cards = match
        expect(p.messages).to be == []
      end


      it 'does not lets the inquisitor give the card back before target has passed it' do
        @game.inquisitor_keep(message_from(@order[1]))
        expect(@chan.messages).to be == []
      end

      it 'does not lets the inquisitor discard the card before target has passed it' do
        @game.inquisitor_discard(message_from(@order[1]))
        expect(@chan.messages).to be == []
      end


      context 'after target has passed card to inquisitor' do
        before :each do
          @game.show_to_inquisitor(message_from(@order[2]), '1')
          expect(@chan.messages).to be == [
            "#{@order[2]} passes a card to #{@order[1]}.",
            "#{@order[1]}: Should #{@order[2]} be allowed to keep this card (\"!keep\") or not (\"!discard\")?",
          ]
          @chan.messages.clear
        end

        it 'does nothing if target tries to pass another card' do
          @game.show_to_inquisitor(message_from(@order[2]), '1')
          expect(@chan.messages).to be == []
        end

        it 'shows inquisitor the card' do
          expect(@players[@order[1]].messages.shift).to be =~ /#{@order[2]} shows you a #{@targets_cards[1]}\.$/
        end

        it 'lets the inquisitor give the card back' do
          @game.inquisitor_keep(message_from(@order[1]))
          expect(@chan.messages).to be == [
            "The card is returned to #{@order[2]}.",
            "#{@order[2]}: It is your turn. Please choose an action.",
          ]
        end

        context 'when inquisitor discards card' do
          before :each do
            @players[@order[2]].messages.clear
            @game.inquisitor_discard(message_from(@order[1]))
          end

          it 'announces to the channel' do
            expect(@chan.messages).to be == [
              "#{@order[2]} is forced to discard that card and replace it with another from the Court Deck.",
              "#{@order[2]}: It is your turn. Please choose an action.",
            ]
          end

          it 'tells player his new card' do
            p = @players[@order[2]]
            expect(p.messages.shift).to be =~ /^\(\w+\) \(\w+\)$/
            expect(p.messages).to be == []
          end
        end
      end
    end

    context 'when player with uses offensive inquisitor on 1-influence player' do
      before :each do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # 1 uses coup on 3, 3 flips card 1
        @game.do_action(message_from(@order[1]), 'coup', @order[3])
        @game.flip_card(message_from(@order[3]), '1')
        @chan.messages.clear

        @game.do_action(message_from(@order[2]), 'inquisitor', @order[3])
        expect(@chan.messages).to be == [
          use_action(@order[2], :inquisitor, @order[3]),
          challenge_prompt([@order[3], @order[1]], @order[2], :inquisitor, @order[3]),
        ].compact
        @chan.messages.clear

        p = @players[@order[2]]
        p.messages.clear

      end

      it 'shows inquisitor the card without asking for a choice' do
        # Have everyone pass
        (3..NUM_PLAYERS).each { |i|
          @game.react_pass(message_from(@order[i]))
          expect(@chan.messages).to be == ["#{@order[i]} passes."]
          @chan.messages.clear
        }
        @game.react_pass(message_from(@order[1]))

        expect(@chan.messages).to be == [
          "#{@order[1]} passes.",
          proceed_with(@order[2], :inquisitor, "Examine opponent's card: #{@order[3]}."),
          "#{@order[3]} passes a card to #{@order[2]}.",
          "#{@order[2]}: Should #{@order[3]} be allowed to keep this card (\"!keep\") or not (\"!discard\")?",
        ]
      end
    end

    context 'when offensive inquisitor is challenged unsuccessfully by 1-influence player' do
      before :each do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # 1 uses coup on 2, 2 flips card 1
        @game.do_action(message_from(@order[1]), 'coup', @order[2])
        @game.flip_card(message_from(@order[2]), '1')
        # 2 uses coup on 3, 3 flips card 1
        @game.do_action(message_from(@order[2]), 'coup', @order[3])
        @game.flip_card(message_from(@order[3]), '1')

        # 3 uses inquisitor on 2
        @game.force_characters(@order[3], nil, :inquisitor)
        @game.do_action(message_from(@order[3]), 'inquisitor', @order[2])
        @chan.messages.clear
      end

      it 'proceeds to the next player' do
        @game.react_challenge(message_from(@order[2]))
        # doh, shift length based on challenged_win length.
        shift_length = 1 + challenged_win('a', :b, 'c').size
        expect(@chan.messages.shift(shift_length)).to be == [
          challenge_on(@order[2], @order[3], :inquisitor),
          challenged_win(@order[3], :inquisitor, @order[2]),
        ].flatten
        expect(@chan.messages.shift).to be =~ lose_card(@order[2])
        expect(@chan.messages).to be == [
          "#{@order[2]} has no more influence, and is out of the game.",
          proceed_with(@order[3], :inquisitor, "Examine opponent's card: #{@order[2]}."),
          "#{@order[1]}: It is your turn. Please choose an action.",
        ]
      end
    end

    # TODO: There could be tests of the inquisitor being blocked, but... meh.

  end

  shared_examples 'game with faction-changing actions' do
    # ===== Apostatize =====

    it 'allows the self-convert action' do
      @game.do_action(message_from(@order[1]), convert_self_name)

      expect(@chan.messages).to be == [
        use_action(@order[1], convert_self_name),
        proceed_with(@order[1], convert_self_name, "Pay 1 coin to #{bank_name}, change own faction."),
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@order[1])).to be == 1
    end

    # TODO consider a test of someone using apostatize when they have 0 coin

    # ===== Convert =====

    it 'allows the targeted convert action' do
      @game.do_action(message_from(@order[1]), convert_other_name, @order[2])

      expect(@chan.messages).to be == [
        use_action(@order[1], convert_other_name, @order[2]),
        proceed_with(@order[1], convert_other_name, "Pay 2 coins to #{bank_name}, choose player to change faction: #{@order[2]}."),
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@order[1])).to be == 0
    end

    it 'allows the convert action on a factionmate' do
      @game.do_action(message_from(@order[1]), convert_other_name, @order[3])

      expect(@chan.messages).to be == [
        use_action(@order[1], convert_other_name, @order[3]),
        proceed_with(@order[1], convert_other_name, "Pay 2 coins to #{bank_name}, choose player to change faction: #{@order[3]}."),
        "#{@order[2]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@order[1])).to be == 0
    end


    # TODO consider a test of someone using convert when they have 1 coin

    # ===== Embezzle =====

    it 'allows the embezzle action' do
      # Put some money in the bank first
      @game.do_action(message_from(@order[1]), convert_self_name)
      @chan.messages.clear

      @game.do_action(message_from(@order[2]), 'embezzle')

      expect(@chan.messages).to be == [
        use_action(@order[2], :embezzle, nil, game_modes),
        challenge_prompt([@order[3], @order[1]], @order[2], :embezzle),
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
        proceed_with(@order[2], :embezzle, "Take all coins from the #{bank_name}."),
        "#{@order[3]}: It is your turn. Please choose an action.",
      ]

      expect(@game.coins(@order[2])).to be == 3
    end

    context 'when player using Embezzle is challenged with 2 characters and one is a Duke' do
      before :each do
        # Put some money in the bank first
        @game.do_action(message_from(@order[1]), convert_self_name)
        @game.force_characters(@order[2], :ambassador, :duke)
        @game.do_action(message_from(@order[2]), 'embezzle')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))
        expect(@chan.messages).to be == [challenge_on(@order[1], @order[2], :duke, :NOT)]
        @chan.messages.clear
      end

      it 'gives no money if embezzler flips the other card' do
        @game.flip_card(message_from(@order[2]), '1')
        expect(@chan.messages).to be == [
          "#{@order[2]} reveals a [AMBASSADOR]. #{@order[2]} loses the challenge!",
          "#{@order[2]} loses influence over the [AMBASSADOR] and cannot use Embezzle this turn.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[2])).to be == 2
      end

      it 'gives no money if embezzler flips the Duke' do
        @game.flip_card(message_from(@order[2]), '2')
        expect(@chan.messages).to be == [
          "#{@order[2]} reveals a [DUKE]. #{@order[2]} loses the challenge!",
          "#{@order[2]} loses influence over the [DUKE] and cannot use Embezzle this turn.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[2])).to be == 2
      end

      it 'does not allow embezzler to flip all cards' do
        p = @players[@order[2]]
        p.messages.clear

        @game.flip_card(message_from(@order[2]), 'all')
        expect(@chan.messages).to be == []
        expect(p.messages).to be == ['You cannot flip all cards because you have a DUKE.']
        expect(@game.coins(@order[2])).to be == 2
      end
    end

    context 'when player using Embezzle is challenged with 2 characters and neither is a Duke' do
      before :each do
        # Put some money in the bank first
        @game.do_action(message_from(@order[1]), convert_self_name)
        @game.force_characters(@order[2], :ambassador, :assassin)
        @game.do_action(message_from(@order[2]), 'embezzle')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))
        expect(@chan.messages).to be == [challenge_on(@order[1], @order[2], :duke, :NOT)]
        @chan.messages.clear
      end

      it 'gives no money if embezzler flips any card' do
        @game.flip_card(message_from(@order[2]), '1')
        expect(@chan.messages).to be == [
          "#{@order[2]} reveals a [AMBASSADOR]. #{@order[2]} loses the challenge!",
          "#{@order[2]} loses influence over the [AMBASSADOR] and cannot use Embezzle this turn.",
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[2])).to be == 2
      end

      it 'flips two cards and gives money if embezzler flips all' do
        @game.flip_card(message_from(@order[2]), 'all')
        expect(@chan.messages).to be == [
          "#{@order[2]} reveals [AMBASSADOR] and [ASSASSIN] and replaces both with new cards from the Court Deck.",
          "#{@order[1]} loses influence for losing the challenge!",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[1])
        expect(@chan.messages).to be == [
          proceed_with(@order[2], :embezzle, "Take all coins from the #{bank_name}."),
          "#{@order[3]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[2])).to be == 3
      end
    end

    context 'when player has 1 influence' do
      before :each do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end

        # Put some money in the bank first
        @game.do_action(message_from(@order[1]), convert_self_name)
        @game.do_action(message_from(@order[2]), 'coup', @order[3])
        @game.flip_card(message_from(@order[3]), '1')
      end

      it 'flips 1 card and gives money if a non-Duke uses Embezzle' do
        @game.force_characters(@order[3], nil, :assassin)
        @game.do_action(message_from(@order[3]), 'embezzle')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))
        expect(@chan.messages).to be == [
          challenge_on(@order[1], @order[3], :duke, :NOT),
          "#{@order[3]} reveals a [ASSASSIN] and replaces it with a new card from the Court Deck.",
          "#{@order[1]} loses influence for losing the challenge!",
        ]
        @chan.messages.clear

        @game.flip_card(message_from(@order[1]), '1')

        expect(@chan.messages.shift).to be =~ lose_card(@order[1])
        expect(@chan.messages).to be == [
          proceed_with(@order[3], :embezzle, "Take all coins from the #{bank_name}."),
          "#{@order[1]}: It is your turn. Please choose an action.",
        ]
        expect(@game.coins(@order[3])).to be == 8
      end

      it 'knocks out the player if a Duke uses Embezzle' do
        @game.force_characters(@order[3], nil, :duke)
        @game.do_action(message_from(@order[3]), 'embezzle')
        @chan.messages.clear

        @game.react_challenge(message_from(@order[1]))
        expect(@chan.messages).to be == [
          challenge_on(@order[1], @order[3], :duke, :NOT),
          "#{@order[3]} reveals a [DUKE]. #{@order[3]} loses the challenge!",
          "#{@order[3]} loses influence over the [DUKE] and cannot use Embezzle this turn.",
          "#{@order[3]} has no more influence, and is out of the game.",
          "#{@order[1]}: It is your turn. Please choose an action.",
        ]
      end
    end
  end

  shared_examples 'game with factional targetting rules' do
    shared_examples "first player can target second" do
      it 'allows targeting opponent with captain' do
        @game.do_action(message_from(@order[1]), 'captain', @order[2])
        expect(@chan.messages[0]).to be == use_action(@order[1], :captain, @order[2])
      end

      it 'allows targeting opponent with assassin' do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
        @chan.messages.clear

        @game.do_action(message_from(@order[1]), 'assassin', @order[2])
        expect(@chan.messages[0]).to be == use_action(@order[1], :assassin, @order[2])
      end

      it 'allows targeting opponent with coup' do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end
        @chan.messages.clear

        @game.do_action(message_from(@order[1]), 'coup', @order[2])
        expect(@chan.messages[0]).to be == use_action(@order[1], :coup, @order[2])
      end
    end

    context 'when there are multiple factions' do
      it_behaves_like "first player can target second"

      it 'does not allow targeting factionmate with captain' do
        p = @players[@order[1]]
        p.messages.clear

        @game.do_action(message_from(@order[1]), 'captain', @order[3])
        expect(@chan.messages).to be == []
        expect(p.messages).to be == [
          "You cannot target a fellow #{factions[0]} with CAPTAIN while the #{factions[1]} exist!"
        ]
      end

      it 'does not allow targeting factionmate with assassin' do
        (1..NUM_PLAYERS).each { |i|
          @game.do_action(message_from(@order[i]), 'income')
        }
        @chan.messages.clear

        p = @players[@order[1]]
        p.messages.clear

        @game.do_action(message_from(@order[1]), 'assassin', @order[3])
        expect(@chan.messages).to be == []
        expect(p.messages).to be == [
          "You cannot target a fellow #{factions[0]} with ASSASSIN while the #{factions[1]} exist!"
        ]
      end

      it 'does not allow targeting factionmate with coup' do
        5.times do
          (1..NUM_PLAYERS).each { |i|
            @game.do_action(message_from(@order[i]), 'income')
          }
        end
        @chan.messages.clear

        p = @players[@order[1]]
        p.messages.clear

        @game.do_action(message_from(@order[1]), 'coup', @order[3])
        expect(@chan.messages).to be == []
        expect(p.messages).to be == [
          "You cannot target a fellow #{factions[0]} with COUP while the #{factions[1]} exist!"
        ]
      end

      context 'when factionmate uses foreign aid' do
        before :each do
          @game.do_action(message_from(@order[1]), 'foreign_aid')
          expect(@chan.messages).to be == [
            use_action(@order[1], :foreign_aid),
            block_foreign_aid([@order[2]], @order[1], factions[1]),
          ]
          @chan.messages.clear
        end

        it 'alerts the player if he tries to block his factionmate' do
          p = @players[@order[3]]
          p.messages.clear

          @game.do_block(message_from(@order[3]), 'duke')
          expect(@chan.messages).to be == []
          expect(p.messages).to be == [
            "You cannot block a fellow #{factions[0]}'s Foreign Aid while the #{factions[1]} exist!"
          ]
        end

        it 'does nothing if player passes on block' do
          @game.react_pass(message_from(@order[3]))
          expect(@chan.messages).to be == []
        end
      end

      it 'allows blocking opponents foreign aid' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        expect(@chan.messages).to be == [
          use_action(@order[1], :foreign_aid),
          block_foreign_aid([@order[2]], @order[1], factions[1]),
        ]
        @chan.messages.clear

        @game.do_block(message_from(@order[2]), 'duke')
        expect(@chan.messages[0]).to be == use_block(@order[2], :duke, @order[1], :foreign_aid)
      end

      it 'proceeds when all opponents have passed blocking foreign aid' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        expect(@chan.messages).to be == [
          use_action(@order[1], :foreign_aid),
          block_foreign_aid([@order[2]], @order[1], factions[1]),
        ]
        @chan.messages.clear

        @game.react_pass(message_from(@order[2]))
        expect(@chan.messages).to be == [
          "#{@order[2]} passes.",
          proceed_with(@order[1], :foreign_aid, 'Take 2 coins.'),
          "#{@order[2]}: It is your turn. Please choose an action.",
        ]
      end

    end

    context 'when there is only one faction' do
      before :each do
        @game.do_action(message_from(@order[1]), 'income')
        @game.do_action(message_from(@order[2]), convert_self_name)
        @game.do_action(message_from(@order[3]), 'income')
        @chan.messages.clear
      end

      it_behaves_like "first player can target second"

      it 'allows blocking opponents foreign aid' do
        @game.do_action(message_from(@order[1]), 'foreign_aid')
        expect(@chan.messages).to be == [
          use_action(@order[1], :foreign_aid),
          block_foreign_aid([@order[2], @order[3]], @order[1]),
        ]
        @chan.messages.clear

        @game.do_block(message_from(@order[2]), 'duke')
        expect(@chan.messages[0]).to be == use_block(@order[2], :duke, @order[1], :foreign_aid)
      end
    end
  end

  shared_examples 'game with factional info' do
    it 'tells players their start characters and alignment' do
      p = @players[@order[1]]
      expect(p.messages.shift).to be == '=' * 40
      expect(p.messages.shift).to be =~ /^\(\w+\) \(\w+\) - Coins: 2 - #{factions[0]}$/
      expect(p.messages).to be == []
      p = @players[@order[2]]
      expect(p.messages.shift).to be == '=' * 40
      expect(p.messages.shift).to be =~ /^\(\w+\) \(\w+\) - Coins: 2 - #{factions[1]}$/
      expect(p.messages).to be == []
    end

    it 'reminds a player of his own faction' do
      p = @players[@order[1]]
      p.messages.clear
      @game.whoami(message_from(@order[1]))
      expect(@chan.messages).to be == []
      expect(p.messages.shift).to be =~ /^\(\w+\) \(\w+\) - Coins: 2 - #{factions[0]}$/
      expect(p.messages).to be == []
    end

    it 'shows table publicly to player' do
      @game.show_table(message_from('p1'))
      expect(@chan.messages).to be == [
        "#{dehighlight(@order[1])}: (########) (########) - Coins: 2 - #{factions[0]}",
        "#{dehighlight(@order[2])}: (########) (########) - Coins: 2 - #{factions[1]}",
        "#{dehighlight(@order[3])}: (########) (########) - Coins: 2 - #{factions[0]}",
        'Court Deck: (9 cards)',
        "#{bank_name}: 0 coins",
      ]
    end

    describe 'who_chars' do
      def expected(i)
        /^#{dehighlight(@order[i])}: \(\w+\) \(\w+\) - Coins: 2 - #{factions[(i + 1) % 2]}$/
      end

      it 'shows mods not in the game' do
        p = @players['npmod']
        p.messages.clear
        @game.who_chars(message_from('npmod'), nil)
        expect(@chan.messages).to be == []
        (1..3).each { |i|
          expect(p.messages.shift).to be =~ expected(i)
        }
        expect(p.messages.shift).to be =~ /Court Deck:( \(\w+\)){9}/
        expect(p.messages).to be == ["#{bank_name}: 0 coins"]
      end
    end
  end

  context 'when p1..3 are playing a reformation game' do
    before :each do
      (1..NUM_PLAYERS).each { |i| @game.join(message_from("p#{i}")) }
      @game.set_game_settings(message_from('p1'), nil, 'reformation')
      @chan.messages.clear
      @game.start_game(message_from('p1'))

      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX3.match(@chan.messages[-2]))
      @order = match
      expect(@chan.messages[-1]).to be == "FIRST TURN. Player: #{@order[1]}. Please choose an action."
      @chan.messages.clear
    end

    let(:convert_self_name) do :apostatize end
    let(:convert_other_name) do :convert end
    let(:bank_name) do 'Almshouse' end
    let(:factions) do ['Protestant', 'Catholic'] end
    let(:game_modes) do [:reformation] end

    it_behaves_like 'game with faction-changing actions'
    it_behaves_like 'game with factional targetting rules'
    it_behaves_like 'game with factional info'
  end

  context 'when p1..3 are playing an incorporation game' do
    before :each do
      (1..NUM_PLAYERS).each { |i| @game.join(message_from("p#{i}")) }
      @game.set_game_settings(message_from('p1'), nil, 'incorporation')
      @chan.messages.clear
      @game.start_game(message_from('p1'))

      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX3.match(@chan.messages[-2]))
      @order = match
      expect(@chan.messages[-1]).to be == "FIRST TURN. Player: #{@order[1]}. Please choose an action."
      @chan.messages.clear
    end

    let(:convert_self_name) do :defect end
    let(:convert_other_name) do :bribe end
    let(:bank_name) do 'Corporate Bank' end
    let(:factions) do ['Resistance', 'Imperial'] end
    let(:game_modes) do [:incorporation] end

    it_behaves_like 'game with faction-changing actions'
    it_behaves_like 'game with factional targetting rules'
    it_behaves_like 'game with factional info'
  end

  context 'when p1..3 are playing a reformation inquisitor game' do
    before :each do
      (1..NUM_PLAYERS).each { |i| @game.join(message_from("p#{i}")) }
      @game.set_game_settings(message_from('p1'), nil, 'reformation inquisitor')
      @chan.messages.clear
      @game.start_game(message_from('p1'))

      expect(@chan.messages.size).to be == 3
      expect(@chan.messages[-3]).to be == 'The game has started.'
      match = (TURN_ORDER_REGEX3.match(@chan.messages[-2]))
      @order = match
      expect(@chan.messages[-1]).to be == "FIRST TURN. Player: #{@order[1]}. Please choose an action."
      @chan.messages.clear
    end

    let(:convert_self_name) do :apostatize end
    let(:convert_other_name) do :convert end
    let(:bank_name) do 'Almshouse' end
    let(:factions) do ['Protestant', 'Catholic'] end
    let(:game_modes) do [:reformation] end

    it_behaves_like 'game with faction-changing actions'
    it_behaves_like 'game with factional targetting rules'
    it_behaves_like 'game with factional info'

    it 'allows targeting opponent with inquisitor' do
      @game.do_action(message_from(@order[1]), 'inquisitor', @order[2])
      expect(@chan.messages[0]).to be == use_action(@order[1], :inquisitor, @order[2])
    end

    it 'does not allow targeting factionmate with inquisitor' do
      p = @players[@order[1]]
      p.messages.clear

      @game.do_action(message_from(@order[1]), 'inquisitor', @order[3])
      expect(@chan.messages).to be == []
      expect(p.messages).to be == [
        "You cannot target a fellow #{factions[0]} with INQUISITOR while the #{factions[1]} exist!"
      ]
    end

    it 'allows targeting self with inquisitor' do
      @game.do_action(message_from(@order[1]), 'inquisitor', @order[1])
      expect(@chan.messages[0]).to be == use_action(@order[1], :inquisitor, @order[1])
    end
  end

end
