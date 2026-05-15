# SPDX-FileCopyrightText: 2025 crux contributors <https://github.com/ash-project/crux/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Crux.FormulaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Crux.Expression, only: [b: 1]

  alias Crux.Expression
  alias Crux.Formula

  doctest Formula

  describe inspect(&Formula.from_expression/1) do
    test "converts an expression to a formula with user-only bindings" do
      expression = b((:a and not :b) or (not :c and :d))

      formula = Formula.from_expression(expression)

      # Bindings hold only user variables — auxiliary Tseitin ids are
      # tracked separately and never leak into bindings.
      assert formula.bindings |> Map.values() |> Enum.sort() == [:a, :b, :c, :d]
      assert MapSet.size(formula.auxiliaries) > 0

      assert formula.bindings
             |> Map.keys()
             |> Enum.all?(&(not MapSet.member?(formula.auxiliaries, &1)))

      # The encoded CNF is satisfiability-equivalent to the source.
      assert Crux.satisfying_scenarios(formula) ==
               Crux.satisfying_scenarios(%Formula{
                 cnf: [[1, 2], [-3, 2], [1, -4], [-3, -4]],
                 bindings: %{1 => :a, 2 => :d, 3 => :b, 4 => :c},
                 reverse_bindings: %{a: 1, d: 2, b: 3, c: 4}
               })
    end

    test "stays linear on the historical exponential-blowup pattern (issue #23)" do
      # `(n_i AND e_i) OR ...` would distribute to 2^pairs clauses under
      # the naive CNF conversion; Tseitin keeps it ~6×pairs.
      pairs = 30

      expression =
        Enum.reduce(1..pairs, false, fn i, acc ->
          {:or, acc, {:and, String.to_atom("n#{i}"), String.to_atom("e#{i}")}}
        end)

      {time_us, formula} = :timer.tc(fn -> Formula.from_expression(expression) end)

      assert length(formula.cnf) < 10 * pairs
      assert time_us < 100_000
      assert Crux.satisfiable?(formula)
    end

    test "converts simple expressions" do
      # Single variable — no compound subexpression to encode, so no aux.
      result = Formula.from_expression(b(:a))
      assert %Formula{cnf: [[1]], bindings: %{1 => :a}, auxiliaries: aux} = result
      assert MapSet.size(aux) == 0

      # Single negated variable — `not` is encoded inline, also no aux.
      result = Formula.from_expression(b(not :a))
      assert %Formula{cnf: [[-1]], bindings: %{1 => :a}, auxiliaries: aux} = result
      assert MapSet.size(aux) == 0

      # Simple OR — `:a or :b` simplifies to a single literal at the
      # root, so still no aux for trivial disjunction.
      result = Formula.from_expression(b(:a or :b))
      assert %Formula{bindings: %{1 => :a, 2 => :b}} = result

      # Simple AND now goes through Tseitin and gains an auxiliary
      # representing the conjunction.
      result = Formula.from_expression(b(:a and :b))
      assert %Formula{bindings: %{1 => :a, 2 => :b}, auxiliaries: aux} = result
      assert MapSet.size(aux) >= 1

      # Booleans short-circuit to constants.
      assert %Formula{cnf: [], bindings: %{}} = Formula.from_expression(true)
      assert %Formula{cnf: [[1], [-1]], bindings: %{}} = Formula.from_expression(false)
    end
  end

  describe inspect(&Formula.to_expression/1) do
    test "converts a formula back to expression" do
      formula = %Formula{
        cnf: [[1], [2]],
        bindings: %{1 => :a, 2 => :b},
        reverse_bindings: %{a: 1, b: 2}
      }

      result = Formula.to_expression(formula)
      assert result == b(:a and :b)
    end

    test "converts formula with OR clause" do
      formula = %Formula{
        cnf: [[1, -2]],
        bindings: %{1 => :x, 2 => :y},
        reverse_bindings: %{x: 1, y: 2}
      }

      result = Formula.to_expression(formula)
      assert result == b(:x or not :y)
    end

    test "converts back boolean formulas" do
      assert true |> Formula.from_expression() |> Formula.to_expression() == true
      assert false |> Formula.from_expression() |> Formula.to_expression() == false
    end

    property "roundtrip from_expression to to_expression preserves equivalence" do
      check all(
              assignments <-
                StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.boolean(), min_length: 1),
              variable_names = Map.keys(assignments),
              expr <- Expression.generate_expression(StreamData.member_of(variable_names))
            ) do
        formula = Formula.from_expression(expr)
        result = Formula.to_expression(formula)
        eval_fn = &Map.fetch!(assignments, &1)

        assert Expression.run(expr, eval_fn) == Expression.run(result, eval_fn),
               """
               Roundtrip conversion changed the logical outcome!
               Original: #{inspect(expr, pretty: true)}
               Roundtrip: #{inspect(result, pretty: true)}
               Assignments: #{inspect(assignments, pretty: true)}
               """
      end
    end
  end

  describe inspect(&Formula.to_picosat/1) do
    test "single literal expressions match DIMACS exactly" do
      # Trivial inputs that don't introduce Tseitin auxiliaries.
      assert Formula.to_picosat(Formula.from_expression(b(:a))) ==
               "p cnf 1 1\n1 0"

      assert Formula.to_picosat(Formula.from_expression(b(not :a))) ==
               "p cnf 1 1\n-1 0"
    end

    test "the DIMACS header counts user + auxiliary variables" do
      formula = Formula.from_expression(b(:a and :b))
      result = Formula.to_picosat(formula)

      expected_vars = map_size(formula.bindings) + MapSet.size(formula.auxiliaries)
      assert result =~ ~r/^p cnf #{expected_vars} #{length(formula.cnf)}\n/
    end

    test "every clause is rendered as space-separated literals terminated by 0" do
      formula = Formula.from_expression(b((:a and :b) or :c))
      result = Formula.to_picosat(formula)

      [_header | body_lines] = String.split(result, "\n")
      assert length(body_lines) == length(formula.cnf)

      Enum.zip(body_lines, formula.cnf)
      |> Enum.each(fn {line, clause} ->
        assert line == Enum.join(clause, " ") <> " 0"
      end)
    end
  end
end
