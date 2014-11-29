#================================================================================
# PLAYER
#================================================================================

class Player

  attr_reader :user, :characters, :coins
  attr_reader :side_cards
  attr_accessor :faction

  def initialize(user)
    @user = user
    @characters = []
    @coins = 0

    # The four cards set aside in a 2p game.
    @side_cards = []

    @faction = 0
  end 

  def receive_characters(characters)
    characters.each do |c|
      self.characters << c
    end
  end

  def receive_side_characters(c1, c2, c3, c4, c5)
    @side_cards = [c1, c2, c3, c4, c5]
  end

  def select_side_character(position)
    # receives 1 to 5, translates to 0 to 4
    char = @side_cards.delete_at(position - 1)
    receive_characters([char])
  end

  def flip_character_card(position)
    # receive 1 or 2, translate to 0 or 1
    return nil unless self.characters[position-1].face_down?

    self.characters[position-1].flip_up
    self.characters[position-1]
  end

  def has_character?(character)
    self.characters.any? { |c| c.face_down? && c.name == character}
  end

  def character_position(character)
    self.characters.index { |c| c.face_down? && c.name == character }
  end

  def switch_character(character, position)
    old = self.characters[position]
    raise "Replaced #{self.user}'s face-up #{old}" unless old.face_down?
    self.characters[position] = character
  end

  def has_influence?
    self.characters.any?{ |c| c.face_down? }
  end

  def influence
    self.characters.count { |c| c.face_down? }
  end

  def give_coins(amount)
    @coins += amount
  end

  def take_coins(amount)
    if self.coins < amount
      taken = self.coins
      @coins = 0
      return taken
    end
    @coins -= amount
    amount
  end

  def to_s
    self.user.nick
  end

  def change_faction
    @faction = 1 - @faction
  end

end
