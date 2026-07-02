# SPDX-FileCopyrightText: 2025 crux contributors <https://github.com/ash-project/crux/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Crux.Formula do
  @moduledoc """
  A module for representing and manipulating satisfiability formulas in
  Conjunctive Normal Form (CNF).
  """

  import Crux.Expression, only: [b: 1]

  alias Crux.Expression
  alias Crux.Formula.Tseitin

  @typedoc """
  A satisfiability formula in Conjunctive Normal Form (CNF) along with
  bindings that map the integers used in the CNF back to their original values.
  """
  @type t(variable) :: %__MODULE__{
          cnf: cnf(),
          bindings: bindings(variable),
          reverse_bindings: reverse_bindings(variable),
          definitions: definitions(),
          auxiliaries: auxiliaries()
        }

  @typedoc """
  See `t/1`.
  """
  @type t() :: t(term())

  @typedoc """
  A formula in Conjunctive Normal Form (CNF) is a conjunction of clauses,
  where each `clause()` is a disjunction of `literal()`s.

  All `clause()`s of a CNF formula must be satisfied for the formula to be satisfied.
  """
  @type cnf() :: [clause()]

  @typedoc """
  A clause is a disjunction of `literal()`s.

  A clause is satisfied if at least one of its `literal()`s is satisfied.
  """
  @type clause() :: nonempty_list(literal())

  @typedoc """
  A `literal()` is either an `affirmed_literal()` (a positive integer) or
  a `negated_literal()` (a negative integer).
  """
  @type literal() :: affirmed_literal() | negated_literal()

  @typedoc """
  An `affirmed_literal()` is a positive integer representing a variable that is
  asserted to be true.
  """
  @type affirmed_literal() :: pos_integer()

  @typedoc """
  A `negated_literal()` is a negative integer representing a variable that is
  asserted to be false.
  """
  @type negated_literal() :: neg_integer()

  @typedoc """
  A `binding()` maps a positive integer (the variable) to its original value.
  """
  @type bindings(variable) :: %{pos_integer() => variable}

  @typedoc """
  A reverse binding maps a variable to its positive integer representation.
  This provides O(log n) lookup for variable-to-integer mappings.
  """
  @type reverse_bindings(variable) :: %{variable => pos_integer()}

  @typedoc """
  See `bindings/1`.
  """
  @type bindings() :: bindings(term())

  @typedoc """
  Auxiliary definition clauses produced by Tseitin encoding.

  These clauses bind each auxiliary variable to the truth value of the
  sub-expression it represents. They are a subset of `cnf/0` and must
  always hold; consumers performing implication tests must not negate
  them.
  """
  @type definitions() :: [clause()]

  @typedoc """
  The set of variable ids introduced by Tseitin encoding.

  Auxiliary ids appear in `cnf/0` but never in `bindings/1`.
  """
  @type auxiliaries() :: MapSet.t(pos_integer())

  @enforce_keys [:cnf, :bindings, :reverse_bindings]
  defstruct [
    :cnf,
    :bindings,
    :reverse_bindings,
    definitions: [],
    auxiliaries: MapSet.new()
  ]

  @doc """
  Converts a boolean expression to a SAT formula in Conjunctive Normal Form (CNF).

  The CNF is produced via the Tseitin transformation: each compound
  sub-expression gets a fresh auxiliary variable and a small set of
  "definition" clauses that bind the auxiliary to the sub-expression's
  truth value. The resulting CNF grows linearly with the size of the
  input — the naive distributive-law approach can blow up
  exponentially. Auxiliary variables never appear in `:bindings` or in
  scenarios returned by `Crux.solve/1` and `Crux.satisfying_scenarios/2`.

  `to_expression/1` reverses the encoding by substituting each auxiliary
  with its definition and simplifying.

  ## Examples

      iex> import Crux.Expression
      ...> formula = Formula.from_expression(b(:a and :b))
      ...> formula.bindings
      %{1 => :a, 2 => :b}
      iex> Formula.to_expression(formula)
      b(:a and :b)

      iex> import Crux.Expression
      ...> formula = Formula.from_expression(b(:x or not :y))
      ...> formula.bindings
      %{1 => :x, 2 => :y}
      iex> Formula.to_expression(formula)
      b(:x or not :y)

  """
  @spec from_expression(Expression.t(variable)) :: t(variable) when variable: term()
  def from_expression(expression) do
    simplified =
      expression
      |> Expression.balance()
      |> Expression.simplify()

    case simplified do
      true ->
        simple_true()

      false ->
        simple_false()

      expression ->
        Tseitin.transform(expression)
    end
  end

  @doc """
  Converts a SAT formula back to a boolean expression.

  For Tseitin-encoded formulas (the output of `from_expression/1`), this
  substitutes each auxiliary variable with its definition and simplifies
  — recovering an expression equivalent to the original source.

  Formulas constructed manually with no auxiliaries are walked
  clause-by-clause, mapping each literal back through `:bindings`.

  ## Examples

      iex> import Crux.Expression
      ...> Formula.to_expression(Formula.from_expression(b(:a and :b)))
      b(:a and :b)

      iex> import Crux.Expression
      ...> Formula.to_expression(Formula.from_expression(b(:x or not :y)))
      b(:x or not :y)

      iex> formula = %Formula{
      ...>   cnf: [[1, -2]],
      ...>   bindings: %{1 => :x, 2 => :y},
      ...>   reverse_bindings: %{x: 1, y: 2}
      ...> }
      ...>
      ...> Formula.to_expression(formula)
      b(:x or not :y)

  """
  @spec to_expression(formula :: t(variable)) :: Expression.t(variable) when variable: term()
  def to_expression(formula)
  def to_expression(%__MODULE__{cnf: []}), do: true
  def to_expression(%__MODULE__{cnf: [[1], [-1]], bindings: %{1 => false}}), do: false

  def to_expression(%__MODULE__{
        cnf: cnf,
        bindings: bindings,
        definitions: definitions,
        auxiliaries: auxiliaries
      }) do
    if MapSet.size(auxiliaries) == 0 do
      # Plain CNF (e.g. hand-constructed) — walk the clauses directly.
      cnf
      |> Enum.map(&clause_to_expression(&1, bindings))
      |> Enum.reduce(&b(&2 and &1))
    else
      definition_set = MapSet.new(definitions)
      assertions = Enum.reject(cnf, &MapSet.member?(definition_set, &1))

      aux_definitions = build_aux_definitions(definitions, auxiliaries)

      assertions
      |> Enum.map(&clause_to_expanded_expression(&1, aux_definitions, bindings))
      |> Enum.reduce(&b(&2 and &1))
      |> Expression.simplify()
    end
  end

  # Recovers `aux_id => {:and | :or, [literal]}` from the Tseitin
  # definition clauses. Tseitin produces three definition clauses per
  # auxiliary; only the "long" clause (length ≥ 3) is needed — its
  # polarity pattern tells us whether the auxiliary represents an AND
  # (one positive literal, rest negative) or an OR (one negative
  # literal, rest positive). Children are encoded before parents, so the
  # auxiliary being defined is always the literal with the largest
  # absolute id in the clause.
  @spec build_aux_definitions(definitions(), auxiliaries()) :: %{
          pos_integer() => {:and | :or, [literal()]}
        }
  defp build_aux_definitions(definitions, auxiliaries) do
    definitions
    |> Enum.filter(&(length(&1) >= 3))
    |> Enum.flat_map(fn clause ->
      max_lit =
        Enum.max_by(clause, &abs/1)

      aux_id = abs(max_lit)

      if MapSet.member?(auxiliaries, aux_id) do
        others = Enum.reject(clause, &(abs(&1) == aux_id))

        definition =
          if max_lit > 0 do
            # AND: long clause is (¬op_1 ∨ ¬op_2 ∨ aux); operands are
            # the literals' negations.
            {:and, Enum.map(others, &(-&1))}
          else
            # OR: long clause is (¬aux ∨ op_1 ∨ op_2); operands appear
            # with their natural polarity.
            {:or, others}
          end

        [{aux_id, definition}]
      else
        []
      end
    end)
    |> Map.new()
  end

  @spec clause_to_expanded_expression(
          clause(),
          %{pos_integer() => {:and | :or, [literal()]}},
          bindings(variable)
        ) :: Expression.t(variable)
        when variable: term()
  defp clause_to_expanded_expression(clause, aux_definitions, bindings) do
    clause
    |> Enum.map(&literal_to_expanded_expression(&1, aux_definitions, bindings))
    |> Enum.reduce(&b(&2 or &1))
  end

  @spec literal_to_expanded_expression(
          literal(),
          %{pos_integer() => {:and | :or, [literal()]}},
          bindings(variable)
        ) :: Expression.t(variable)
        when variable: term()
  defp literal_to_expanded_expression(literal, aux_definitions, bindings) when literal > 0,
    do: resolve_id(literal, aux_definitions, bindings)

  defp literal_to_expanded_expression(literal, aux_definitions, bindings) when literal < 0,
    do: b(not resolve_id(-literal, aux_definitions, bindings))

  @spec resolve_id(
          pos_integer(),
          %{pos_integer() => {:and | :or, [literal()]}},
          bindings(variable)
        ) :: Expression.t(variable)
        when variable: term()
  defp resolve_id(id, aux_definitions, bindings) do
    case Map.fetch(aux_definitions, id) do
      {:ok, {:and, operands}} ->
        operands
        |> Enum.map(&literal_to_expanded_expression(&1, aux_definitions, bindings))
        |> Enum.reduce(&b(&2 and &1))

      {:ok, {:or, operands}} ->
        operands
        |> Enum.map(&literal_to_expanded_expression(&1, aux_definitions, bindings))
        |> Enum.reduce(&b(&2 or &1))

      :error ->
        Map.fetch!(bindings, id)
    end
  end

  @doc """
  Formats a CNF formula to PicoSAT DIMACS format.

  Takes a formula struct and returns a string in the DIMACS CNF format
  that can be consumed by SAT solvers like PicoSAT.

  The header reports the highest variable id used in the CNF, which
  includes Tseitin auxiliary variables.

  ## Examples

      iex> alias Crux.{Expression, Formula}
      ...> formula = Formula.from_expression(Expression.b(:a))
      ...> Formula.to_picosat(formula)
      "p cnf 1 1\\n1 0"

  """
  @spec to_picosat(t()) :: String.t()
  def to_picosat(%__MODULE__{cnf: clauses, bindings: bindings, auxiliaries: auxiliaries}) do
    variable_count = map_size(bindings) + MapSet.size(auxiliaries)
    clause_count = length(clauses)

    formatted_input =
      Enum.map_join(clauses, "\n", fn clause ->
        Enum.join(clause, " ") <> " 0"
      end)

    "p cnf #{variable_count} #{clause_count}\n" <> formatted_input
  end

  @doc false
  @spec simple_true() :: t()
  def simple_true do
    %__MODULE__{
      cnf: [],
      bindings: %{},
      reverse_bindings: %{},
      definitions: [],
      auxiliaries: empty_auxiliaries()
    }
  end

  @doc false
  @spec simple_false() :: t()
  def simple_false do
    %__MODULE__{
      cnf: [[1], [-1]],
      bindings: %{1 => false},
      reverse_bindings: %{false => 1},
      definitions: [],
      auxiliaries: empty_auxiliaries()
    }
  end

  # On Elixir < 1.19, `MapSet.new/0` (and `new/1` with a literal argument) is
  # inlined by the compiler into a bare `%MapSet{}` literal, whose structural
  # type loses `MapSet.t()`'s opaqueness and trips Dialyzer's opaque checks
  # under OTP 28 in any downstream code that receives it (elixir-lang/elixir
  # #14576). The variable argument prevents that inlining, so the runtime
  # `MapSet.new/1` call keeps the opaque type sealed.
  @doc false
  @spec empty_auxiliaries() :: auxiliaries()
  def empty_auxiliaries do
    none = []
    MapSet.new(none)
  end

  @spec clause_to_expression(clause(), bindings(variable)) :: Expression.t(variable)
        when variable: term()
  defp clause_to_expression(clause, bindings) do
    clause
    |> Enum.map(&literal_to_expression(&1, bindings))
    |> Enum.reduce(&b(&2 or &1))
  end

  @spec literal_to_expression(literal(), bindings(variable)) :: Expression.t(variable)
        when variable: term()
  defp literal_to_expression(literal, bindings)

  defp literal_to_expression(literal, bindings) when literal > 0,
    do: Map.fetch!(bindings, literal)

  defp literal_to_expression(literal, bindings) when literal < 0,
    do: b(not Map.fetch!(bindings, -literal))
end
