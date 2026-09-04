# frozen_string_literal: true

# OLGC fork patch: community role labels endpoint. Isolated spec file so
# upstream rebases never conflict here — run with the other olgc specs on
# every Canvas upgrade.

require_relative "../spec_helper"

describe OlgcRolesController do
  before :once do
    # the board: tags live here
    @board = course_factory(active_all: true)
    @parent = user_with_pseudonym(active_all: true)
    @board.enroll_student(@parent, enrollment_state: "active")

    category = GroupCategory.create!(
      context: @board, name: OlgcRolesController::ROLES_CATEGORY, non_collaborative: true
    )
    @tag = @board.groups.create!(name: "SC", group_category: category, non_collaborative: true)
    @tag.add_user(@parent)

    # an unrelated course whose roster the app might be viewing
    @course = course_factory(active_all: true)
    @viewer = user_with_pseudonym(active_all: true)
    @course.enroll_student(@viewer, enrollment_state: "active")

    @outsider = user_with_pseudonym(active_all: true)
  end

  before do
    Setting.set(OlgcRolesController::SETTING, @board.id.to_s)
    Rails.cache.clear
  end

  it "serves the board's tag labels to any enrolled user of the requested course" do
    user_session(@viewer)
    get :show, params: { course_id: @course.id }, format: :json
    expect(response).to be_successful
    expect(response.parsed_body).to eq({ @parent.id.to_s => ["SC"] })
  end

  it "rejects users who cannot read the requested course" do
    user_session(@outsider)
    get :show, params: { course_id: @course.id }, format: :json
    expect(response).to be_forbidden
  end

  it "returns an empty map when the setting is unset" do
    Setting.set(OlgcRolesController::SETTING, "")
    user_session(@viewer)
    get :show, params: { course_id: @course.id }, format: :json
    expect(response.parsed_body).to eq({})
  end

  it "prefers institutional account-level tags, merging every OLGC-prefixed category" do
    Account.default.enable_feature!(:institutional_tags)
    cat = InstitutionalTagCategory.create!(
      account: Account.default, name: OlgcRolesController::ROLES_CATEGORY
    )
    sg = InstitutionalTagCategory.create!(
      account: Account.default, name: "OLGC Student Government"
    )
    hidden = InstitutionalTagCategory.create!(
      account: Account.default, name: "Internal Bookkeeping"
    )
    InstitutionalTagAssociation.create!(
      institutional_tag: InstitutionalTag.create!(category: cat, name: "Teacher", description: "x"),
      context: @outsider
    )
    InstitutionalTagAssociation.create!(
      institutional_tag: InstitutionalTag.create!(category: sg, name: "Treasurer", description: "x"),
      context: @outsider
    )
    InstitutionalTagAssociation.create!(
      institutional_tag: InstitutionalTag.create!(category: hidden, name: "Secret", description: "x"),
      context: @outsider
    )

    user_session(@viewer)
    get :show, params: { course_id: @course.id }, format: :json
    expect(response.parsed_body).to eq({ @outsider.id.to_s => %w[Teacher Treasurer] })
  end

  it "ignores deleted tag memberships" do
    @tag.group_memberships.update_all(workflow_state: "deleted")
    Rails.cache.clear
    user_session(@viewer)
    get :show, params: { course_id: @course.id }, format: :json
    expect(response.parsed_body).to eq({})
  end
end
