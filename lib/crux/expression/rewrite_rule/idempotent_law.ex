# SPDX-FileCopyrightText: 2025 crux contributors <https://github.com/ash-project/crux/graphs.contributors>
#
# SPDX-License-Identifier: MIT

# credo:disable-for-this-file Credo.Check.Warning.BoolOperationOnSameValues
defmodule Crux.Expression.RewriteRule.IdempotentLaw do
  @moduledoc """
  Rewrite rule that applies idempotent laws to simplify expressions.

  See: https://en.wikipedia.org/wiki/Idempotence

  Applies the transformations:
  - `A AND A = A`
  - `A OR A = A`

  The idempotent laws state that applying the same operation twice
  has the same effect as applying it once.
  """

  use Crux.Expression.RewriteRule

  import Crux.Expression, only: [b: 1]

  @impl Crux.Expression.RewriteRule
  def walk(b(expr and expr)), do: expr
  def walk(b(expr or expr)), do: expr
  def walk(other), do: other
end
