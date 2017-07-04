defmodule ExUnitJsonFormatterTest do
  use ExUnit.Case
  import ExUnitJsonFormatter

  test "formats passing test" do
    test = %ExUnit.Test{case: TestModule, name: :'should test'}
    assert format_test_pass(test) ==
      %{"title" => "should test", "fullTitle" => "TestModule: should test"}
  end

  test "formats failing test" do
    failures = [{:error, catch_error(raise "\"oops\""), []},
                {:error, catch_error(raise "oops"), []}]
    test = %ExUnit.Test{case: TestModule,
                               name: :'should test',
                               tags: %{file: __ENV__.file, line: 1},
                               state: {:failed, failures}}
    message = "\nFailure #1\n** (RuntimeError) \"oops\"\nFailure #2\n** (RuntimeError) oops"
    assert format_test_failure(test, failures) ==
      %{"title" => "should test",
        "fullTitle" => "TestModule: should test",
        "err" => %{"file" => "test/exunit_json_formatter_test.exs",
                   "line" => 1,
                   "message" => message}}
  end

  test "formats failing test case" do
    failures = [{:error, catch_error(raise "oops"), []},
                {:error, catch_error(raise "oops"), []}]
    test = %ExUnit.Test{case: TestModule,
                        name: :'should test',
                        tags: %{file: __ENV__.file, line: 1}}
    test_case = %ExUnit.TestCase{name: TestModule,
                                 state: {:failed, failures},
                                 tests: [test]}
    message = "\nFailure #1\n** (RuntimeError) oops\nFailure #2\n** (RuntimeError) oops"
    assert format_test_case_failure(test_case, failures) ==
      %{"title" => "TestModule: failure on setup_all callback",
        "fullTitle" => "TestModule: failure on setup_all callback",
        "err" => %{"file" => "test/exunit_json_formatter_test.exs",
                   "message" => message}}
  end
end
