# frozen_string_literal: true

# OLGC fork patch: users may update their own profile bio through
# PUT /api/v1/users/:id when the account allows it (the stock API only lets
# admins with manage_user_details set a bio). Isolated spec file so upstream
# rebases never conflict here — run with the other olgc specs on every
# Canvas upgrade.

require_relative "../api_spec_helper"

describe "OLGC: self-service bio updates via Users API", type: :request do
  let(:course) { course_factory(active_all: true) }
  let(:student) { user_with_pseudonym(active_all: true) }
  let(:other_student) { user_with_pseudonym(active_all: true) }
  let(:root_account) { course.root_account }

  before do
    course.enroll_student(student, enrollment_state: "active")
    course.enroll_student(other_student, enrollment_state: "active")
    @user = student
  end

  def put_bio(target, bio, expected_status: 200)
    api_call(:put,
             "/api/v1/users/#{target.id}",
             { controller: "users", action: "update", format: "json", id: target.id.to_param },
             { user: { bio: } },
             {},
             { expected_status: })
  end

  def set_profile_settings(users_can_edit_bio:, users_can_edit_profile: true, enable_profiles: true)
    root_account.settings = { enable_profiles:, users_can_edit_profile:, users_can_edit_bio: }
    root_account.save!
  end

  describe "PUT update" do
    it "allows a user to update their own bio when the account permits it" do
      set_profile_settings(users_can_edit_bio: true)
      json = put_bio(student, "hello from mobile")
      expect(json["bio"]).to eql "hello from mobile"
      expect(student.reload.profile.bio).to eql "hello from mobile"
    end

    it "is forbidden when users_can_edit_bio is disabled" do
      set_profile_settings(users_can_edit_bio: false)
      put_bio(student, "nope", expected_status: 403)
      expect(student.reload.profile.bio).to be_nil
    end

    it "is forbidden when users_can_edit_profile is disabled" do
      set_profile_settings(users_can_edit_bio: true, users_can_edit_profile: false)
      put_bio(student, "nope", expected_status: 403)
      expect(student.reload.profile.bio).to be_nil
    end

    it "is forbidden when profiles are disabled for the account" do
      set_profile_settings(users_can_edit_bio: true, enable_profiles: false)
      put_bio(student, "nope", expected_status: 403)
      expect(student.reload.profile.bio).to be_nil
    end

    it "does not let a user update another user's bio" do
      set_profile_settings(users_can_edit_bio: true)
      put_bio(other_student, "nope", expected_status: 403)
      expect(other_student.reload.profile.bio).to be_nil
    end
  end
end
