# frozen_string_literal: true

# OLGC fork patch: observer enrollments auto-create the user-level
# UserObservationLink (app/models/observer_enrollment.rb). Isolated spec
# file so upstream rebases never conflict here.

require_relative "../spec_helper"

describe "OLGC observer link auto-creation" do
  before :once do
    course_with_student(active_all: true)
    @parent = user_with_pseudonym(active_all: true)
  end

  it "creates a UserObservationLink when a linked observer enrollment is created" do
    @course.enroll_user(@parent, "ObserverEnrollment",
                        associated_user_id: @student.id,
                        enrollment_state: "active")

    link = UserObservationLink.where(observer_id: @parent.id, user_id: @student.id)
                              .where.not(workflow_state: "deleted")
    expect(link.exists?).to be true
    expect(@parent.reload.linked_students).to include(@student)
  end

  it "does not create a link for unlinked observer enrollments" do
    @course.enroll_user(@parent, "ObserverEnrollment", enrollment_state: "active")

    expect(UserObservationLink.where(observer_id: @parent.id).exists?).to be false
  end

  it "is idempotent when the link already exists" do
    UserObservationLink.create_or_restore(student: @student, observer: @parent,
                                          root_account: @course.root_account)

    expect do
      @course.enroll_user(@parent, "ObserverEnrollment",
                          associated_user_id: @student.id,
                          enrollment_state: "active")
    end.not_to change {
      UserObservationLink.where(observer_id: @parent.id, user_id: @student.id).count
    }
  end

  it "does not loop when the link's own enrollment sync runs" do
    second_course = course_factory(active_all: true)
    second_course.enroll_student(@student, enrollment_state: "active")

    @course.enroll_user(@parent, "ObserverEnrollment",
                        associated_user_id: @student.id,
                        enrollment_state: "active")
    run_jobs

    # link machinery created observer enrollments in the student's other
    # course without spawning duplicate links
    expect(
      UserObservationLink.where(observer_id: @parent.id, user_id: @student.id)
                         .where.not(workflow_state: "deleted").count
    ).to eq 1
  end
end
