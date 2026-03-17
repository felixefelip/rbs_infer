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
end
