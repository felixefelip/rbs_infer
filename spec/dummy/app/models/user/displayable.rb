# frozen_string_literal: true

module User::Displayable
  extend ActiveSupport::Concern

  def initials
    first = first_name.to_s[0] || ""
    last = last_name.to_s[0] || ""
    "#{first}#{last}".upcase
  end

  def display_name
    full_name.presence || email
  end

  def gravatar_url(size = 80)
    hash = Digest::MD5.hexdigest(email.to_s.downcase.strip)
    "https://www.gravatar.com/avatar/#{hash}?s=#{size}&d=identicon"
  end

  def profile_summary
    {
      name: display_name,
      initials: initials,
      posts_count: posts_count,
      member_since: created_at&.year
    }
  end

  def short_bio(max = 100)
    "#{display_name} — #{posts_count} posts"
  end
end
