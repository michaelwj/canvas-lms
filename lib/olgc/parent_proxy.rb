# frozen_string_literal: true

# OLGC fork: parents (linked observers) may submit assignments on behalf of
# their own children — Canvas's proxy-submission mechanism, extended from
# graders to the observer<->observee relationship. The submission lands on
# the student's record stamped with proxy_submitter (visible in gradebook /
# SpeedGrader as "submitted by <parent> on behalf of <student>").
module Olgc
  module ParentProxy
    def self.allowed?(observer:, student:)
      return false unless observer && student
      return false if observer.id == student.id

      UserObservationLink.active.where(observer_id: observer.id, user_id: student.id).exists?
    end
  end
end
