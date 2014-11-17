
#================================================================================
# ACTION
#================================================================================

class Action

  attr_accessor :action, :name, :character_required, :effect, :needs_target, :has_decision, :cost, :blocks, :blockable_by
  attr_reader :can_target_friends
  attr_reader :character_forbidden
  attr_reader :mode_forbidden
  attr_reader :mode_required
  attr_reader :self_targettable
  attr_reader :self_effect
  attr_reader :effect_f

  def initialize(options)
    self.action              = options[:action]
    self.name                = options[:name] 
    self.character_required  = options[:character_required] || nil          
    @character_forbidden     = options[:character_forbidden] || nil
    self.effect              = options[:effect] || ""
    self.needs_target        = options[:needs_target] || false
    @can_target_friends      = options[:can_target_friends] || false
    self.has_decision        = options[:has_decision] || false
    self.cost                = options[:cost] || 0
    self.blocks              = options[:blocks] || nil
    self.blockable_by        = options[:blockable_by] || []

    @mode_forbidden = options[:mode_forbidden] || nil
    @mode_required = options[:mode_required] || nil
    @self_targettable = options[:self_targettable] || false
    @self_effect = options[:self_effect] || false
    @effect_f = options[:effect_f] || nil
  end 

  # State methods

  def challengeable?
    self.character_required? || self.character_forbidden?
  end

  def needs_decision?
    self.has_decision
  end

  def character_required?
    !self.character_required.nil?
  end

  def character_forbidden?
    !self.character_forbidden.nil?
  end

  def blockable?
    !self.blockable_by.empty?
  end

  def to_s
    self.action.to_s
  end

  def to_s_full(actor, target)
    req = @character_required && "Requires #{@character_required.capitalize}"
    forbid = @character_forbidden && "Cannot have #{@character_forbidden.capitalize}"
    effect = actor == target && @self_effect ? @self_effect : @effect
    return "#{@name} (#{[req, forbid, effect].compact.join(', ')})"
  end

end
