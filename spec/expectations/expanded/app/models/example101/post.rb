module Example101
  class Post
    include Assoc

    declare :comments
  end
end

class Example101::Post
  extend ::Example101::Assoc::ClassMethods
end
