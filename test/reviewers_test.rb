# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/common/reviewers'

class ReviewersTest < Minitest::Test
  def test_agent_handles_expand_to_their_labels
    assert_equal ['label:Agentic Review Request', 'label:Agentic Review Request and Approve', 'rubik-cube-man'],
                 Reviewers.expand_all(%w[agent agent-approve rubik], org: 'teamziax')
  end

  def test_an_expanded_label_expands_to_itself
    expanded = Reviewers.expand_all(%w[agent-approve], org: 'teamziax')
    assert_equal expanded, Reviewers.expand_all(expanded, org: 'teamziax')
  end

  def test_a_label_nobody_listens_for_is_refused
    assert_raises(Reviewers::UnknownHandle) { Reviewers.expand('label:Please review', org: 'teamziax') }
  end

  def test_label_name
    assert_equal 'Agentic Review Request', Reviewers.label_name('label:Agentic Review Request')
    assert_nil Reviewers.label_name('teamziax/game')
  end
end
