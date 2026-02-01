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
    test "converts an expression to a formula with bindings" do
      expression = b((:a and not :b) or (not :c and :d))

      # (:a and not :b) or (not :c and :d) in CNF becomes:
      # (:a or not :c) and (:a or :d) and (not :b or not :c) and (not :b or :d)
      result = Formula.from_expression(expression)

      assert %Formula{
               cnf: [
                 # :a or :d
                 [1, 2],
                 # not :b or :d
                 [-3, 2],
                 # :a or not :c
                 [1, -4],
                 # not :b or not :c
                 [-3, -4]
               ],
               bindings: %{
                 1 => :a,
                 2 => :d,
                 3 => :b,
                 4 => :c
               }
             } = result
    end

    test "converts simple expressions" do
      # Single variable
      result = Formula.from_expression(b(:a))
      assert %Formula{cnf: [[1]], bindings: %{1 => :a}} = result

      # Single negated variable
      result = Formula.from_expression(b(not :a))
      assert %Formula{cnf: [[-1]], bindings: %{1 => :a}} = result

      # Simple OR
      result = Formula.from_expression(b(:a or :b))
      assert %Formula{cnf: [[1, 2]], bindings: %{1 => :a, 2 => :b}} = result

      # Simple AND
      result = Formula.from_expression(b(:a and :b))
      assert %Formula{cnf: [[1], [2]], bindings: %{1 => :a, 2 => :b}} = result

      # Booleans
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
    test "converts a formula to DIMACS format" do
      # Simple conjunction: :a and :b
      expression = b(:a and :b)
      formula = Formula.from_expression(expression)
      result = Formula.to_picosat(formula)

      # Should produce CNF with 2 variables and 2 clauses
      assert result == "p cnf 2 2\n1 0\n2 0"
    end

    test "converts more complex formulas" do
      # Disjunction: :a or :b
      expression = b(:a or :b)
      formula = Formula.from_expression(expression)
      result = Formula.to_picosat(formula)

      # Should produce CNF with 2 variables and 1 clause
      assert result == "p cnf 2 1\n1 2 0"
    end

    test "handles negated variables" do
      # Not :a
      expression = b(not :a)
      formula = Formula.from_expression(expression)
      result = Formula.to_picosat(formula)

      # Should produce CNF with 1 variable and 1 clause
      assert result == "p cnf 1 1\n-1 0"
    end
  end
end
