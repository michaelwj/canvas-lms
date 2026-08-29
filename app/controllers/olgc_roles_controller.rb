# frozen_string_literal: true

# OLGC fork: community role labels ("OLGC Roles" differentiation tags on the
# community board course) served to ANY enrolled user. Tags are invisible to
# non-admin API callers by Canvas design, so the app cannot read them with
# the user\'s own token — this endpoint reads them with server authority and
# exposes only the derived label map. Read-only; labeling, not authorization.
#
#   GET /api/v1/courses/:course_id/olgc_roles
#     -> { "<user_id>": ["SC", "Parent"], ... }
#
# The :course_id only gates ACCESS (must be able to read that course); the
# labels always come from the board course named by Setting
# "olgc_roles_course_id" (unset => {}). Cached 5 minutes per process.
class OlgcRolesController < ApplicationController
  before_action :require_user

  ROLES_CATEGORY = "OLGC Roles"
  SETTING = "olgc_roles_course_id"

  def show
    course = api_find(Course.active, params[:course_id])
    return render_unauthorized_action unless course.grants_right?(@current_user, session, :read)

    render json: self.class.roles_map
  end

  # Two sources, institutional preferred: an account-level "OLGC Roles"
  # institutional-tag category (tags users directly, no course membership
  # needed) wins when it has data; otherwise the board course's
  # differentiation tags (Setting olgc_roles_course_id). Same output shape
  # either way, so clients never care which is active.
  def self.roles_map
    Rails.cache.fetch(["olgc_roles_map", Setting.get(SETTING, "")].cache_key, expires_in: 5.minutes) do
      institutional_roles_map.presence || course_tag_roles_map
    end
  end

  def self.institutional_roles_map
    return {} unless Account.default.feature_enabled?(:institutional_tags)

    category = InstitutionalTagCategory.active.find_by(account: Account.default, name: ROLES_CATEGORY)
    return {} unless category

    map = Hash.new { |h, k| h[k] = [] }
    InstitutionalTagAssociation.active
                               .joins(:institutional_tag)
                               .merge(InstitutionalTag.active)
                               .where(institutional_tags: { category_id: category.id })
                               .where.not(user_id: nil)
                               .pluck(:user_id, :"institutional_tags.name")
                               .each { |user_id, name| map[user_id.to_s] << name }
    map.each_value(&:sort!)
    map
  end

  def self.course_tag_roles_map
    source_id = Setting.get(SETTING, "").presence
    return {} unless source_id

    source = Course.active.find_by(id: source_id)
    return {} unless source

    categories = source.all_differentiation_tag_categories.where(name: ROLES_CATEGORY)
    tags = Group.active.non_collaborative.where(group_category_id: categories.select(:id))
    map = Hash.new { |h, k| h[k] = [] }
    GroupMembership.where(group_id: tags.select(:id))
                   .where.not(workflow_state: "deleted")
                   .joins(:group)
                   .pluck(:user_id, "groups.name")
                   .each { |user_id, name| map[user_id.to_s] << name }
    map.each_value(&:sort!)
    map
  end
end
