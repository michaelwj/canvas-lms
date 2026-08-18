# frozen_string_literal: true

# OLGC fork patch: chaperone messaging policy (lib/olgc/chaperone_messaging).
# Isolated spec file so upstream rebases never conflict here. These specs are
# the rebase tripwire — run them as part of every Canvas upgrade.

require_relative "../../spec_helper"

describe Olgc::ChaperoneMessaging do
  before do
    Setting.set(described_class::SETTING_NAME, "true")
  end

  before :once do
    @course = course_factory(active_all: true)
    @teacher = user_with_pseudonym(active_all: true)
    @course.enroll_teacher(@teacher, enrollment_state: "active")

    @student = user_with_pseudonym(active_all: true)
    @course.enroll_student(@student, enrollment_state: "active")

    @parent = user_with_pseudonym(active_all: true)
    UserObservationLink.create_or_restore(student: @student, observer: @parent,
                                          root_account: @course.root_account)

    # a second family: student with NO linked parent
    @unlinked_student = user_with_pseudonym(active_all: true)
    @course.enroll_student(@unlinked_student, enrollment_state: "active")

    # an unrelated parent (observes a student in another course)
    @other_course = course_factory(active_all: true)
    @other_student = user_with_pseudonym(active_all: true)
    @other_course.enroll_student(@other_student, enrollment_state: "active")
    @other_parent = user_with_pseudonym(active_all: true)
    UserObservationLink.create_or_restore(student: @other_student, observer: @other_parent,
                                          root_account: @other_course.root_account)
  end

  def filter(sender, targets)
    described_class.filter_new_recipients!(
      sender:, recipients: targets, raw: targets.map { |t| t.id.to_s }
    )
  end

  describe "creation matrix" do
    it "adds the student's parent for teacher -> student" do
      extras = filter(@teacher, [@student])
      expect(extras.map(&:id)).to eq [@parent.id]
    end

    it "blocks teacher -> student with no linked parent" do
      expect { filter(@teacher, [@unlinked_student]) }
        .to raise_error(described_class::PolicyError, /no linked parent/)
    end

    it "blocks parent -> other family's student" do
      expect { filter(@other_parent, [@student]) }
        .to raise_error(described_class::PolicyError, /not other students/)
    end

    it "allows parent -> own child with no chaperone" do
      expect(filter(@parent, [@student])).to eq []
    end

    it "allows parent -> teacher and parent -> parent" do
      expect(filter(@parent, [@teacher])).to eq []
      expect(filter(@parent, [@other_parent])).to eq []
    end

    it "applies the teacher rule for a teacher-parent messaging a student they teach" do
      @course.enroll_teacher(@other_parent, enrollment_state: "active")
      extras = filter(@other_parent, [@student])
      expect(extras.map(&:id)).to eq [@parent.id]
    end

    it "adds the sender's own parent for student -> teacher" do
      extras = filter(@student, [@teacher])
      expect(extras.map(&:id)).to eq [@parent.id]
    end

    it "allows student -> own parent and student -> student freely" do
      expect(filter(@student, [@parent])).to eq []
      expect(filter(@student, [@unlinked_student])).to eq []
    end

    it "blocks student -> teacher when the student has no linked parent" do
      expect { filter(@unlinked_student, [@teacher]) }
        .to raise_error(described_class::PolicyError, /no parent is linked to your account/)
    end

    it "exempts account admins" do
      admin = account_admin_user(account: @course.root_account)
      expect(filter(admin, [@student])).to eq []
    end

    it "ignores recipients expanded from context codes (course sends)" do
      extras = described_class.filter_new_recipients!(
        sender: @teacher, recipients: [@student], raw: ["course_#{@course.id}"]
      )
      expect(extras).to eq []
    end

    it "does nothing when the setting is off" do
      Setting.set(described_class::SETTING_NAME, "false")
      expect(filter(@teacher, [@student])).to eq []
    end

    it "never blocks on the reply path (is_reply: true)" do
      # a parent replying to a student who wrote first must go through, even
      # though initiating to that student would be blocked
      expect do
        described_class.filter_new_recipients!(
          sender: @other_parent, recipients: [@student],
          raw: [@student.id.to_s], is_reply: true
        )
      end.not_to raise_error
      expect(
        described_class.filter_new_recipients!(
          sender: @other_parent, recipients: [@student],
          raw: [@student.id.to_s], is_reply: true
        )
      ).to eq []
    end
  end

  describe "reply_chaperones" do
    it "adds the student's parent when a parent replies without them present" do
      conversation = @other_parent.initiate_conversation([@student])
      conversation.add_message("hello")

      extras = described_class.reply_chaperones(
        sender: @other_parent, conversation: conversation.conversation
      )
      expect(extras.map(&:id)).to eq [@parent.id]
    end

    it "adds nothing when the parent is already a participant" do
      conversation = @other_parent.initiate_conversation([@student, @parent])
      conversation.add_message("hello")

      extras = described_class.reply_chaperones(
        sender: @other_parent, conversation: conversation.conversation
      )
      expect(extras).to eq []
    end

    it "adds nothing for non-parent senders or own children" do
      conversation = @teacher.initiate_conversation([@student])
      conversation.add_message("hello")
      expect(described_class.reply_chaperones(
               sender: @teacher, conversation: conversation.conversation
             )).to eq []

      own = @parent.initiate_conversation([@student])
      own.add_message("hi kiddo")
      expect(described_class.reply_chaperones(
               sender: @parent, conversation: own.conversation
             )).to eq []
    end

    it "blocks the reply when the student has no linked parent" do
      conversation = @other_parent.initiate_conversation([@unlinked_student])
      conversation.add_message("hello")

      expect do
        described_class.reply_chaperones(
          sender: @other_parent, conversation: conversation.conversation
        )
      end.to raise_error(described_class::PolicyError, /no linked parent/)
    end
  end
end
