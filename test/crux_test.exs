# SPDX-FileCopyrightText: 2025 crux contributors <https://github.com/ash-project/crux/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule CruxTest do
  use ExUnit.Case,
    async: false,
    parameterize: [%{solver: Picosat}, %{solver: SimpleSat}]

  use ExUnitProperties

  import Crux.Expression, only: [b: 1]

  alias Crux.Expression
  alias Crux.Formula

  doctest Crux

  setup %{solver: solver} do
    Process.put(Crux.Implementation, solver)
    :ok
  end

  describe inspect(&Crux.solve/1) do
    test "finds a satisfying assignment for a satisfiable formula" do
      formula = Formula.from_expression(b(:a or :b))

      assert {:ok, result} = Crux.solve(formula)

      assert result in [
               %{a: true},
               %{b: true},
               %{a: true, b: true}
             ]
    end

    test "returns :unsatisfiable for an unsatisfiable formula" do
      formula = Formula.from_expression(b(:a and not :a))

      assert {:error, :unsatisfiable} = Crux.solve(formula)
    end

    test "deals with simple booleans properly" do
      assert {:ok, %{}} = true |> Formula.from_expression() |> Crux.solve()
      assert {:error, :unsatisfiable} = false |> Formula.from_expression() |> Crux.solve()
    end
  end

  describe inspect(&Crux.satisfiable?/1) do
    test "returns true for satisfiable formulas" do
      # Simple satisfiable formula: :a or :b
      expression = b(:a or :b)
      formula = Formula.from_expression(expression)

      assert Crux.satisfiable?(formula)
    end

    test "returns false for unsatisfiable formulas" do
      # Contradiction: :a and not :a
      expression = b(:a and not :a)
      formula = Formula.from_expression(expression)

      refute Crux.satisfiable?(formula)
    end

    test "returns true for tautologies" do
      # Always true: :a or not :a
      expression = b(:a or not :a)
      formula = Formula.from_expression(expression)

      assert Crux.satisfiable?(formula)
    end

    test "returns true for complex satisfiable formulas" do
      # Complex but satisfiable: (:a and :b) or (:c and :d)
      expression = b((:a and :b) or (:c and :d))
      formula = Formula.from_expression(expression)

      assert Crux.satisfiable?(formula)
    end

    test "deals with simple booleans properly" do
      assert true |> Formula.from_expression() |> Crux.satisfiable?()
      refute false |> Formula.from_expression() |> Crux.satisfiable?()
    end
  end

  describe inspect(&Crux.decision_tree/2) do
    test "builds tree for simple AND formula" do
      formula = Formula.from_expression(b(:a and :b))

      tree = Crux.decision_tree(formula)

      # For :a and :b, we expect:
      # - if :a = false, then formula is false (regardless of :b)
      # - if :a = true, then we need :b = true for the formula to be true
      assert {:a, false, {:b, false, true}} = tree
    end

    test "builds tree for simple OR formula" do
      formula = Formula.from_expression(b(:a or :b))

      tree = Crux.decision_tree(formula)

      assert {:a, {:b, false, true}, true} = tree
    end

    test "returns false for unsatisfiable formula" do
      formula = Formula.from_expression(b(:a and not :a))

      refute Crux.decision_tree(formula)
    end

    test "returns true for tautology" do
      formula = Formula.from_expression(b(:a or not :a))

      assert Crux.decision_tree(formula)
    end

    test "skips irrelevant variables" do
      # :b doesn't affect the outcome since :a is always true
      formula = Formula.from_expression(b(:a or :b))

      # :b first
      tree = Crux.decision_tree(formula, sorter: &>=/2)

      # Should show :b first due to sorting, then :a
      assert {:b, {:a, false, true}, true} = tree
    end

    test "skips impossible branches" do
      formula = Formula.from_expression(b((:a or :b) and Expression.at_most_one([:a, :b])))

      tree =
        Crux.decision_tree(formula,
          conflicts?: fn
            :a, :b -> true
            _, _ -> false
          end
        )

      assert {:a, {:b, false, true}, true} = tree
    end

    test "deals with simple booleans properly" do
      assert true |> Formula.from_expression() |> Crux.decision_tree() == true
      assert false |> Formula.from_expression() |> Crux.decision_tree() == false
    end

    property "decision tree paths match original expression semantics" do
      variable_name =
        :alphanumeric |> StreamData.atom() |> StreamData.filter(&(not is_boolean(&1)))

      check all(
              assignments <-
                StreamData.map_of(variable_name, StreamData.boolean(), min_length: 1),
              variable_names = Map.keys(assignments),
              expr <- Expression.generate_expression(StreamData.member_of(variable_names))
            ) do
        formula = Formula.from_expression(expr)
        tree = Crux.decision_tree(formula)

        # Extract all paths from the tree
        satisfying_paths = extract_paths_to(tree, true)
        unsatisfying_paths = extract_paths_to(tree, false)

        # Validate satisfying paths
        for path <- satisfying_paths do
          assignment = path_to_assignment(path, assignments)
          result = Expression.run(expr, &Map.fetch!(assignment, &1))

          assert result,
                 """
                 Satisfying path should make expression true!
                 Expression: #{inspect(expr)}
                 Path: #{inspect(path)}
                 Assignment: #{inspect(assignment)}
                 Result: #{result}
                 """
        end

        # Validate unsatisfying paths
        for path <- unsatisfying_paths do
          assignment = path_to_assignment(path, assignments)
          result = Expression.run(expr, &Map.fetch!(assignment, &1))

          refute result,
                 """
                 Unsatisfying path should make expression false!
                 Expression: #{inspect(expr)}
                 Path: #{inspect(path)}
                 Assignment: #{inspect(assignment)}
                 Result: #{result}
                 """
        end
      end
    end
  end

  describe inspect(&Crux.satisfying_scenarios/1) do
    test "returns all satisfying assignments for AND formula" do
      formula = Formula.from_expression(b(:a and :b))

      scenarios = Crux.satisfying_scenarios(formula)

      assert scenarios == [%{a: true, b: true}]
    end

    test "returns all satisfying assignments for OR formula" do
      formula = Formula.from_expression(b(:a or :b))

      scenarios = Crux.satisfying_scenarios(formula)

      # Should have 2 simplified scenarios: {b: true}, {a: true}
      assert length(scenarios) == 2
      assert %{b: true} in scenarios
      assert %{a: true} in scenarios
    end

    test "returns empty list for unsatisfiable formula" do
      formula = Formula.from_expression(b(:a and not :a))

      scenarios = Crux.satisfying_scenarios(formula)

      assert scenarios == []
    end

    test "returns all assignments for tautology" do
      formula = Formula.from_expression(b(:a or not :a))

      scenarios = Crux.satisfying_scenarios(formula)

      # Tautology is optimized to a single scenario: empty map (always true)
      assert scenarios == [%{}]
    end

    test "uses domain knowledge to filter and minimize scenarios" do
      # XOR: (:a or :b) and at_most_one([:a, :b])
      formula = Formula.from_expression(b((:a or :b) and Expression.at_most_one([:a, :b])))

      # Without domain knowledge
      scenarios_basic = Crux.satisfying_scenarios(formula)
      assert length(scenarios_basic) == 2
      assert %{a: true, b: false} in scenarios_basic
      assert %{a: false, b: true} in scenarios_basic

      # With domain knowledge about conflicts
      scenarios_optimized =
        Crux.satisfying_scenarios(formula,
          conflicts?: fn
            # a and b conflict (no need for symmetric definition)
            :a, :b -> true
            _, _ -> false
          end
        )

      # Should still return the same scenarios since they don't have both a and b true
      assert length(scenarios_optimized) == 2
      assert %{a: true, b: false} in scenarios_optimized
      assert %{a: false, b: true} in scenarios_optimized
    end

    test "uses implies? option to minimize scenarios" do
      # Formula: :a and :b and :c (requires all three variables)
      formula = Formula.from_expression(b(:a and :b and :c))

      # Without domain knowledge - should get one scenario with all variables
      scenarios_basic = Crux.satisfying_scenarios(formula)
      assert scenarios_basic == [%{a: true, b: true, c: true}]

      # With domain knowledge: :a implies :b
      # This means when :a is true, :b is redundant (implied) and should be filtered out
      scenarios_with_implications =
        Crux.satisfying_scenarios(formula,
          implies?: fn
            :a, :b -> true
            _, _ -> false
          end
        )

      # Should get scenario with :b filtered out since it's implied by :a
      assert scenarios_with_implications == [%{a: true, c: true}]
    end

    test "deals with simple booleans properly" do
      assert [%{}] = true |> Formula.from_expression() |> Crux.satisfying_scenarios()
      assert [] = false |> Formula.from_expression() |> Crux.satisfying_scenarios()
    end

    property "all scenarios satisfy the original expression" do
      variable_name =
        :alphanumeric |> StreamData.atom() |> StreamData.filter(&(not is_boolean(&1)))

      check all(
              variable_names <- StreamData.list_of(variable_name, min_length: 1, max_length: 3),
              variable_names = Enum.uniq(variable_names),
              expr <- Expression.generate_expression(StreamData.member_of(variable_names))
            ) do
        formula = Formula.from_expression(expr)
        scenarios = Crux.satisfying_scenarios(formula)

        for scenario <- scenarios do
          defaults = Map.new(variable_names, &{&1, false})
          assignment = Map.merge(defaults, scenario)

          result = Expression.run(expr, &Map.fetch!(assignment, &1))

          assert result,
                 """
                 Scenario should satisfy the expression!
                 Expression: #{inspect(expr)}
                 Scenario: #{inspect(scenario)}
                 Assignment: #{inspect(assignment)}
                 Result: #{result}
                 """
        end
      end
    end
  end

  describe inspect(&Crux.validate_assignments/2) do
    test "returns ok for valid assignments without conflicts" do
      assignments = [a: true, b: false, c: true]
      opts = []

      assert {:ok, [a: true, b: false, c: true]} =
               Crux.validate_assignments(assignments, opts)
    end

    test "filters out implied variables" do
      assignments = [a: true, b: false, c: true]

      opts = [
        implies?: fn
          # a implies c, so c should be filtered out
          :a, :c -> true
          _, _ -> false
        end
      ]

      assert {:ok, [a: true, b: false]} = Crux.validate_assignments(assignments, opts)
    end

    test "returns error for conflicting assignments" do
      assignments = [a: true, b: true, c: false]

      opts = [
        conflicts?: fn
          # a and b conflict (no need to define both directions now)
          :a, :b -> true
          _, _ -> false
        end
      ]

      assert {:error, :unsatisfiable} = Crux.validate_assignments(assignments, opts)
    end

    test "does not conflict when one variable is false" do
      assignments = [a: true, b: false]

      opts = [
        conflicts?: fn
          # a and b would conflict if both true (no need for symmetric definition)
          :a, :b -> true
          _, _ -> false
        end
      ]

      # No conflict since b is false
      assert {:ok, [a: true, b: false]} = Crux.validate_assignments(assignments, opts)
    end

    test "processes variables in sorted order" do
      assignments = [c: true, a: false, b: true]

      opts = [
        sorter: &<=/2,
        implies?: fn
          # a implies b (but a is false here)
          :a, :b -> true
          _, _ -> false
        end
      ]

      # Should be sorted as a, b, c and b should not be filtered since a is false
      assert {:ok, [a: false, b: true, c: true]} =
               Crux.validate_assignments(assignments, opts)
    end

    test "works with maps" do
      assignments = %{a: true, b: false}
      opts = []

      assert {:ok, result} = Crux.validate_assignments(assignments, opts)
      assert [a: true, b: false] = Enum.sort(result)
    end

    test "backward implication: detects conflict when implied variable is false" do
      # If a implies b, then setting b=false should conflict when a=true
      # Process a first, then b
      assignments = [a: true, b: false]

      opts = [
        # This ensures a comes before b
        sorter: &<=/2,
        implies?: fn
          # a implies b
          :a, :b -> true
          _, _ -> false
        end
      ]

      # Expected: a=true gets added to acc, then when processing b=false,
      # we check if any true var in acc (a) implies b, and since a->b is true,
      # setting b=false conflicts with a=true -> b=true
      assert {:error, :unsatisfiable} = Crux.validate_assignments(assignments, opts)
    end

    test "backward implication: allows false when no implication exists" do
      # If a does not imply b, then b=false is fine even when a=true
      assignments = [a: true, b: false]

      opts = [
        implies?: fn
          # Define an implication that doesn't involve a -> b
          # unrelated implication
          :c, :d -> true
          _, _ -> false
        end
      ]

      # This should be ok because a=true doesn't imply anything about b
      assert {:ok, [a: true, b: false]} = Crux.validate_assignments(assignments, opts)
    end

    test "complex implications with multiple variables" do
      # For this to work, we need b to be processed before c
      # a=true, c=false, but a doesn't directly imply c
      assignments = [a: true, b: true, c: false]

      opts = [
        # Process in a, b, c order
        sorter: &<=/2,
        implies?: fn
          # b implies c
          :b, :c -> true
          _, _ -> false
        end
      ]

      # When processing: a=true (ok), b=true (ok), c=false (conflict because b implies c)
      assert {:error, :unsatisfiable} = Crux.validate_assignments(assignments, opts)
    end

    test "forward implication filters conflict variables" do
      assignments = [a: true, b: true]

      opts = [
        implies?: fn
          # a implies b
          :a, :b -> true
          _, _ -> false
        end
      ]

      # b should be filtered out because a implies it
      assert {:ok, [a: true]} = Crux.validate_assignments(assignments, opts)
    end
  end

  # Helper functions for property tests

  defp extract_paths_to(tree, value, path \\ %{})

  defp extract_paths_to(true, true, path), do: [path]
  defp extract_paths_to(false, false, path), do: [path]
  defp extract_paths_to(true, false, _), do: []
  defp extract_paths_to(false, true, _), do: []

  defp extract_paths_to({var, left, right}, value, path) do
    extract_paths_to(left, value, Map.put(path, var, false)) ++
      extract_paths_to(right, value, Map.put(path, var, true))
  end

  defp path_to_assignment(path, assignments) do
    Map.merge(assignments, path)
  end
end
