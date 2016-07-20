require 'test_helper'

class AnalyzerControllerTest < ActionController::TestCase
  test "should get start" do
    get :start
    assert_response :success
  end

end
