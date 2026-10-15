# frozen_string_literal: true

# OLGC fork patch: a parent (observer) may create/update a planner override
# ON BEHALF OF a child they observe, by passing observed_user_id to
# POST/PUT /api/v1/planner/overrides. Used by the mobile app's To Do list so
# a parent can tick an on-paper assignment done for a student with no
# device. Isolated spec file so upstream rebases never conflict here — run
# with the other olgc specs on every Canvas upgrade.

require_relative "../api_spec_helper"

describe "OLGC: planner overrides on behalf of an observed student", type: :request do
  let(:course) { course_factory(active_all: true) }
  let(:student) { user_with_pseudonym(active_all: true) }
  let(:parent) { user_with_pseudonym(active_all: true) }
  let(:stranger) { user_with_pseudonym(active_all: true) }
  let(:assignment) { course.assignments.create!(title: "Worksheet", submission_types: "on_paper", points_possible: 10, due_at: 2.days.from_now) }

  before do
    course.enroll_student(student, enrollment_state: "active")
    course.enroll_user(parent, "ObserverEnrollment", associated_user_id: student.id, enrollment_state: "active")
    course.enroll_user(stranger, "ObserverEnrollment", enrollment_state: "active") # observer of the course, not of the student
  end

  def create_override(as:, params:, expected_status: 201)
    @user = as
    api_call(:post,
             "/api/v1/planner/overrides",
             { controller: "planner_overrides", action: "create", format: "json" },
             { plannable_type: "assignment", plannable_id: assignment.id, marked_complete: true }.merge(params),
             {},
             { expected_status: })
  end

  def update_override(as:, id:, params:, expected_status: 200)
    @user = as
    api_call(:put,
             "/api/v1/planner/overrides/#{id}",
             { controller: "planner_overrides", action: "update", format: "json", id: id.to_param },
             { marked_complete: false }.merge(params),
             {},
             { expected_status: })
  end

  describe "POST create with observed_user_id" do
    it "writes the override as the child when the parent observes them in that course" do
      json = create_override(as: parent, params: { observed_user_id: student.id })
      override = PlannerOverride.find(json["id"])
      expect(override.user).to eq student
      expect(override.marked_complete).to be true
      expect(assignment.planner_override_for(student)).to eq override
      expect(assignment.planner_override_for(parent)).to be_nil
    end

    it "is refused for an observer who is not linked to that student" do
      create_override(as: stranger, params: { observed_user_id: student.id }, expected_status: 403)
      expect(assignment.planner_override_for(student)).to be_nil
    end

    it "is refused for a parent observing the student only in another course" do
      other = course_factory(active_all: true)
      other_assignment = other.assignments.create!(title: "Elsewhere", submission_types: "on_paper", points_possible: 5)
      other.enroll_student(student, enrollment_state: "active")
      # the fork's auto-link (df374a321a4) follows the student into new courses; take the parent back out of this one
      other.enrollments.where(user_id: parent.id).find_each { |e| e.workflow_state = "deleted"; e.save! }
      @user = parent
      api_call(:post,
               "/api/v1/planner/overrides",
               { controller: "planner_overrides", action: "create", format: "json" },
               { plannable_type: "assignment", plannable_id: other_assignment.id, marked_complete: true, observed_user_id: student.id },
               {},
               { expected_status: 403 })
      expect(other_assignment.planner_override_for(student)).to be_nil
    end

    it "still writes the parent's own override without the param (stock behavior)" do
      json = create_override(as: parent, params: {})
      expect(PlannerOverride.find(json["id"]).user).to eq parent
    end
  end

  describe "PUT update with observed_user_id" do
    it "updates the child's override and the child's planner items reflect it" do
      override = PlannerOverride.create!(plannable: assignment, user: student, marked_complete: true)
      json = update_override(as: parent, id: override.id, params: { observed_user_id: student.id, marked_complete: false })
      expect(json["marked_complete"]).to be false
      expect(override.reload.marked_complete).to be false
      expect(override.user).to eq student
    end

    it "cannot reach the child's override without being linked" do
      override = PlannerOverride.create!(plannable: assignment, user: student, marked_complete: true)
      update_override(as: stranger, id: override.id, params: { observed_user_id: student.id, marked_complete: false }, expected_status: 403)
      expect(override.reload.marked_complete).to be true
    end
  end
end
