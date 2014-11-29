#================================================================================
# TURN
#================================================================================

class Turn

  attr_reader :active_player, :action, :target_player, :counteracting_player, :counteraction, :decider, :reactions, :state

  attr_accessor :action_challenger
  attr_accessor :block_challenger

  attr_accessor :action_challenge_successful
  attr_accessor :block_challenge_successful

  attr_accessor :decision_type

  def initialize(player)
    @state                = :action # action, reactions, paused, decision, end
    @active_player        = player
    @target_player        = nil
    @action               = nil
    @counteraction        = nil
    @counteracting_player = nil
    @decider              = nil # for when waiting on flips
    @reactions            = {}

    @action_challenger = nil
    @block_challenger = nil

    @action_challenge_successful = false
    @block_challenge_successful = false

    @decision_type = nil # lose influence, switch cards, show to inquisitor, keep/discard
  end 


  def add_action(action, target = nil)
    @action        = action
    @target_player = target
  end

  def add_counteraction(action, player)
    @counteraction        = action
    @counteracting_player = player
    @reactions            = {}
  end

  def pass(player)
    if self.waiting_for_reactions?
      return false if @reactions[player] == :pass
      @reactions[player] = :pass
      return true
    end
    false
  end

  def make_decider(player)
    @decider = player
  end

  def counteracted?
    self.counteraction != nil
  end

  def challengee_action
    self.counteracted? ? self.counteraction : self.action
  end

  def challengee_player
    self.counteracted? ? self.counteracting_player : self.active_player
  end

  # State methods

  def waiting_for_initial_characters?
    self.state == :initial_characters
  end

  def waiting_for_reactions?
    [:action_challenge, :block, :block_challenge].include?(self.state)
  end

  def waiting_for_challenges?
    [:action_challenge, :block_challenge].include?(self.state)
  end

  def waiting_for_action?
    self.state == :action
  end

  def waiting_for_action_challenge?
    self.state == :action_challenge
  end

  def waiting_for_action_challenge_reply?
    self.state == :action_challenge_reply
  end

  def waiting_for_action_challenge_loser?
    self.state == :action_challenge_loser
  end

  def waiting_for_block?
    self.state == :block
  end

  def waiting_for_block_challenge?
    self.state == :block_challenge
  end

  def waiting_for_block_challenge_reply?
    self.state == :block_challenge_reply
  end

  def waiting_for_block_challenge_loser?
    self.state == :block_challenge_loser
  end

  def waiting_for_decision?
    self.state == :decision
  end

  def wait_for_challenge_loser
    if self.state == :action_challenge_reply
      @state = :action_challenge_loser
    elsif self.state == :block_challenge_reply
      @state = :block_challenge_loser
    else
      raise "wait_for_challenge_loser at state #{self.state}"
    end
  end

  def wait_for_initial_characters
    @state = :initial_characters
  end

  def wait_for_action
    @state = :action
  end

  def wait_for_action_challenge
    @state = :action_challenge
  end

  def wait_for_action_challenge_reply
    @state = :action_challenge_reply
  end

  def wait_for_block
    @state = :block
    @reactions = {}
  end

  def wait_for_block_challenge
    @state = :block_challenge
    @reactions = {}
  end

  def wait_for_block_challenge_reply
    @state = :block_challenge_reply
  end

  def wait_for_decision
    @state = :decision
  end

  def end_turn
    @state = :end
  end

end




