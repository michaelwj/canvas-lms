# frozen_string_literal: true

# OLGC chaperone messaging policy (server-side enforcement).
#
# No unsupervised adult<->student messaging:
# - teacher -> student they teach: one of the student's parents is added
# - parent  -> other family's student: blocked at initiation (reply-only);
#   a parent replying in a thread with such a student pulls the student's
#   parent in (reply_chaperones)
# - student -> teacher/other adult: one of the student's own parents is added
# - students with no linked parents: blocked with guidance
# - whole-course/section/group sends are exempt (only explicitly-picked
#   numeric recipients are evaluated); account admins are exempt
#
# Role resolution is exact: parent = any active UserObservationLink as
# observer (community-board StudentEnrollments don't make parents students).
#
# Kill switch: Setting "olgc_chaperone_messaging" (default OFF). Remember
# Settings are cached per-process — restart web/jobs after changing.
#
# Touchpoints (all funnel through ConversationsHelper):
#   normalize_recipients  -> filter_new_recipients!  (create/add via both
#                            REST and GraphQL)
#   process_response      -> reply_chaperones        (plain replies)
module Olgc
  module ChaperoneMessaging
    SETTING_NAME = "olgc_chaperone_messaging"

    class PolicyError < ::ConversationsHelper::Error
      def initialize(message)
        super(message:, status: :bad_request, attribute: "recipients")
      end
    end

    class << self
      def enabled?
        Setting.get(SETTING_NAME, "false") == "true"
      end

      def exempt?(user)
        AccountUser.active.where(user:).exists?
      end

      # Hook A: explicitly-picked recipients at creation / recipient-add.
      # `raw` is the original recipient strings (numeric ids = hand-picked;
      # course_/group_ codes = exempt broadcast). Returns extra users to
      # append; raises PolicyError for blocked sends.
      def filter_new_recipients!(sender:, recipients:, raw:)
        return [] unless enabled? && sender && recipients.present?
        return [] if exempt?(sender)

        explicit_ids = Array(raw).filter_map { |r| Integer(r.to_s, exception: false) }.to_set
        return [] if explicit_ids.none?

        ctx = context_for(sender)
        extras = []
        recipients.each do |target|
          next unless explicit_ids.include?(target.id)

          verdict = evaluate(sender, target, ctx)
          case verdict[:action]
          when :block
            raise PolicyError, verdict[:message]
          when :chaperone
            verdict[:parents].each do |parent|
              next if recipients.any? { |r| r.id == parent.id }
              next if extras.any? { |r| r.id == parent.id }

              extras << parent
            end
          end
        end
        extras
      end

      # Hook B: a parent replying in a thread containing another family's
      # student (whose parent isn't a participant) pulls the parent in.
      def reply_chaperones(sender:, conversation:)
        return [] unless enabled? && sender
        return [] if exempt?(sender)

        ctx = context_for(sender)
        return [] unless ctx[:parent]

        participants = conversation.participants.to_a
        participant_ids = participants.map(&:id).to_set
        extras = []
        participants.each do |participant|
          next if participant.id == sender.id
          next if ctx[:observee_ids].include?(participant.id)
          next unless student?(participant)

          parents = parents_of(participant)
          raise PolicyError, no_parent_message(participant) if parents.empty?
          next if parents.any? { |parent| participant_ids.include?(parent.id) }

          parents.each do |parent|
            extras << parent unless extras.any? { |r| r.id == parent.id }
          end
        end
        extras
      end

      private

      def context_for(sender)
        {
          parent: parent?(sender),
          observee_ids: sender.as_observer_observation_links.active.pluck(:user_id).to_set,
          teacher_course_ids: sender.enrollments.active.where(type: %w[TeacherEnrollment TaEnrollment]).pluck(:course_id),
        }
      end

      def parent?(user)
        user.as_observer_observation_links.active.exists?
      end

      def teacher?(user)
        user.enrollments.active.where(type: %w[TeacherEnrollment TaEnrollment]).exists?
      end

      def student?(user)
        return false if parent?(user)

        user.enrollments.active.where(type: "StudentEnrollment").exists?
      end

      def parents_of(student)
        student.linked_observers.to_a
      end

      def evaluate(sender, target, ctx)
        return { action: :allow } if ctx[:observee_ids].include?(target.id)

        target_is_student = student?(target)

        if ctx[:parent]
          if target_is_student
            teaches_target = ctx[:teacher_course_ids].present? &&
                             StudentEnrollment.active.where(user_id: target.id, course_id: ctx[:teacher_course_ids]).exists?
            return chaperone_for(target) if teaches_target

            return { action: :block,
                     message: I18n.t("School policy: parents can start messages with teachers, parents, and their own children — but not other students. You can reply if they message you first.") }
          end
          return { action: :allow }
        end

        if ctx[:teacher_course_ids].present?
          return chaperone_for(target) if target_is_student

          return { action: :allow }
        end

        # student sender
        if teacher?(target) || parent?(target)
          return { action: :allow } if sender.linked_observers.where(id: target.id).exists?

          own_parents = parents_of(sender)
          if own_parents.empty?
            return { action: :block,
                     message: I18n.t("School policy requires one of your parents on messages to teachers and other adults, but no parent is linked to your account. Please contact the office.") }
          end
          return { action: :chaperone, parents: own_parents }
        end
        { action: :allow }
      end

      def chaperone_for(target)
        parents = parents_of(target)
        raise PolicyError, no_parent_message(target) if parents.empty?

        { action: :chaperone, parents: }
      end

      def no_parent_message(student)
        I18n.t("%{name} has no linked parent in Canvas, so school policy blocks direct messages. Please contact the office.",
               name: student.short_name || student.name)
      end
    end
  end
end
