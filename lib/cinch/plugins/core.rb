require 'json'

#================================================================================
# GAME
#================================================================================

$player_count = 0

class Game


  MIN_PLAYERS = 3
  MAX_PLAYERS = 6
  STARTING_DECK = [
      :duke, :assassin, :contessa, :captain, :ambassador,
      :duke, :assassin, :contessa, :captain, :ambassador,
      :duke, :assassin, :contessa, :captain, :ambassador
    ]
  COINS = 50

  attr_accessor :started, :players, :deck, :invitation_sent
  
  def initialize
    self.started         = false
    self.players         = []
    self.deck            = STARTING_DECK
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

    self.next_turn(players.first)
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


  # TURN

  # Check and see if action is valid
  #
  def valid_action?(action)
    [:duke, :assassin, :contessa, :captain, :ambassador, :income, :foreign_aid, :coup].include? action
  end

  # def vote_for_mission(player, vote)
  #   @current_round.mission_votes[self.find_player(player)] = vote
  # end

  # def not_back_from_mission
  #   team_players = @current_round.team.players
  #   back_players = @current_round.mission_votes.keys
  #   not_back = team_players.reject{ |player| back_players.include?(player) }
  #   not_back
  # end

  # def all_mission_votes_in?
  #   self.not_back_from_mission.size == 0
  # end

  # NEXT TURN

  def check_game_state
    if self.started?
        # status = "Waiting on players to PASS or CHALLENGE: #{self.not_back_from_mission.map(&:user).join(", ")}"
    else
      if self.player_count.zero?
        status = "No game in progress."
      else
        status = "Game being started. #{player_count} players have joined: #{self.players.map(&:user).join(", ")}"
      end
    end
    status
  end


  # GAME STATE

  def is_over?
    
  end

  def winner?
    
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

  attr_accessor :active_player, :action, :reactions

  def initialize(player)
    self.active_player = player
    self.action = nil
    self.reactions = {}
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
    self.characters = characters
  end

  def give_coins(amount)
    self.coins += amount
  end

  def to_s
    self.user.nick
  end

end






