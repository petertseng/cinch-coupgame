require 'json'



#================================================================================
# GAME
#================================================================================

$player_count = 0

class Game


  MIN_PLAYERS = 2
  MAX_PLAYERS = 6
  COINS = 50

  ACTIONS = {
    :income      => Action.new( :action       => :income,
                                :name         => "Income",      
                                :effect       => "Take 1 coin"),
 
    :foreign_aid => Action.new( :action       => :foreign_aid,
                                :name         => "Foreign Aid", 
                                :effect       => "Take 2 coins",
                                :blockable_by => [:duke] ),
 
    :coup        => Action.new( :action       => :coup,
                                :name         => "Coup",
                                :effect       => "Pay 7 coins, choose player to lose influence",  
                                :has_decision => true,
                                :needs_target => true,
                                :cost         => 7 ),

    :embezzle    => Action.new( :action              => :embezzle,
                                :character_forbidden => :duke,
                                :name                => "Embezzle",
                                :effect_f            => lambda { |game|
                                  bank = game.settings.include?(:reformation) ? 'Almshouse' : 'Corporate Bank'
                                  "Take all coins from the #{bank}"
                                },
                                :mode_required       => [:reformation, :incorporation]),

    :apostatize  => Action.new( :action              => :apostatize,
                                :name                => "Apostatize",
                                :cost                => 1,
                                :effect              => "Pay 1 coin to Almshouse, change own faction",
                                :mode_required       => [:reformation]),

    :convert     => Action.new( :action              => :convert,
                                :name                => "Convert",
                                :cost                => 2,
                                :needs_target        => true,
                                :can_target_friends  => true,
                                :effect              => "Pay 2 coins to Almshouse, choose player to change faction",
                                :mode_required       => [:reformation]),

    :defect      => Action.new( :action              => :defect,
                                :name                => "Defect",
                                :cost                => 1,
                                :effect              => "Pay 1 coin to Corporate Bank, change own faction",
                                :mode_required       => [:incorporation]),

    :bribe       => Action.new( :action              => :bribe,
                                :name                => "Bribe",
                                :cost                => 2,
                                :needs_target        => true,
                                :can_target_friends  => true,
                                :effect              => "Pay 2 coins to Corporate Bank, choose player to change faction",
                                :mode_required       => [:incorporation]),

    :duke        => Action.new( :action             => :duke,      
                                :character_required => :duke, 
                                :name               => "Tax",
                                :effect             => "Take 3 coins",
                                :blocks             => :foreign_aid),

    :assassin    => Action.new( :action             => :assassin, 
                                :character_required => :assassin,  
                                :name               => "Assassinate", 
                                :effect             => "Pay 3 coins, choose player to lose influence",  
                                :has_decision       => true,
                                :needs_target       => true,
                                :cost               => 3,
                                :blockable_by       => [:contessa]),

    :ambassador  => Action.new( :action             => :ambassador,  
                                :character_required => :ambassador,
                                :name               => "Exchange",
                                :effect             => "Exchange cards with Court Deck",
                                :mode_forbidden     => :inquisitor,
                                :has_decision       => true,
                                :blocks             => :captain),

    :inquisitor  => Action.new( :action             => :inquisitor,
                                :character_required => :inquisitor,
                                :name               => "Exchange",
                                :effect             => "Examine opponent's card",
                                :mode_required      => [:inquisitor],
                                :needs_target       => true,
                                :self_targettable   => true,
                                :self_effect        => "Exchange card with Court Deck",
                                :has_decision       => true,
                                :blocks             => :captain),

    :captain     => Action.new( :action             => :captain, 
                                :character_required => :captain,  
                                :name               => "Steal",
                                :effect             => "Take 2 coins from another player",  
                                :needs_target       => true,
                                :blocks             => :captain,
                                :blockable_by       => [:captain, :ambassador, :inquisitor]),

    :contessa    => Action.new( :action             => :contessa,
                                :character_required => :contessa,  
                                :name               => "Contessa",
                                :blocks             => :assassin)
  }

  attr_reader :started, :players, :deck, :discard_pile, :turns, :invitation_sent
  attr_accessor :ambassador_cards, :ambassador_options
  attr_accessor :inquisitor_shown_card
  attr_reader :channel_name
  attr_accessor :settings
  attr_reader :bank
  
  def initialize(channel_name)
    @channel_name = channel_name
    @settings = []
    @started         = false
    @players         = []
    @discard_pile    = []
    @turns           = []
    @invitation_sent = false
    @ambassador_cards = []
    @ambassador_options = []
    @inquisitor_shown_card = nil
    @bank = 0

    @active_player_killed = false
  end

  #----------------------------------------------
  # Game Status
  #----------------------------------------------

  def started?
    self.started == true
  end

  def not_started?
    self.started == false 
  end

  def accepting_players?
    self.not_started? && ! self.at_max_players?
  end


  #----------------------------------------------
  # Game Setup
  #----------------------------------------------

  # Player handlers

  def at_max_players?
    self.player_count == MAX_PLAYERS
  end

  def at_min_players?
    self.player_count >= MIN_PLAYERS
  end

  def add_player(user)
    added = nil
    unless self.has_player?(user)
      new_player = Player.new(user)
      self.players << new_player
      added = new_player
    end
    added
  end

  def has_player?(user)
    found = self.find_player(user)
    found.nil? ? false : true
  end

  def remove_player(user)
    removed = nil
    player = self.find_player(user)
    unless player.nil?
      self.players.delete(player)
      removed = player
      @active_player_killed = current_turn && current_turn.active_player == player
    end
    removed
  end


  # Invitation handlers

  def mark_invitation_sent
    @invitation_sent = true
  end

  def reset_invitation
    @invitation_sent = false
  end

  def invitation_sent?
    self.invitation_sent == true
  end

  #----------------------------------------------
  # Game 
  #----------------------------------------------

  # Starts up the game
  #
  def start_game!
    @started = true
    @deck = build_starting_deck

    self.players.shuffle!.rotate!(rand(MAX_PLAYERS)) # shuffle seats
    $player_count = self.player_count

    self.next_turn

    # Do this after #next_turn since next_turn rotates the players!
    if self.has_factions?
      faction = 0
      self.players.each { |p|
        p.faction = faction
        faction = 1 - faction
      }
    end

    self.pass_out_characters_and_coins
  end

  # Build starting deck
  #
  def build_starting_deck
    deck = []
    id = 1
    last_char = @settings.include?(:inquisitor) ? :inquisitor : :ambassador
    [:duke, :assassin, :contessa, :captain, last_char].each do |char|
      3.times.each do 
        deck << Character.new(id, char)
        id += 1
      end
    end
    deck
  end

  # Shuffle the deck, pass out characters and coins
  #
  def pass_out_characters_and_coins
    if self.players.size == 2 && @settings.include?(:twoplayer)
      side_decks = [[], []]
      # Uh this is kinda wonky.
      # Oh Well YOLT (You only live twice) in Coup.
      5.times {
        side_decks[0] << self.draw_cards(1)[0]
        side_decks[1] << self.draw_cards(1)[0]
        self.deck.rotate!
      }
    end

    self.deck.shuffle!

    # assign loyalties
    self.players.each_with_index do |player, index|
      if self.players.size == 2
        if @settings.include?(:twoplayer)
          player.receive_characters(self.draw_cards(1))
          player.receive_side_characters(*side_decks[index].shuffle)
        else
          player.receive_characters(self.draw_cards(2))
        end
        # first player gets 1 coin and second gets 2.
        player.give_coins(index + 1)
      else
        player.receive_characters(self.draw_cards(2))
        player.give_coins(2)
      end
    end
  end

  # Draw # of cards from the deck
  #
  def draw_cards(count)
    self.deck.shift(count)
  end

  # Move a player's characters to discard pile
  #
  def discard_characters_for(player)
    player.characters.each do |c|
      self.discard_pile << c
    end
  end

  # Removes character from player, switches with new from deck
  #
  def replace_character_with_new(player, character)
    position = player.character_position(character)
    old_character = player.characters[position]

    raise "Replaced #{player}'s face-up #{character}" unless old_character.face_down?

    self.deck << old_character
    self.deck.shuffle!
    player.characters[position] = self.deck.shift
  end

  # Shuffles these two cards into the deck
  def shuffle_into_deck(c1, c2 = nil)
    self.deck << c1
    self.deck << c2 if c2
    self.deck.shuffle!
  end


  # TURNS

  def pay_for_current_turn
    case self.current_turn.action.action
    when :coup
      self.current_player.take_coins 7
    when :assassin
      self.current_player.take_coins 3
    when :apostatize, :defect
      self.current_player.take_coins 1
      @bank += 1
    when :convert, :bribe
      self.current_player.take_coins 2
      @bank += 2
    end
  end

  def process_current_turn
    case self.current_turn.action.action
    when :income
      self.current_player.give_coins 1
    when :foreign_aid
      self.current_player.give_coins 2
    when :coup
      self.current_turn.make_decider(self.target_player, :lose_influence)
    when :duke
      self.current_player.give_coins 3
    when :assassin
      self.current_turn.make_decider(self.target_player, :lose_influence)
    when :ambassador
      self.current_turn.make_decider(self.current_player, :switch_cards)
    when :inquisitor
      decision_type = self.target_player == self.current_player ? :switch_cards : :show_to_inquisitor
      self.current_turn.make_decider(self.target_player, decision_type)
    when :captain
      taken = self.target_player.take_coins 2
      self.current_player.give_coins taken
    when :embezzle
      self.current_player.give_coins @bank
      @bank = 0
    when :apostatize, :defect
      self.current_player.change_faction
    when :convert, :bribe
      self.target_player.change_faction
    end
  end

  def not_reacted
    reacted_players = self.current_turn.reacted_players
    self.reacting_players.reject{ |player| reacted_players.include?(player) }
  end

  def all_reactions_in?
    self.not_reacted.size == 0
  end

  def all_enemy_reactions_in?
    # If there are no enemies, just return all_reactions_in?
    return self.all_reactions_in? if self.players.all? { |p| p.faction == self.current_player.faction }

    reacted_players = self.current_turn.reacted_players
    pending = self.reacting_players.reject { |player|
      # Reject if they have react, or if their faction is the same (they can't react)
      reacted_players.include?(player) || player.faction == self.current_player.faction
    }
    pending.size == 0
  end

  def not_selected_initial_character
    self.players.select { |p| p.characters.size < 2 }
  end

  def all_characters_selected?
    self.players.all? { |p| p.characters.size == 2 }
  end

  def action_usable?(action)
    # Forbidden mode? Well then definitely false.
    return false if action.mode_forbidden && self.settings.include?(action.mode_forbidden)
    # Usable if action does not require a mode, or the settings include the required mode.
    action.mode_required.nil? || action.mode_required.any? { |mr| self.settings.include?(mr) }
  end

  def has_factions?
    @settings.include?(:reformation) || @settings.include?(:incorporation)
  end

  def bank_name
    if @settings.include?(:reformation)
      'Almshouse'
    elsif @settings.include?(:incorporation)
      'Corporate Bank'
    else
      raise "Game settings #{@settings} does not have bank"
    end
  end

  def factions
    if @settings.include?(:reformation)
      ['Protestant', 'Catholic']
    elsif @settings.include?(:incorporation)
      ['Resistance', 'Imperial']
    else
      raise "Game settings #{@settings} does not have factions"
    end
  end

  def is_enemy?(player, target)
    return true unless self.has_factions?
    # self-targetting is OK (Inquisitor)
    # It's not this code's responsibility to check whether action can self-target
    return true if player == target

    enemies = self.players.select { |p| p.faction != player.faction }

    # I can target them if the enemy faction is vanquished, or they are an ENEMY
    return enemies.empty? || target.faction != player.faction
  end

  # turns

  def next_turn
    self.current_turn.end_turn unless current_turn.nil?

    # If the active player was killed, do not rotate.
    # Rotating would skip the player after him!
    self.players.rotate! unless @active_player_killed
    @active_player_killed = false

    self.turns << Turn.new(self.players.first)
  end

  def current_turn
    self.turns.last 
  end

  # players

  def current_player
    self.current_turn.active_player
  end

  def target_player
    self.current_turn.target_player
  end

  def counteracting_player
    self.current_turn.counteracting_player
  end

  def reacting_players
    self.current_turn.counteraction.nil? ? (self.players - [self.current_player]) : (self.players - [self.counteracting_player])
  end


  # GAME STATE

  def is_over?
    self.players.one? {|p| p.has_influence? }
  end

  def winner
    self.players.find {|p| p.has_influence? }
  end

  #----------------------------------------------
  # Helpers 
  #----------------------------------------------

  def player_count
    self.players.count
  end

  def find_player(user)
    self.players.find{ |p| p.user == user }
  end

end


