class Column
  attr_accessor :board, :column_name, :user_name

	def initialize(column_name:)
		@column_name = column_name
	end

  def set_default_user_name
		self.user_name = board.user_name
  end
end

class Board
  attr_reader :user_name

	def initialize(user_name:)
		@user_name = user_name
	end
end

class Example
  def self.run
	  board = Board.new(user_name: 'John Doe')

		column = Column.new(column_name: 'To Do') # user_name e board são nil neste ponto

		column.board = board

		column.set_default_user_name # como o board foi atribuído, agora o user_name será definido corretamente sem NoMethodError
  end
end
