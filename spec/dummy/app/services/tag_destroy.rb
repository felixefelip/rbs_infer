# Example with a instance variable wifh attr_reader

class TagDestroy
  attr_reader :tag, :user, :posts, :xml

	def initialize(tag_id, user_id)
		@tag = Tag.find(tag_id)
		@posts = []
    atribui_user(user_id)
	end

	def call
		tag.destroy
	end

	private

	def atribui_user(user_id)
		@user = User.find(user_id)
	end

  def user_name
		user.name
  end

	def iterate_tags
		my_tags = tag.posts.first&.tags&.order(:name)
		my_tags&.each do |t|
			t.save!
		end
	end

	# Test when the local var has the same name as the attr_reader and different type
  def iterate_tag_posts
	  posts = tag.posts.order(:created_at)
	  posts.where(status: :published).each do |post|
	    puts post.title
	  end
  end

  def iterate_tag_posts_with_transaction
		ActiveRecord::Base.transaction do
			iterate_tag_posts
		end
  end

  def call_process_tag
	  process_tag(tag)
  end

  def process_tag(tag)
	  tag.save!
  end

	def test_nokogiri
		@xml = Nokogiri::XML("")
	end

  def parse_xml
		xml.xpath("//Pedidos").map do |order|
      order
    end
  end

	def parse_xml_as_hash
    xml.xpath("//Pedidos").map do |order|
      test_hash(order)
    end
	end

	def test_hash(order)
		{ order: order, date: order.date }
	end

	def verify_multiples_returns_with_void
		if user_posts.any?
			save_post
		elsif user_name
		 	user_name
		else
			nil
		end
	end

	def verify_multiples_returns_with_void_and_rescue
		user_posts.first!.save!
	rescue StandardError
		"error"
	end

	# when returns two types
	# def verify_multiples_returns
	# 	user_posts.first!.save || user_name
	# end

	def save_post
    user_posts.first!.save!
	end

	def user_posts
    @user.posts
	end
end
