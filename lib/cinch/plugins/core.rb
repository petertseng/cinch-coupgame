require 'json'

#================================================================================
# ACTION
#================================================================================

class Action

  attr_accessor :action, :name, :character_required, :effect, :needs_target, :has_decision, :cost, :blocks, :blockable_by

  def initialize(options)
    self.action              = options[:action]
    self.name                = options[:name] 
    self.character_required  = options[:character_required] || nil          
    self.effect              = options[:effect] || ""
    self.needs_target        = options[:needs_target] || false
    self.has_decision        = options[:has_decision] || false
    self.cost                = options[:cost] || 0
    self.blocks              = options[:blocks] || nil
    self.blockable_by        = options[:blockable_by] || []
  end 

  # State methods

  def needs_reactions?
    !self.blockable_by.empty? || self.character_required?
  end

  def needs_decision?
    self.has_decision
  end

  def character_required?
    !self.character_required.nil?
  end

  def to_s
    self.action.to_s
  end

end


#================================================================================
# GAME
#================================================================================

$player_count = 0

class Game


  MIN_PLAYERS = 3
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
                                :has_decision       => true,
                                :blocks             => :captain),

    :captain     => Action.new( :action             => :captain, 
                                :character_required => :captain,  
                                :name               => "Extort",    
                                :effect             => "Take 2 coins from another player",  
                                :needs_target       => true,
                                :blocks             => :captain,
                                :blockable_by       => [:captain, :ambassador]),

    :contessa    => Action.new( :action             => :contessa,
                                :character_required => :contessa,  
                                :name               => "Contessa",
                                :blocks             => :assassin)
  }

  attr_accessor :started, :players, :deck, :discard_pile, :turns, :invitation_sent
  
  def initialize
    self.started         = false
    self.players         = []
    self.deck            = self.build_starting_deck
    self.discard_pile    = []
    self.turns           = []
    self.invitation_sent = false
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
  
    self.players.shuffle.rotate!(rand(MAX_PLAYERS)) # shuffle seats
    $player_count = self.player_count

    self.next_turn
  end

  # Build starting deck
  #
  def build_starting_deck
    deck = []
    [:duke, :assassin, :contessa, :captain, :ambassador].each do |char|
      3.times.each do 
        deck << Character.new(char)
      end
    end
    deck
  end

  # Shuffle the deck, pass out characters and coins
  #
  def pass_out_characters_and_coins
    self.deck.shuffle!

    # assign loyalties
    puts "="*80
    self.players.each do |player|
      player.receive_characters( self.deck.shift(2) )
      player.give_coins(2)
      puts "#{player} #{player.characters.inspect} - #{player.coins}"      
    end
    puts "="*80
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
    self.deck << old_character
    self.deck.shuffle!
    player.characters[position] = self.deck.shift
  end


  # TURNS

  # Check and see if action is valid
  #
  def valid_action?(action)
    [:duke, :assassin, :contessa, :captain, :ambassador, :income, :foreign_aid, :coup].include? action
  end

  def process_current_turn
    case self.current_turn.action.action
    when :income
      self.current_player.give_coins 1
    when :foreign_aid
      self.current_player.give_coins 2
    when :coup
      self.current_player.take_coins 7
      self.current_turn.make_decider self.target_player
    when :duke
      self.current_player.give_coins 3
    when :assassin
      self.current_player.take_coins 3
      self.current_turn.make_decider self.target_player
    when :ambassador
      self.current_turn.make_decider self.current_player
    when :captain
      self.current_player.give_coins 2
      self.target_player.take_coins 2
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


  # turns

  def next_turn
    puts "="*80
    puts "END TURN: State #{self.current_turn.state}; Player #{self.current_turn.active_player}; Action #{self.current_turn.action.action}; Target #{self.current_turn.target_player};\nReactions Action #{self.current_turn.reactions.inspect}" unless current_turn.nil?
    self.current_turn.end_turn unless current_turn.nil?
    self.turns << Turn.new(self.players.rotate!.first)
    puts "-"*80
    puts "NEW TURN: State #{self.current_turn.state}; Player #{self.current_turn.active_player};"
    puts "="*80
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

  def reacting_players
    self.current_turn.counteraction.nil? ? (self.players - [self.current_player]) : (self.players - [self.target_player])
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

#================================================================================
# TURN
#================================================================================

class Turn

  attr_accessor :active_player, :action, :target_player, :counteraction, :decider, :reactions, :state

  def initialize(player)
    self.state          = :action # action, reactions, paused, decision, end
    self.active_player  = player
    self.target_player  = nil
    self.action         = nil
    self.counteraction  = nil
    self.decider        = nil # for when waiting on flips
    self.reactions      = {}
  end 


  def add_action(action, target = nil)
    self.action        = Game::ACTIONS[action.to_sym]
    self.target_player = target
  end

  def pass(player)
    if self.waiting_for_reactions?
      self.reactions[player] = :pass
    end
  end

  def make_decider(player)
    self.decider = player
  end

  # State methods

  def waiting_for_action?
    self.state == :action
  end

  def waiting_for_reactions?
    self.state == :reactions
  end

  def paused?
    self.state == :paused
  end

  def waiting_for_decision?
    self.state == :decision
  end

  def ended?
    self.state == :end
  end

  def wait_for_reactions
    self.state = :reactions
  end

  def pause
    self.state = :paused
  end

  def wait_for_decision
    self.state = :decision
  end

  def end_turn
    self.state = :end
  end

end


#================================================================================
# PLAYER
#================================================================================

class Player

  attr_accessor :user, :characters, :coins

  def initialize(user)
    self.user = user
    self.characters = []
    self.coins = 0
  end 

  def receive_characters(characters)
    characters.each do |c|
      self.characters << c
    end
  end

  def flip_character_card(position)
    # receive 1 or 2, translate to 0 or 1
    self.characters[position-1].flip_up
    self.characters[position-1]
  end

  def has_character?(character)
    self.characters.select{ |c| c.face_down? }.any?{ |c| c.name == character }
  end

  def character_position(character)
    char = self.characters.select{ |c| c.face_down? }.find{ |c| c.name == character }
    self.characters.index(char)
  end

  def switch_character(character, position)

  end

  def has_influence?
    self.characters.any?{ |c| c.face_down? }
  end

  def influence
    self.characters.select{ |c| c.face_down? }.size
  end

  def give_coins(amount)
    self.coins += amount
  end

  def take_coins(amount)
    self.coins -= amount
  end

  def to_s
    self.user.nick
  end

end


#================================================================================
# CHARACTER
#================================================================================

class Character

  attr_accessor :name, :face_down

  def initialize(name)
    self.name = name
    self.face_down = true
  end 

  def flip_up
    self.face_down = false
  end

  def face_down?
    self.face_down
  end

  def to_s
    self.name.to_s.upcase
  end

end






