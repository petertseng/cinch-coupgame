
#================================================================================
# ACTION
#================================================================================

class Action

  attr_accessor :action, :name, :character_required, :effect, :needs_target, :has_decision, :cost, :blocks, :blockable_by
  attr_reader :mode_forbidden

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

    @mode_forbidden = options[:mode_forbidden] || nil
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

  def blockable?
    !self.blockable_by.empty?
  end

  def to_s
    self.action.to_s
  end

end