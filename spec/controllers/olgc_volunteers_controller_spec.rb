# frozen_string_literal: true

# OLGC fork patch: volunteer-course enrollment tooling. Isolated spec file so
# upstream rebases never conflict here — run with the other olgc specs on
# every Canvas upgrade.

require_relative "../spec_helper"

describe OlgcVolunteersController do
  before :once do
    # the board: role tags live here (course differentiation tags path)
    @board = course_factory(active_all: true)
    category = GroupCategory.create!(
      context: @board, name: OlgcRolesController::ROLES_CATEGORY, non_collaborative: true
    )
    parent_tag = @board.groups.create!(name: "Parent", group_category: category, non_collaborative: true)
    sc_tag = @board.groups.create!(name: "SC", group_category: category, non_collaborative: true)
    teacher_tag = @board.groups.create!(name: "Teacher", group_category: category, non_collaborative: true)

    @parent = user_with_pseudonym(active_all: true, name: "Pat Parent", username: "pat@example.com")
    @pending_parent = user_with_pseudonym(active_all: true, name: "Penny Pending")
    @sc = user_with_pseudonym(active_all: true, name: "Sam Steering")
    @enrolled_parent = user_with_pseudonym(active_all: true, name: "Ed Enrolled")
    @teacher_only = user_with_pseudonym(active_all: true, name: "Tia Teacher")
    [@parent, @pending_parent, @sc, @enrolled_parent, @teacher_only].each { |u| @board.enroll_student(u, enrollment_state: "active") }
    [@parent, @pending_parent, @enrolled_parent].each { |u| parent_tag.add_user(u) }
    sc_tag.add_user(@sc)
    teacher_tag.add_user(@teacher_only)

    # the volunteer course: manager is a teacher; two sections
    @course = course_factory(active_all: true, course_name: "Volunteering")
    @manager = user_with_pseudonym(active_all: true)
    @course.enroll_teacher(@manager, enrollment_state: "active")
    @sc_section = @course.course_sections.create!(name: "Steering Committee")
    @course.enroll_student(@enrolled_parent, enrollment_state: "active")
    @pending_enrollment = @course.enroll_student(@pending_parent, enrollment_state: "invited")

    @volunteer = user_with_pseudonym(active_all: true)
    @course.enroll_student(@volunteer, enrollment_state: "active")
  end

  before do
    Setting.set(OlgcRolesController::SETTING, @board.id.to_s)
    Setting.set(OlgcVolunteersController::COURSE_SETTING, @course.id.to_s)
    Rails.cache.clear
  end

  describe "GET course" do
    it "returns the configured volunteer course id" do
      user_session(@volunteer)
      get :course, format: :json
      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "course_id" => @course.id })
    end

    it "returns null when unset" do
      Setting.set(OlgcVolunteersController::COURSE_SETTING, "")
      user_session(@volunteer)
      get :course, format: :json
      expect(response.parsed_body).to eq({ "course_id" => nil })
    end
  end

  describe "GET candidates" do
    it "lists tagged users who are not actively enrolled, with pending state" do
      user_session(@manager)
      get :candidates, params: { course_id: @course.id }, format: :json
      expect(response).to be_successful

      body = response.parsed_body
      expect(body["sections"].pluck("name")).to include("Steering Committee")
      expect(body["default_section_id"]).to eq(@course.default_section.id)

      by_id = body["candidates"].index_by { |c| c["id"] }
      expect(by_id.keys).to match_array([@parent.id, @pending_parent.id, @sc.id])

      expect(by_id[@parent.id]).to include("name" => "Pat Parent", "email" => "pat@example.com", "roles" => ["Parent"], "enrollment" => nil)
      expect(by_id[@sc.id]["roles"]).to eq(["SC"])
      expect(by_id[@pending_parent.id]["enrollment"]).to include(
        "id" => @pending_enrollment.id,
        "workflow_state" => "invited",
        "section_id" => @course.default_section.id
      )
    end

    it "honors the eligible roles setting" do
      Setting.set(OlgcVolunteersController::ROLES_SETTING, "SC")
      user_session(@manager)
      get :candidates, params: { course_id: @course.id }, format: :json
      expect(response.parsed_body["candidates"].pluck("id")).to eq([@sc.id])
    end

    it "rejects users who cannot enroll students in the course" do
      user_session(@volunteer)
      get :candidates, params: { course_id: @course.id }, format: :json
      expect(response).to be_forbidden
    end
  end

  describe "POST enroll" do
    it "enrolls the selected users active in the chosen section without an invitation" do
      user_session(@manager)
      post :enroll,
           params: { course_id: @course.id, user_ids: [@sc.id, @parent.id], section_id: @sc_section.id },
           format: :json
      expect(response).to be_successful

      rows = response.parsed_body["enrolled"]
      expect(rows.pluck("user_id")).to match_array([@sc.id, @parent.id])
      expect(rows.pluck("workflow_state").uniq).to eq(["active"])
      expect(rows.pluck("section_id").uniq).to eq([@sc_section.id])

      e = @course.student_enrollments.find_by(user_id: @sc.id)
      expect(e).to be_active
      expect(e.course_section).to eq(@sc_section)
    end

    it "upgrades a pending enrollment to active instead of creating a second one" do
      user_session(@manager)
      expect do
        post :enroll, params: { course_id: @course.id, user_ids: [@pending_parent.id] }, format: :json
      end.not_to change { @course.student_enrollments.where(user_id: @pending_parent.id).count }
      expect(@pending_enrollment.reload).to be_active
    end

    it "leaves an already-active enrollment alone" do
      user_session(@manager)
      post :enroll, params: { course_id: @course.id, user_ids: [@enrolled_parent.id], section_id: @sc_section.id }, format: :json
      expect(response).to be_successful
      e = @course.student_enrollments.find_by(user_id: @enrolled_parent.id)
      expect(e).to be_active
      expect(e.course_section).to eq(@course.default_section)
    end

    it "defaults to the course's default section" do
      user_session(@manager)
      post :enroll, params: { course_id: @course.id, user_ids: [@parent.id] }, format: :json
      expect(@course.student_enrollments.find_by(user_id: @parent.id).course_section).to eq(@course.default_section)
    end

    it "requires user_ids" do
      user_session(@manager)
      post :enroll, params: { course_id: @course.id }, format: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects users who cannot enroll students" do
      user_session(@volunteer)
      post :enroll, params: { course_id: @course.id, user_ids: [@parent.id] }, format: :json
      expect(response).to be_forbidden
    end
  end
end
