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
                                :effect             => "Exchange card with Court Deck, or examine opponent's card",
                                :mode_required      => :inquisitor,
                                :needs_target       => true,
                                :self_targettable   => true,
                                :has_decision       => true,
                                :blocks             => :captain),

    :captain     => Action.new( :action             => :captain, 
                                :character_required => :captain,  
                                :name               => "Extort",    
                                :effect             => "Take 2 coins from another player",  
                                :needs_target       => true,
                                :blocks             => :captain,
                                :blockable_by       => [:captain, :ambassador, :inquisitor]),

    :contessa    => Action.new( :action             => :contessa,
                                :character_required => :contessa,  
                                :name               => "Contessa",
                                :blocks             => :assassin)
  }

  attr_accessor :started, :players, :deck, :discard_pile, :turns, :invitation_sent
  attr_accessor :ambassador_cards, :ambassador_options
  attr_reader :channel_name
  attr_accessor :settings
  
  def initialize(channel_name)
    @channel_name = channel_name
    @settings = []
    self.started         = false
    self.players         = []
    self.deck            = self.build_starting_deck
    self.discard_pile    = []
    self.turns           = []
    self.invitation_sent = false
    @ambassador_cards = []
    @ambassador_options = []
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
    end
    removed
  end


  # Invitation handlers

  def mark_invitation_sent
    self.invitation_sent = true
  end

  def reset_invitation
    self.invitation_sent = false
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
    self.started = true
    self.pass_out_characters_and_coins
  
    self.players.shuffle!.rotate!(rand(MAX_PLAYERS)) # shuffle seats
    $player_count = self.player_count

    self.next_turn
  end

  # Build starting deck
  #
  def build_starting_deck
    deck = []
    id = 1
    [:duke, :assassin, :contessa, :captain, :ambassador].each do |char|
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
    self.deck.shuffle!

    # assign loyalties
    self.players.each do |player|
      if self.players.size == 2
        player.receive_characters(self.draw_cards(1))
        player.receive_side_characters(*self.draw_cards(5))
      else
        player.receive_characters(self.draw_cards(2))
      end
      player.give_coins(2)
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
  def shuffle_into_deck(c1, c2)
    self.deck << c1
    self.deck << c2
    self.deck.shuffle!
  end


  # TURNS

  def pay_for_current_turn
    case self.current_turn.action.action
    when :coup
      self.current_player.take_coins 7
    when :assassin
      self.current_player.take_coins 3
    end
  end

  def process_current_turn
    case self.current_turn.action.action
    when :income
      self.current_player.give_coins 1
    when :foreign_aid
      self.current_player.give_coins 2
    when :coup
      self.current_turn.make_decider self.target_player
    when :duke
      self.current_player.give_coins 3
    when :assassin
      self.current_turn.make_decider self.target_player
    when :ambassador
      self.current_turn.make_decider self.current_player
    when :captain
      taken = self.target_player.take_coins 2
      self.current_player.give_coins taken
    end
  end

  def process_counteraction(player, action)
    self.current_turn.reactions = {}
    self.current_turn.counteraction = action
  end

  def not_reacted
    reacted_players = self.current_turn.reactions.keys
    self.reacting_players.reject{ |player| reacted_players.include?(player) }
  end

  def all_reactions_in?
    self.not_reacted.size == 0
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
    action.mode_required.nil? || self.settings.include?(action.mode_required)
  end

  # turns

  def next_turn
    self.current_turn.end_turn unless current_turn.nil?
    self.turns << Turn.new(self.players.rotate!.first)
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


