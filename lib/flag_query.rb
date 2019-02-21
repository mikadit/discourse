require 'ostruct'

module FlagQuery

  def self.plugin_post_custom_fields
    @plugin_post_custom_fields ||= {}
  end

  # Allow plugins to add custom fields to the flag views
  def self.register_plugin_post_custom_field(field, plugin)
    plugin_post_custom_fields[field] = plugin
  end

  def self.flagged_posts_report(current_user, opts = nil)
    Discourse.deprecate("FlagQuery is deprecated, use the Reviewable API instead.")

    opts ||= {}
    offset = opts[:offset] || 0
    per_page = opts[:per_page] || 25

    reviewables = ReviewableFlaggedPost
      .includes(:reviewable_scores)
      .viewable_by(current_user)
      .limit(per_page)
      .offset(offset)

    if opts[:filter] == 'old'
      reviewables = reviewables.where("status <> ?", Reviewable.statuses[:pending])
    else
      reviewables = reviewables.pending
    end

    total_rows = reviewables.count

    post_ids = reviewables.map(&:target_id).uniq

    posts = DB.query(<<~SQL, post_ids: post_ids)
      SELECT p.id,
             p.cooked as excerpt,
             p.raw,
             p.user_id,
             p.topic_id,
             p.post_number,
             p.reply_count,
             p.hidden,
             p.deleted_at,
             p.user_deleted,
             NULL as post_actions,
             NULL as post_action_ids,
             (SELECT created_at FROM post_revisions WHERE post_id = p.id AND user_id = p.user_id ORDER BY created_at DESC LIMIT 1) AS last_revised_at,
             (SELECT COUNT(*) FROM post_actions WHERE (disagreed_at IS NOT NULL OR agreed_at IS NOT NULL OR deferred_at IS NOT NULL) AND post_id = p.id)::int AS previous_flags_count
        FROM posts p
       WHERE p.id in (:post_ids)
    SQL

    post_lookup = {}
    user_ids = Set.new
    topic_ids = Set.new

    posts.each do |p|
      user_ids << p.user_id
      topic_ids << p.topic_id
      p.excerpt = Post.excerpt(p.excerpt)
      post_lookup[p.id] = p
    end

    reviewables.each do |r|
      post = post_lookup[r.target_id]

      if opts[:rest_api]
        post.post_action_ids ||= []
      else
        post.post_actions ||= []
      end

      r.reviewable_scores.each do |rs|
        disposition =
          case ReviewableScore.statuses[rs.status]
          when :agreed then :agreed
          when :disagreed then :disagreed
          when :ignored then :deferred
          else nil
          end

        action = {
          id: rs.id,
          post_id: post.id,
          user_id: post.user_id,
          post_action_type_id: rs.reviewable_score_type,
          created_at: rs.created_at,
          disposed_by_id: rs.reviewed_by_id,
          disposed_at: rs.reviewed_at,
          disposition: disposition,
          related_post_id: pa.related_post_id,
          targets_topic: pa.targets_topic,
          staff_took_action: pa.staff_took_action
        }
        action[:name_key] = PostActionType.types.key(pa.post_action_type_id)
      end
    end

    post_actions = actions.order('post_actions.created_at DESC')
      .includes(related_post: { topic: { ordered_posts: :user } })
      .where(post_id: post_ids)

    all_post_actions = []

    post_actions.each do |pa|

      if pa.related_post && pa.related_post.topic
        conversation = {}
        related_topic = pa.related_post.topic
        if response = related_topic.ordered_posts[0]
          conversation[:response] = {
            excerpt: excerpt(response.cooked),
            user_id: response.user_id
          }
          user_ids << response.user_id
          if reply = related_topic.ordered_posts[1]
            conversation[:reply] = {
              excerpt: excerpt(reply.cooked),
              user_id: reply.user_id
            }
            user_ids << reply.user_id
            conversation[:has_more] = related_topic.posts_count > 2
          end
        end

        action.merge!(permalink: related_topic.relative_url, conversation: conversation)
      end

      if opts[:rest_api]
        post.post_action_ids << action[:id]
        all_post_actions << action
      else
        post.post_actions << action
      end

      user_ids << pa.user_id
      user_ids << pa.disposed_by_id if pa.disposed_by_id
    end

    post_custom_field_names = []
    plugin_post_custom_fields.each do |field, plugin|
      post_custom_field_names << field if plugin.enabled?
    end

    post_custom_fields = Post.custom_fields_for_ids(post_ids, post_custom_field_names)

    # maintain order
    posts = post_ids.map { |id| post_lookup[id] }

    # TODO: add serializer so we can skip this
    posts.map! do |post|
      result = post.to_h
      if cfs = post_custom_fields[post.id]
        result[:custom_fields] = cfs
      end
      result
    end

    users = User.includes(:user_stat).where(id: user_ids.to_a).to_a
    User.preload_custom_fields(users, User.whitelisted_user_custom_fields(guardian))

    [
      posts,
      Topic.with_deleted.where(id: topic_ids.to_a).to_a,
      users,
      all_post_actions,
      total_rows
    ]
  end

  def self.flagged_post_actions(opts = nil)
    Discourse.deprecate("FlagQuery is deprecated, please use the Reviewable API instead.")

    opts ||= {}

    scores = ReviewableScore.includes(:reviewable).where('reviewables.type' => 'ReviewableFlaggedPost')
    scores = relation.where('reviewables.topic_id' => opts[:topic_id]) if opts[:topic_id]
    scores = relation.where('reviewables.target_created_by_id' => opts[:user_id]) if opts[:user_id]

    if opts[:filter] == 'without_custom'
      return scores.where(reviewable_score_type: PostActionType.flag_types_without_custom.values)
    end

    if opts[:filter] == "old"
      scores = scores.where('reviewables.status <> ?', Reviewable.statuses[:pending])
    else
      scores = scores.where('reviewables.status' => Reviewable.statuses[:pending])
    end

    scores
  end

  def self.flagged_topics
    Discourse.deprecate("FlagQuery has been deprecated. Please use the Reviewable API instead.")

    params = {
      pending: Reviewable.statuses[:pending],
      min_score: SiteSetting.min_score_default_visibility
    }

    results = DB.query(<<~SQL, params)
      SELECT rs.reviewable_score_type,
        p.id AS post_id,
        r.topic_id,
        rs.created_at,
        p.user_id
      FROM reviewables AS r
      INNER JOIN reviewable_scores AS rs ON rs.reviewable_id = r.id
      INNER JOIN posts AS p ON p.id = r.target_id
      WHERE r.type = 'ReviewableFlaggedPost'
        AND r.status = :pending
        AND r.score >= :min_score
      ORDER BY rs.created_at DESC
    SQL

    ft_by_id = {}
    user_ids = Set.new

    results.each do |r|
      ft = ft_by_id[r.topic_id] ||= OpenStruct.new(
        topic_id: r.topic_id,
        flag_counts: {},
        user_ids: Set.new,
        last_flag_at: r.created_at,
      )

      ft.flag_counts[r.reviewable_score_type] ||= 0
      ft.flag_counts[r.reviewable_score_type] += 1

      ft.user_ids << r.user_id
      user_ids << r.user_id
    end

    all_topics = Topic.where(id: ft_by_id.keys).to_a
    all_topics.each { |t| ft_by_id[t.id].topic = t }

    Topic.preload_custom_fields(all_topics, TopicList.preloaded_custom_fields)
    {
      flagged_topics: ft_by_id.values,
      users: User.where(id: user_ids)
    }
  end

  private

  def self.excerpt(cooked)
    excerpt = Post.excerpt(cooked, 200, keep_emoji_images: true)
    # remove the first link if it's the first node
    fragment = Nokogiri::HTML.fragment(excerpt)
    if fragment.children.first == fragment.css("a:first").first && fragment.children.first
      fragment.children.first.remove
    end
    fragment.to_html.strip
  end

end
