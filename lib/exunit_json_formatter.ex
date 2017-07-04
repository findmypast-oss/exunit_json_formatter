defmodule ExUnitJsonFormatter do
  use GenServer
  @moduledoc """
  Formats ExUnit output as a stream of JSON objects (roughly compatible
  with Mocha's json-stream reporter)
  """

  # GenServer callbacks that receive test runner messages

  def init(opts) do
    config = %{
      seed: opts[:seed],
      trace: opts[:trace],
      pass_counter: 0,
      failure_counter: 0,
      skipped_counter: 0,
      invalid_counter: 0,
      case_counter: 0,
      start_time: nil
    }
    {:ok, config}
  end

  def handle_cast({:suite_started, opts}, state) do
    ["start", %{"including" => opts[:include],
                "excluding" => opts[:exclude]}]
    |> Poison.encode!
    |> IO.puts
    {:noreply, %{state | start_time: NaiveDateTime.utc_now}}
  end

  def handle_cast({:suite_finished, run_us, load_us}, state) do
    ["end",format_stats(state, run_us, load_us)]
    |> Poison.encode!
    |> IO.puts
    {:noreply, state}
  end

  def handle_cast({:case_started, _}, state) do
    {:noreply, state}
  end

  def handle_cast({:case_finished, test_case = %ExUnit.TestCase{state: {:failed, failure}}}, state) do
    ["fail", format_test_case_failure(test_case, failure)]
    |> Poison.encode!
    |> IO.puts
    {:noreply, state}
  end

  def handle_cast({:case_finished, _}, state) do
    {:noreply, %{state | case_counter: state[:case_counter] + 1}}
  end

  def handle_cast({:test_started, _}, state) do
    {:noreply, state}
  end

  def handle_cast({:test_finished, test = %ExUnit.Test{state: nil}}, state) do
    ["pass", format_test_pass(test)]
    |> Poison.encode!
    |> IO.puts
    {:noreply, %{state | pass_counter: state[:pass_counter] + 1}}
  end

  def handle_cast({:test_finished, test = %ExUnit.Test{state: {:failed, failure}}}, state) do
    ["fail", format_test_failure(test, failure)]
    |> Poison.encode!
    |> IO.puts
    {:noreply, %{state | failure_counter: state[:failure_counter] + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:skip, _}}}, state) do
    {:noreply, %{state | skipped_counter: state[:skipped_counter] + 1}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{state: {:invalid, _}}}, state) do
    {:noreply, %{state | invalid_counter: state[:invalid_counter] + 1}}
  end

  # FORMATTING FUNCTIONS
  import Exception, only: [format_stacktrace_entry: 1, format_file_line: 3]

  @counter_padding ""
  @width 80
  @no_value ExUnit.AssertionError.no_value

  @doc """
  Receives test stats and formats them to JSON
  """
  def format_stats(%{pass_counter: passed, failure_counter: failed, skipped_counter: skipped,
                     invalid_counter: invalid, case_counter: cases, start_time: start},
                   run_us, load_us) do
    stats = %{"duration" => run_us / 1_000,
              "start" => NaiveDateTime.to_iso8601(start),
              "end" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now),
              "passes" => passed,
              "failures" => failed,
              "pending" => skipped,
              "invalid" => invalid,
              "tests" => passed + failed + skipped + invalid,
              "suites" => cases}
    if not is_nil(load_us), do: Map.put(stats, "loadTime", load_us / 1_000), else: stats
  end

  @doc """
  Receives a test and formats its information
  """
  def format_test_pass(test) do
    %ExUnit.Test{case: case, name: name} = test
    name_str = Atom.to_string(name)
    case_str = case |> Atom.to_string |> String.trim_leading("Elixir.")

    %{"title" => name_str, "fullTitle" => "#{case_str}: #{name_str}"}
  end

  @doc """
  Receives a test and formats its failure.
  """
  def format_test_failure(test, failures) do
    %ExUnit.Test{name: name, case: case, tags: tags} = test
    message = Enum.map_join(Enum.with_index(failures), "", fn {{kind, reason, stack}, index} ->
      {text, stack} = format_kind_reason(test, kind, reason, stack, @width)
      failure_header(failures, index) <> text <> format_stacktrace(stack, case, name, nil)
     end) <> report(tags, failures, @width)

    %{"title" => to_string(name),
      "fullTitle" => "#{inspect case}: #{name}",
      "err" => %{"file" => Path.relative_to_cwd(tags[:file]),
                 "line" => tags[:line],
                 "message" => message}}
  end

  defp format_assertion_error(test, struct, stack, width, counter_padding) do
    label_padding_size = if has_value?(struct.right), do: 7, else: 6
    padding_size = label_padding_size + byte_size(@counter_padding)
    inspect = &inspect_multiline(&1, padding_size, width)
    {left, right} = format_sides(struct, inspect)

    [
      note: if_value(struct.message, &format_message(&1)),
      code: if_value(struct.expr, &code_multiline(&1, padding_size)),
      code: unless_value(struct.expr, fn -> get_code(test, stack) || @no_value end),
      left: left,
      right: right
    ]
    |> format_meta(label_padding_size)
    |> make_into_lines(counter_padding)
  end

  defp report(tags, failures, width) do
    case Map.take(tags, List.wrap(tags[:report])) do
      report when map_size(report) == 0 ->
        ""
      report ->
        report_spacing(failures) <>
          "tags:" <>
          Enum.map_join(report, "", fn {key, value} ->
            prefix = "  #{key}: "
            prefix <> inspect_multiline(value, byte_size(prefix), width) <> "\n"
          end)
    end
  end

  defp report_spacing([_]), do: ""
  defp report_spacing(_), do: "\n"

  @doc """
  Receives a test case and formats its failure.
  """
  def format_test_case_failure(test_case, failures) do
    %ExUnit.TestCase{name: name, tests: tests} = test_case
    tags = tests |> hd |> Map.get(:tags)
    title = "#{inspect name}: failure on setup_all callback"
    message = Enum.map_join Enum.with_index(failures), "", fn {{kind, reason, stack}, index} ->
      {text, stack} = format_kind_reason(test_case, kind, reason, stack, 80)
      failure_header(failures, index) <> text <> format_stacktrace(stack, name, nil, nil)
    end

    %{"title" => title,
      "fullTitle" => title,
      "err" => %{"file" => Path.relative_to_cwd(tags[:file]),
                 "message" => message}}
  end

  defp format_kind_reason(test, :error, %ExUnit.AssertionError{} = struct, stack, width) do
    {format_assertion_error(test, struct, stack, width, @counter_padding), stack}
  end

  defp format_kind_reason(test, kind, reason, stack, _width) do
    message = Exception.format_banner(kind, reason)
    {message <> format_code(test, stack), stack}
  end

  defp format_code(test, stack) do
    if snippet = get_code(test, stack) do
      "code: " <> snippet <> "\n"
    else
      ""
    end
  end

  defp get_code(%{case: case, name: name}, stack) do
    info = Enum.find_value(stack, fn {^case, ^name, _, info} -> info; _ -> nil end)
    file = info[:file]
    line = info[:line]
    if line > 0 && file && File.exists?(file) do
      file |> File.stream! |> Enum.at(line - 1) |> String.trim
    end
  rescue
    _ -> nil
  end
  defp get_code(%{}, _) do
    nil
  end

  defp format_meta(fields, padding_size) do
    for {label, value} <- fields, has_value?(value) do
      format_label(label, padding_size) <> value
    end
  end

  defp if_value(value, fun) do
    if has_value?(value) do
      fun.(value)
    else
      value
    end
  end

  defp unless_value(value, fun) do
    if has_value?(value) do
      @no_value
    else
      fun.()
    end
  end

  defp has_value?(value) do
    value != @no_value
  end

  defp format_label(:note, _padding_size), do: ""

  defp format_label(label, padding_size) do
    String.pad_trailing("#{label}:", padding_size)
  end

  defp format_message(value) do
    String.replace(value, "\n", "\n" <> @counter_padding)
  end

  defp code_multiline(expr, padding_size) when is_binary(expr) do
    padding = String.duplicate(" ", padding_size)
    String.replace(expr, "\n", "\n" <> padding)
  end
  defp code_multiline({fun, _, [expr]}, padding_size) when is_atom(fun) do
    code_multiline(Atom.to_string(fun) <> " " <> Macro.to_string(expr), padding_size)
  end
  defp code_multiline(expr, padding_size) do
    code_multiline(Macro.to_string(expr), padding_size)
  end

  defp inspect_multiline(expr, padding_size, width) do
    padding = String.duplicate(" ", padding_size)
    width = if width == :infinity, do: width, else: width - padding_size
    inspect(expr, [pretty: true, width: width])
    |> String.replace("\n", "\n" <> padding)
  end

  defp make_into_lines(reasons, padding) do
    padding <> Enum.join(reasons, "\n" <> padding) <> "\n"
  end

  defp format_sides(struct, inspect) do
    %{left: left, right: right} = struct

    case format_diff(left, right) do
      {left, right} ->
        {IO.iodata_to_binary(left), IO.iodata_to_binary(right)}
      nil ->
        {if_value(left, inspect), if_value(right, inspect)}
    end
  end

  defp format_diff(left, right) do
    if has_value?(left) and has_value?(right) do
      if script = edit_script(left, right) do
        colorize_diff(script, {[], []})
      end
    end
  end

  defp colorize_diff(script, acc) when is_list(script) do
    Enum.reduce(script, acc, &colorize_diff(&1, &2))
  end

  defp colorize_diff({:eq, content}, {left, right}) do
    {[left | content], [right | content]}
  end

  defp colorize_diff({:del, content}, {left, right}) do
    {[left | content], right}
  end

  defp colorize_diff({:ins, content}, {left, right}) do
    {left, [right | content]}
  end

  defp edit_script(left, right) do
    task = Task.async(ExUnit.Diff, :script, [left, right])
    case Task.yield(task, 1_500) || Task.shutdown(task, :brutal_kill) do
      {:ok, script} -> script
      nil -> nil
    end
  end

  defp format_stacktrace([], _case, _test, _color) do
    ""
  end

  defp format_stacktrace(stacktrace, test_case, test, color) do
    "stacktrace:" <>
      Enum.map_join(stacktrace, fn entry ->
        stacktrace_info format_stacktrace_entry(entry, test_case, test), color
      end)
  end

  defp format_stacktrace_entry({test_case, test, _, location}, test_case, test) do
    format_file_line(location[:file], location[:line], " (test)")
  end

  defp format_stacktrace_entry(entry, _test_case, _test) do
    format_stacktrace_entry(entry)
  end

  defp failure_header([_], _), do: ""
  defp failure_header(_, i), do: "\n#{@counter_padding}Failure ##{i+1}\n"

  defp stacktrace_info("", _formatter), do: ""
  defp stacktrace_info(msg, nil),       do: "       " <> msg <> "\n"

end
