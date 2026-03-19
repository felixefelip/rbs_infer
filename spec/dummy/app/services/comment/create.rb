class Comment::Create
	def create(comment_id)
		comment = Comment.find(comment_id)

		return if comment.body.blank?

		response = :ok
		process_creation_response(comment, response)
	end

	private

	def process_creation_response(comment, status)
		puts "Comment created successfully for comment #{comment.id}, status: #{status}"
		comment.save!
	end

	def dummy_hash
    { foo: "bar",
		  baz: 42,
	  	nested: { a: 1, b: 2 },
			comment: Comment.new
		}
	end

	def test_dummy_hash
		dummy_hash[:comment].body = "Test body"

		# adding a new key to the hash to test dynamic behavior
		dummy_hash[:other_comment] = Comment.new(body: "Another comment")
	end
end
