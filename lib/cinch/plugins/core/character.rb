#================================================================================
# CHARACTER
#================================================================================

class Character

  attr_reader :id
  attr_reader :name, :face_down

  def initialize(id, name)
    @id = id
    @name = name
    @face_down = true
  end 

  def flip_up
    raise "card #{@id} is already face-up" unless self.face_down?
    @face_down = false
  end

  def face_down?
    self.face_down
  end

  def to_s
    self.name.to_s.upcase
  end

  def eql?(character)  
    self.class.equal?(character.class) &&  
      @id == character.id
  end 

  alias == eql?  

end

