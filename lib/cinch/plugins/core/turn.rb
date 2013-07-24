#================================================================================
# TURN
#================================================================================

class Turn

  attr_accessor :active_player, :action, :target_player, :counteracting_player, :counteraction, :decider, :reactions, :state

  def initialize(player)
    self.state                = :action # action, reactions, paused, decision, end
    self.active_player        = player
    self.target_player        = nil
    self.action               = nil
    self.counteraction        = nil
    self.counteracting_player = nil
    self.decider              = nil # for when waiting on flips
    self.reactions            = {}
  end 


  def add_action(action, target = nil)
    self.action        = Game::ACTIONS[action.to_sym]
    self.target_player = target
  end

  def add_counteraction(action, player)
    self.counteraction        = Game::ACTIONS[action.to_sym]
    self.counteracting_player = player
    self.reactions            = {}
  end

  def pass(player)
    if self.waiting_for_reactions?
      self.reactions[player] = :pass
    end
  end

  def make_decider(player)
    self.decider = player
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




