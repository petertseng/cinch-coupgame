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
    return nil unless self.characters[position-1].face_down?

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
    self.characters[position] = character
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
    if self.coins < amount
      taken = self.coins
      self.coins = 0
      return taken
    end
    self.coins -= amount
    amount
  end

  def to_s
    self.user.nick
  end

end