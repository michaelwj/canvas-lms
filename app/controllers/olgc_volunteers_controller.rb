# frozen_string_literal: true

# OLGC fork: volunteer-course enrollment tooling for the mobile app.
#
# Being enrolled in the Volunteering course means "eligible to be put on a
# shift" — the roster is the pool the CSV matcher and reassign picker draw
# from. Managers decide who joins; this controller gives them the list of
# people who SHOULD be there (tagged Parent / SC via the OLGC roles map,
# see OlgcRolesController) but are not yet actively enrolled, and enrolls
# the ones they pick straight into a section with an ACTIVE enrollment, so
# nobody has to accept an invitation. Pending ("invited") enrollments are
# listed as candidates too and get upgraded to active by the same call.
#
#   GET  /api/v1/olgc_volunteer_course
#     -> { "course_id": 123 | null }         (Setting olgc_volunteer_course_id)
#   GET  /api/v1/courses/:course_id/olgc_volunteer_candidates
#     -> { "sections": [...], "default_section_id": n, "candidates": [...] }
#   POST /api/v1/courses/:course_id/olgc_volunteer_enrollments
#        user_ids[]=1&user_ids[]=2&section_id=9
#     -> { "enrolled": [{ user_id, enrollment_id, workflow_state, section_id }] }
#
# Both course-scoped actions require the caller to be able to create student
# enrollments in the course (the manager's teacher enrollment grants that).
class OlgcVolunteersController < ApplicationController
  include AvatarHelper

  before_action :require_user
  before_action :load_course, except: :course
  before_action :require_enroll_permission, except: :course

  COURSE_SETTING = "olgc_volunteer_course_id"
  # comma-separated role labels (from the OLGC roles map) that qualify
  ROLES_SETTING = "olgc_volunteer_roles"
  DEFAULT_ROLES = "Parent,SC"
  MAX_BATCH = 200

  def course
    id = Setting.get(COURSE_SETTING, "").presence
    render json: { course_id: id && id.to_i }
  end

  def candidates
    eligible = self.class.eligible_roles
    roles = OlgcRolesController.roles_map
    tagged = roles.select { |_id, names| names.intersect?(eligible) }
    ids = tagged.keys.map(&:to_i)

    # anyone with an ACTIVE enrollment of any type is already in (managers
    # included — we never want to double-enroll a teacher as a student)
    active_ids = @course.enrollments.where(user_id: ids, workflow_state: "active").distinct.pluck(:user_id)
    pending = @course.enrollments
                     .where(user_id: ids - active_ids)
                     .where.not(workflow_state: %w[deleted rejected completed])
                     .preload(:course_section)
                     .group_by(&:user_id)

    users = User.active.where(id: ids - active_ids).order(:sortable_name).to_a
    render json: {
      sections: sections_json,
      default_section_id: @course.default_section.id,
      candidates: users.map do |u|
        e = pending[u.id]&.first
        {
          id: u.id,
          name: u.name,
          sortable_name: u.sortable_name,
          email: u.email,
          avatar_url: avatar_url_for_user(u),
          roles: tagged[u.id.to_s],
          enrollment: e && {
            id: e.id,
            workflow_state: e.workflow_state,
            section_id: e.course_section_id,
            section_name: e.course_section&.name
          }
        }
      end
    }
  end

  def enroll
    user_ids = Array(params[:user_ids]).map(&:to_i).uniq.first(MAX_BATCH)
    return render json: { errors: ["user_ids required"] }, status: :bad_request if user_ids.empty?

    section = if params[:section_id].present?
                @course.course_sections.active.find(params[:section_id])
              else
                @course.default_section
              end

    enrolled = User.active.where(id: user_ids).map do |user|
      e = @course.enroll_user(user, "StudentEnrollment", section:, enrollment_state: "active", no_notify: true)
      { user_id: user.id, enrollment_id: e.id, workflow_state: e.workflow_state, section_id: e.course_section_id }
    end
    render json: { enrolled: }
  end

  def self.eligible_roles
    Setting.get(ROLES_SETTING, DEFAULT_ROLES).split(",").map(&:strip).compact_blank
  end

  private

  def load_course
    @course = api_find(Course.active, params[:course_id])
  end

  def require_enroll_permission
    return if @current_user.can_create_enrollment_for?(@course, session, "StudentEnrollment")

    render_unauthorized_action
  end

  def sections_json
    @course.course_sections.active.order(:name).map { |s| { id: s.id, name: s.name } }
  end
end
