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

  def eql?(character)  
    self.class.equal?(character.class) &&  
      self.name == character.name
  end 

  alias == eql?  

end

