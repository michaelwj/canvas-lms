# frozen_string_literal: true

#
# Copyright (C) 2017 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# @API Planner
# @subtopic Planner Overrides
#
# API for creating, accessing and updating planner override. PlannerOverrides are used
# to control the visibility of objects displayed on the Planner.
#
# @model PlannerOverride
#     {
#       "id": "PlannerOverride",
#       "description": "User-controlled setting for whether an item should be displayed on the planner or not",
#       "properties": {
#         "id": {
#           "description": "The ID of the planner override",
#           "example": 234,
#           "type": "integer"
#         },
#         "plannable_type": {
#           "description": "The type of the associated object for the planner override",
#           "example": "Assignment",
#           "type": "string"
#         },
#         "plannable_id": {
#           "description": "The id of the associated object for the planner override",
#           "example": 1578941,
#           "type": "integer"
#         },
#         "user_id": {
#           "description": "The id of the associated user for the planner override",
#           "example": 1578941,
#           "type": "integer"
#         },
#         "assignment_id": {
#           "description": "The id of the plannable's associated assignment, if it has one",
#           "example": 1578941,
#           "type": "integer"
#         },
#         "workflow_state": {
#           "description": "The current published state of the item, synced with the associated object",
#           "example": "published",
#           "type": "string"
#         },
#         "marked_complete": {
#           "description": "Controls whether or not the associated plannable item is marked complete on the planner",
#           "example": false,
#           "type": "boolean"
#         },
#         "dismissed": {
#           "description": "Controls whether or not the associated plannable item shows up in the opportunities list",
#           "example": false,
#           "type": "boolean"
#         },
#         "created_at": {
#           "description": "The datetime of when the planner override was created",
#           "example": "2017-05-09T10:12:00Z",
#           "type": "datetime"
#         },
#         "updated_at": {
#           "description": "The datetime of when the planner override was updated",
#           "example": "2017-05-09T10:12:00Z",
#           "type": "datetime"
#         },
#         "deleted_at": {
#           "description": "The datetime of when the planner override was deleted, if applicable",
#           "example": "2017-05-15T12:12:00Z",
#           "type": "datetime"
#         }
#       }
#     }
#
class PlannerOverridesController < ApplicationController
  include Api::V1::PlannerOverride

  # OLGC fork patch: see olgc_resolve_target_user below.
  before_action :olgc_resolve_target_user, only: %i[create update]

  # @API List planner overrides
  #
  # Retrieve a planner override for the current user
  #
  # @returns [PlannerOverride]
  def index
    planner_overrides = Api.paginate(PlannerOverride.for_user(@current_user).active, self, api_v1_planner_overrides_url)
    render json: planner_overrides.map { |po| planner_override_json(po, @current_user, session) }
  end

  # @API Show a planner override
  #
  # Retrieve a planner override for the current user
  #
  # @returns PlannerOverride
  def show
    planner_override = PlannerOverride.for_user(@current_user).find(params[:id])
    render json: planner_override_json(planner_override, @current_user, session)
  end

  # @API Update a planner override
  #
  # Update a planner override's visibilty for the current user
  #
  # @argument marked_complete
  #   determines whether the planner item is marked as completed
  #
  # @argument dismissed
  #   determines whether the planner item shows in the opportunities list
  #
  # @returns PlannerOverride
  def update
    planner_override = PlannerOverride.for_user(@target_user).find(params[:id])
    return unless olgc_authorized_for?(planner_override.plannable)

    planner_override.marked_complete = value_to_boolean(params[:marked_complete])
    planner_override.dismissed = value_to_boolean(params[:dismissed])
    sync_module_requirement_done(planner_override.plannable, @target_user, value_to_boolean(params[:marked_complete]))

    if planner_override.save
      olgc_clear_planner_caches
      render json: planner_override_json(planner_override, @target_user, session), status: :ok
    else
      render json: planner_override.errors, status: :bad_request
    end
  end

  # @API Create a planner override
  #
  # Create a planner override for the current user
  #
  # @argument plannable_type [Required, String, "announcement"|"assignment"|"discussion_topic"|"quiz"|"wiki_page"|"planner_note"|"calendar_event"|"assessment_request"|"sub_assignment"|"peer_review_sub_assignment"]
  #   Type of the item that you are overriding in the planner
  #
  # @argument plannable_id [Required, Integer]
  #   ID of the item that you are overriding in the planner
  #
  # @argument marked_complete [Boolean]
  #   If this is true, the item will show in the planner as completed
  #
  # @argument dismissed [Boolean]
  #   If this is true, the item will not show in the opportunities list
  #
  #
  # @returns PlannerOverride
  def create
    plannable_type = PlannerHelper::PLANNABLE_TYPES[params[:plannable_type]]
    plannable = plannable_type.constantize.find(params[:plannable_id])
    return unless olgc_authorized_for?(plannable)

    planner_override = PlannerOverride.new(plannable:,
                                           marked_complete: value_to_boolean(params[:marked_complete]),
                                           user: @target_user,
                                           dismissed: value_to_boolean(params[:dismissed]))
    planner_override.plannable_type = plannable.type if plannable.is_a?(SubAssignment) || plannable.is_a?(PeerReviewSubAssignment)
    sync_module_requirement_done(plannable, @target_user, value_to_boolean(params[:marked_complete]))

    begin
      if planner_override.save
        olgc_clear_planner_caches
        render json: planner_override_json(planner_override, @target_user, session), status: :created
      else
        render json: planner_override.errors, status: :bad_request
      end
    rescue ActiveRecord::RecordNotUnique => e
      # although a callback tries to validate the uniqueness here on the model,
      # there's a race condition where 2 requests try to create a planner
      # here at almost the exact same time.  This should fail the second
      # one gracefully rather than sending a 500.
      Canvas::Errors.capture_exception(:planner_overrides, e, :info)
      planner_override.errors.add(:plannable_id, :already_exists, message: "A planner override for this item already exists")
      render json: planner_override.errors, status: :bad_request
    end
  end

  # @API Delete a planner override
  #
  # Delete a planner override for the current user
  #
  # @returns PlannerOverride
  def destroy
    planner_override = PlannerOverride.for_user(@current_user).find(params[:id])

    if planner_override.destroy
      Rails.cache.delete(planner_meta_cache_key)
      render json: planner_override_json(planner_override, @current_user, session), status: :ok
    else
      render json: planner_override.errors, status: :bad_request
    end
  end

  private

  # OLGC fork patch: a parent may tick a child's To Do item done — on-paper
  # work when the student has no device of their own. With observed_user_id
  # the override is written AS THE CHILD, so the child's own planner, the
  # web To Do list and every observer agree (a per-parent override would
  # not, and could not tell siblings in one course apart). Allowed only
  # while the parent actively observes that child in the item's course.
  # Without the param everything behaves exactly as stock.
  def olgc_resolve_target_user
    @target_user = params[:observed_user_id].present? ? api_find(User, params[:observed_user_id]) : @current_user
  end

  def olgc_authorized_for?(plannable)
    return true if @target_user == @current_user

    course_id = plannable.try(:context_id) if plannable.try(:context_type) == "Course"
    observing = course_id &&
                @current_user.observer_enrollments.active
                             .where(associated_user_id: @target_user, course_id:)
                             .shard(@current_user).exists?
    return true if observing

    render_unauthorized_action
    false
  end

  def olgc_clear_planner_caches
    Rails.cache.delete(planner_meta_cache_key(@target_user))
    Rails.cache.delete(planner_meta_cache_key) if @target_user != @current_user
  end

end
