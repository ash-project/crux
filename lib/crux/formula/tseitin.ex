# SPDX-FileCopyrightText: 2025 crux contributors <https://github.com/ash-project/crux/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Crux.Formula.Tseitin do
  @moduledoc """
  Tseitin transformation from a boolean `Crux.Expression` into CNF.

  The naive distributive-law CNF conversion can blow up exponentially
  (`(a₁ AND b₁) OR ... OR (aₙ AND bₙ)` produces 2ⁿ clauses). Tseitin
  introduces a fresh auxiliary variable for each compound subexpression
  and emits clauses that bind the auxiliary to the subexpression's truth
  value. The resulting CNF grows linearly in the size of the expression
  at the cost of those auxiliary variables.

  The transformation preserves satisfiability and — because the encoding
  is the full biconditional (`x ↔ subexpr`) — every user-variable
  assignment uniquely determines the auxiliary variables, so the set of
  satisfying user-variable models is identical to the original
  expression's.
  """

  import Crux.Expression, only: [b: 1]

  alias Crux.Expression
  alias Crux.Formula

  @typep state(variable) :: %{
           bindings: Formula.bindings(variable),
           reverse_bindings: Formula.reverse_bindings(variable),
           auxiliaries: Formula.auxiliaries(),
           definitions: [Formula.clause()],
           next_id: pos_integer()
         }

  @doc """
  Tseitin-encodes `expression` into CNF.

  Assumes `expression` is neither the literal `true` nor `false` —
  callers should short-circuit those at a higher level. Booleans nested
  inside the expression are handled.

  The returned `Formula` separates the auxiliary definition clauses
  (`:definitions`) from the full CNF (`:cnf`). Consumers that want to
  negate the formula (for implication tests) must keep the definition
  clauses required; auxiliaries are not freely assignable. `:bindings`
  and `:reverse_bindings` only cover user-supplied variables, never
  auxiliaries; the auxiliary ids live in `:auxiliaries`.
  """
  @spec transform(Expression.t(variable)) :: Formula.t(variable) when variable: term()
  def transform(expression) do
    state = %{
      bindings: %{},
      reverse_bindings: %{},
      auxiliaries: Formula.empty_auxiliaries(),
      definitions: [],
      next_id: 1
    }

    {root_lit, state} = encode(expression, state)

    assertion = [root_lit]
    definitions = Enum.reverse(state.definitions)
    cnf = [assertion | definitions]

    %Formula{
      cnf: cnf,
      definitions: definitions,
      bindings: state.bindings,
      reverse_bindings: state.reverse_bindings,
      auxiliaries: state.auxiliaries
    }
  end

  @spec encode(Expression.t(variable), state(variable)) :: {Formula.literal(), state(variable)}
        when variable: term()
  defp encode(true, state) do
    {aux, state} = fresh_aux(state)
    {aux, add_definitions(state, [[aux]])}
  end

  defp encode(false, state) do
    {aux, state} = fresh_aux(state)
    {aux, add_definitions(state, [[-aux]])}
  end

  defp encode(b(not subexpr), state) do
    {sub_lit, state} = encode(subexpr, state)
    {-sub_lit, state}
  end

  defp encode(b(left and right), state) do
    {left_lit, state} = encode(left, state)
    {right_lit, state} = encode(right, state)
    {aux, state} = fresh_aux(state)

    # aux ↔ (left AND right)
    new_clauses = [
      [-aux, left_lit],
      [-aux, right_lit],
      [-left_lit, -right_lit, aux]
    ]

    {aux, add_definitions(state, new_clauses)}
  end

  defp encode(b(left or right), state) do
    {left_lit, state} = encode(left, state)
    {right_lit, state} = encode(right, state)
    {aux, state} = fresh_aux(state)

    # aux ↔ (left OR right)
    new_clauses = [
      [-aux, left_lit, right_lit],
      [-left_lit, aux],
      [-right_lit, aux]
    ]

    {aux, add_definitions(state, new_clauses)}
  end

  defp encode(variable, state) do
    case Map.fetch(state.reverse_bindings, variable) do
      {:ok, id} ->
        {id, state}

      :error ->
        {id, state} = next_id(state)

        state = %{
          state
          | bindings: Map.put(state.bindings, id, variable),
            reverse_bindings: Map.put(state.reverse_bindings, variable, id)
        }

        {id, state}
    end
  end

  @spec next_id(state(variable)) :: {pos_integer(), state(variable)} when variable: term()
  defp next_id(state) do
    id = state.next_id
    {id, %{state | next_id: id + 1}}
  end

  @spec fresh_aux(state(variable)) :: {pos_integer(), state(variable)} when variable: term()
  defp fresh_aux(state) do
    {id, state} = next_id(state)
    {id, %{state | auxiliaries: MapSet.put(state.auxiliaries, id)}}
  end

  @spec add_definitions(state(variable), [Formula.clause()]) :: state(variable)
        when variable: term()
  defp add_definitions(state, clauses) do
    %{state | definitions: Enum.reverse(clauses, state.definitions)}
  end
end
