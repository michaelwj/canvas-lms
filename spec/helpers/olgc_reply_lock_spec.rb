# frozen_string_literal: true

# OLGC fork patch: replies_locked_for? audience on replies
# (app/helpers/conversations_helper.rb, process_response). Isolated spec file
# so upstream rebases never conflict here — run with the other olgc specs on
# every Canvas upgrade.
#
# Upstream passes the request's `recipients` param as the "who else is in this
# thread" argument. A plain reply has none, so the "a teacher is involved"
# escape hatch evaluates against [] and never fires — 403 for any replier
# without :send_messages in the course (observers by default).

require_relative "../spec_helper"

describe "OLGC reply lock audience" do
  include ConversationsHelper

  before :once do
    @course = course_factory(active_all: true)
    @teacher = user_with_pseudonym(active_all: true)
    @course.enroll_teacher(@teacher, enrollment_state: "active")

    @student = user_with_pseudonym(active_all: true)
    @course.enroll_student(@student, enrollment_state: "active")

    # a parent: observer enrollments do NOT carry :send_messages by default
    @parent = user_with_pseudonym(active_all: true)
    @course.enroll_user(@parent, "ObserverEnrollment", enrollment_state: "active",
                                                      associated_user_id: @student.id)

    @conversation = @teacher.initiate_conversation([@parent, @student], nil,
                                                   context_type: "Course",
                                                   context_id: @course.id)
    @conversation.add_message("hello from the teacher")
  end

  it "keeps replies locked when the audience is empty (the upstream bug)" do
    conversation = @conversation.conversation
    expect(conversation.replies_locked_for?(@parent, [])).to be true
  end

  it "unlocks the reply once the thread's real participants are the audience" do
    conversation = @conversation.conversation
    participants = conversation.conversation_participants.map(&:user_id)
    expect(conversation.replies_locked_for?(@parent, participants)).to be false
  end

  it "lets an observer reply to a teacher-started thread through process_response" do
    parent_conversation = @conversation.conversation.conversation_participants
                                       .find_by(user_id: @parent.id)
    expect do
      process_response(
        conversation: parent_conversation,
        context: @course,
        current_user: @parent,
        session: nil,
        recipients: nil,
        context_code: nil,
        message_ids: nil,
        body: "thanks!",
        attachment_ids: nil,
        domain_root_account_id: Account.default.id,
        media_comment_id: nil,
        media_comment_type: nil
      )
    end.not_to raise_error
  end
end
