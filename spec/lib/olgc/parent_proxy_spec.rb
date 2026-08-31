# frozen_string_literal: true

# OLGC fork patch: parent proxy submissions. Isolated spec file — part of
# the rebase-tripwire suite; run before every deploy/upgrade.

require_relative "../../spec_helper"

describe "OLGC parent proxy submissions" do
  before :once do
    @course = course_factory(active_all: true)
    @student = user_with_pseudonym(active_all: true)
    @course.enroll_student(@student, enrollment_state: "active")
    @parent = user_with_pseudonym(active_all: true)
    UserObservationLink.create_or_restore(student: @student, observer: @parent,
                                          root_account: @course.root_account)
    @stranger = user_with_pseudonym(active_all: true)
    @course.enroll_student(@stranger, enrollment_state: "active")
    @assignment = @course.assignments.create!(
      title: "essay", submission_types: "online_text_entry,online_upload", points_possible: 10
    )
  end

  describe Olgc::ParentProxy do
    it "allows only active linked observer pairs" do
      expect(described_class.allowed?(observer: @parent, student: @student)).to be true
      expect(described_class.allowed?(observer: @stranger, student: @student)).to be false
      expect(described_class.allowed?(observer: @parent, student: @parent)).to be false
    end
  end

  describe SubmissionsController, type: :controller do
    it "lets a linked parent submit for their child, stamped as proxy" do
      user_session(@parent)
      post :create,
           params: {
             course_id: @course.id,
             assignment_id: @assignment.id,
             submission: { user_id: @student.id, submission_type: "online_text_entry", body: "done" },
           },
           format: :json
      expect(response).to be_successful
      submission = @assignment.submissions.find_by(user: @student)
      expect(submission.submission_type).to eq "online_text_entry"
      expect(submission.proxy_submitter_id).to eq @parent.id
    end

    it "rejects an unlinked user submitting for someone else" do
      user_session(@stranger)
      post :create,
           params: {
             course_id: @course.id,
             assignment_id: @assignment.id,
             submission: { user_id: @student.id, submission_type: "online_text_entry", body: "nope" },
           },
           format: :json
      expect(response).to be_unauthorized
      expect(@assignment.submissions.find_by(user: @student)&.submission_type).to be_nil
    end

    it "still requires grading rights when submitted_at is supplied" do
      user_session(@parent)
      post :create,
           params: {
             course_id: @course.id,
             assignment_id: @assignment.id,
             submission: { user_id: @student.id, submission_type: "online_text_entry",
                           body: "backdated", submitted_at: 1.day.ago.iso8601 },
           },
           format: :json
      expect(response).to be_unauthorized
    end
  end

  describe SubmissionsApiController, type: :controller do
    it "lets a linked parent reserve an upload for their child" do
      user_session(@parent)
      post :create_file,
           params: {
             course_id: @course.id,
             assignment_id: @assignment.id,
             user_id: @student.id,
             name: "worksheet.jpg",
             size: 1000,
             content_type: "image/jpeg",
           },
           format: :json
      expect(response).to be_successful
      expect(response.parsed_body).to have_key("upload_url")
    end

    it "rejects an unlinked user reserving an upload for someone else" do
      user_session(@stranger)
      post :create_file,
           params: {
             course_id: @course.id,
             assignment_id: @assignment.id,
             user_id: @student.id,
             name: "worksheet.jpg",
             size: 1000,
             content_type: "image/jpeg",
           },
           format: :json
      expect(response).to be_unauthorized
    end
  end
end
