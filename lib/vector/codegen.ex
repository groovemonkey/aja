defmodule A.Vector.CodeGen do
  @moduledoc false

  # Notes: averaged overhead
  # Enum.sum(for i <- 1..100, do: A.Vector.new(1..i) |> :erts_debug.size_shared()) / 100

  # 2^3 = 8 -> 87.2
  # 2^4 = 16 -> 86.96
  # 2^5 = 32 -> 93.56
  # :array -> 77.3

  # Notes: averaged over 1..1000, the trend is the opposite (:array 638.18, vec32 577.016)

  @bits 4
  @branch_factor :math.pow(2, @bits) |> round()
  @range 1..@branch_factor

  @arguments_ast Macro.generate_arguments(@branch_factor, nil)
  @other_arguments_ast Macro.generate_arguments(2 * @branch_factor, nil)
                       |> Enum.drop(@branch_factor)
  @wildcard quote do: _

  defmacro bits do
    @bits
  end

  defmacro branch_factor do
    @branch_factor
  end

  defmacro incr_level(level) do
    quote do
      unquote(level) + unquote(@bits)
    end
  end

  defmacro decr_level(level) do
    quote do
      unquote(level) - unquote(@bits)
    end
  end

  defmacro radix_div(i) do
    quote do
      Bitwise.>>>(unquote(i), unquote(@bits))
    end
  end

  defmacro radix_rem(i) do
    quote do
      Bitwise.&&&(unquote(i), unquote(@branch_factor - 1))
    end
  end

  defmacro array_type(declaration, value) do
    quote do
      @type unquote(declaration) :: unquote({:{}, [], List.duplicate(value, @branch_factor)})
    end
  end

  defmacro radix_search(index, level) do
    quote do
      unquote(index)
      |> Bitwise.>>>(unquote(level))
      |> Bitwise.&&&(unquote(@branch_factor - 1))
    end
  end

  def range do
    @range
  end

  def block(lines) when is_list(lines) do
    {:__block__, [], lines}
  end

  def array() do
    do_array(@arguments_ast)
  end

  def array(args) do
    args
    |> validate_args_length()
    |> do_array()
  end

  def array_ast() do
    {:{}, [], [:{}, [], @arguments_ast]}
  end

  def array_ast(args) do
    validate_args_length(args)

    {:{}, [], [:{}, [], args]}
  end

  def arguments do
    @arguments_ast
  end

  def arguments(i) when i in 1..@branch_factor do
    Enum.take(@arguments_ast, i)
  end

  def argument_at(i) when i in 0..(@branch_factor - 1) do
    Enum.at(@arguments_ast, i)
  end

  def reversed_arguments() do
    unquote(
      @arguments_ast
      |> Enum.reverse()
      |> Macro.escape()
    )
  end

  def reversed_arguments(i) when i in 1..@branch_factor do
    @arguments_ast
    |> Enum.take(i)
    |> Enum.reverse()
  end

  def other_arguments do
    @other_arguments_ast
  end

  def other_arguments(i) when i in 1..@branch_factor do
    Enum.take(@other_arguments_ast, i)
  end

  def duplicate_argument(arg) do
    List.duplicate(arg, @branch_factor)
  end

  def arguments_with_nils(i) when i in 1..@branch_factor do
    nils = List.duplicate(nil, @branch_factor - i)
    Enum.take(@arguments_ast, i) ++ nils
  end

  def arguments_with_wildcards(i) when i in 1..@branch_factor do
    nils = List.duplicate(@wildcard, @branch_factor - i)
    Enum.take(@arguments_ast, i) ++ nils
  end

  def array_with_wildcards(n) do
    n
    |> arguments_with_wildcards()
    |> do_array()
  end

  def array_with_nils(n) do
    n
    |> arguments_with_nils()
    |> do_array()
  end

  def value_with_nils(value) do
    [value] |> fill_with(nil)
  end

  def fill_with(args, value) do
    missing = @branch_factor - length(args)
    args ++ List.duplicate(value, missing)
  end

  def map_until(args \\ @arguments_ast, n, fun) when is_integer(n) and is_function(fun, 1) do
    args
    |> Enum.with_index()
    |> Enum.map(fn
      {arg, i} when i < n -> fun.(arg)
      {arg, _} -> arg
    end)
  end

  def list_with_rest(args \\ @arguments_ast, rest_variable) do
    case length(args) do
      0 ->
        rest_variable

      len ->
        List.update_at(args, len - 1, fn last_arg ->
          quote do
            unquote(last_arg) | unquote(rest_variable)
          end
        end)
    end
  end

  defmacro var(variable) do
    Macro.escape(variable)
  end

  def inject_args(expr, args) do
    map = Map.new(args)

    Macro.postwalk(expr, fn
      {arg_name, _, nil} = ast ->
        case map do
          %{^arg_name => arg_value} -> arg_value
          _ -> ast
        end

      ast ->
        ast
    end)
  end

  defp validate_args_length(args) do
    # raise on unexpected args
    unquote(@branch_factor) = length(args)

    args
  end

  def do_array(args) do
    {:{}, [], args}
  end

  def sparse_map(args, fun) do
    Enum.map(args, fn
      nil -> nil
      arg -> fun.(arg)
    end)
  end

  # MAPPERS

  def apply_mapper(fun) do
    fn arg ->
      quote do
        unquote(fun).(unquote(arg))
      end
    end
  end

  # FIND

  defmacro find_cond_tail(size,
             do: [{:->, _, [[condition], returned]}, {:->, _, [_, default]}]
           ) do
    clauses =
      arguments()
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg, i} ->
        stop_check = quote do: (unquote(i) === unquote(size) -> unquote(default))

        cond_check =
          quote do
            unquote(inject_args(condition, arg: arg)) ->
              unquote(inject_args(returned, arg: arg, i: i))
          end

        if i > 0 do
          stop_check ++ cond_check
        else
          cond_check
        end
      end)

    final_clause = quote do: (true -> unquote(default))

    quote do
      cond do
        unquote(clauses ++ final_clause)
      end
    end
  end

  defmacro find_cond_trie(do: [{:->, _, [[condition], returned]}, {:->, _, [_, default]}]) do
    clauses =
      arguments()
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg, i} ->
        stop_check = quote do: (unquote(arg) === nil -> unquote(default))

        cond_check =
          quote do
            unquote(inject_args(condition, arg: arg)) ->
              unquote(inject_args(returned, arg: arg, i: i))
          end

        if i > 0 do
          stop_check ++ cond_check
        else
          cond_check
        end
      end)

    final_clause = quote do: (true -> unquote(default))

    quote do
      cond do
        unquote(clauses ++ final_clause)
      end
    end
  end

  defmacro find_cond_leaf(do: [{:->, _, [[condition], returned]}, {:->, _, [_, default]}]) do
    clauses =
      arguments()
      |> Enum.with_index()
      |> Enum.flat_map(fn {arg, i} ->
        quote do
          unquote(inject_args(condition, arg: arg)) ->
            unquote(inject_args(returned, arg: arg, i: i))
        end
      end)

    final_clause = quote do: (true -> unquote(default))

    quote do
      cond do
        unquote(clauses ++ final_clause)
      end
    end
  end

  # FOLDS

  defmacro def_foldl(header, do: body) do
    {fun_name, [{arg_name, _, nil}, acc | rest_args]} = Macro.decompose_call(header)

    expanded_body = Macro.expand(body, __CALLER__)

    acc_params =
      case acc do
        {acc_name, _, nil} ->
          {:acc_var, Macro.var(acc_name, nil)}

        {:\\, _, [{acc_name, _, nil}, acc_value]} ->
          case acc_value do
            {:first, _, []} ->
              {:acc_first, Macro.var(acc_name, nil)}

            _ ->
              {:acc_value, Macro.var(acc_name, nil), acc_value}
          end
      end

    do_def_foldl(fun_name, arg_name, acc_params, rest_args, expanded_body)
  end

  defp do_def_foldl(fun_name, arg_name, acc_params, rest_args, expanded_body) do
    acc_var = elem(acc_params, 1)
    tail_fun_name = fun_name_with_suffix(fun_name, :tail)
    trie_fun_name = fun_name_with_suffix(fun_name, :trie)

    [
      do_def_foldl_trie(trie_fun_name, arg_name, acc_var, rest_args, expanded_body),
      do_def_foldl_tail(tail_fun_name, arg_name, acc_var, rest_args, expanded_body),
      case acc_params do
        {:acc_var, acc_var} ->
          do_foldl_with_acc(fun_name, tail_fun_name, trie_fun_name, acc_var, rest_args)

        {:acc_value, _acc_var, acc_value} ->
          do_foldl_with_value(fun_name, tail_fun_name, trie_fun_name, acc_value, rest_args)

        {:acc_first, acc_var} ->
          trie_left_fun_name = fun_name_with_suffix(fun_name, :trie_left)

          [
            do_def_foldl_trie_left(
              trie_left_fun_name,
              trie_fun_name,
              arg_name,
              acc_var,
              rest_args,
              expanded_body
            ),
            do_foldl_with_first(fun_name, tail_fun_name, trie_left_fun_name, rest_args)
          ]
      end
    ]
    |> List.flatten()
  end

  defp do_foldl_with_acc(fun_name, tail_fun_name, trie_fun_name, acc_var, rest_args) do
    quote do
      def unquote(fun_name)(vector, unquote(acc_var), unquote_splicing(rest_args))

      def unquote(fun_name)(
            {size, tail_offset, level, trie, tail},
            unquote(acc_var),
            unquote_splicing(rest_args)
          ) do
        new_acc =
          unquote(trie_fun_name)(trie, level, unquote(acc_var), unquote_splicing(rest_args))

        unquote(tail_fun_name)(tail, 0, size - tail_offset, new_acc, unquote_splicing(rest_args))
      end

      def unquote(fun_name)({size, tail}, unquote(acc_var), unquote_splicing(rest_args)) do
        unquote(tail_fun_name)(tail, 0, size, unquote(acc_var), unquote_splicing(rest_args))
      end

      def unquote(fun_name)(
            {_},
            unquote(acc_var),
            unquote_splicing(for _ <- rest_args, do: @wildcard)
          ) do
        unquote(acc_var)
      end
    end
  end

  defp do_foldl_with_value(
         fun_name,
         tail_fun_name,
         trie_left_fun_name,
         acc_value,
         rest_args
       ) do
    quote do
      def unquote(fun_name)(vector, unquote_splicing(rest_args))

      def unquote(fun_name)(
            {size, tail_offset, level, trie, tail},
            unquote_splicing(rest_args)
          ) do
        new_acc =
          unquote(trie_left_fun_name)(
            trie,
            level,
            unquote(acc_value),
            unquote_splicing(rest_args)
          )

        unquote(tail_fun_name)(tail, 0, size - tail_offset, new_acc, unquote_splicing(rest_args))
      end

      def unquote(fun_name)({size, tail}, unquote_splicing(rest_args)) do
        unquote(tail_fun_name)(tail, 0, size, unquote(acc_value), unquote_splicing(rest_args))
      end

      def unquote(fun_name)(
            {_},
            unquote_splicing(for _ <- rest_args, do: @wildcard)
          ) do
        unquote(acc_value)
      end
    end
  end

  defp do_foldl_with_first(fun_name, tail_fun_name, trie_left_fun_name, rest_args) do
    quote do
      def unquote(fun_name)(vector, unquote_splicing(rest_args))

      def unquote(fun_name)(
            {size, tail_offset, level, trie, tail},
            unquote_splicing(rest_args)
          ) do
        new_acc = unquote(trie_left_fun_name)(trie, level, unquote_splicing(rest_args))

        unquote(tail_fun_name)(tail, 0, size - tail_offset, new_acc, unquote_splicing(rest_args))
      end

      def unquote(fun_name)({size, tail}, unquote_splicing(rest_args)) do
        acc = :erlang.element(1, tail)
        unquote(tail_fun_name)(tail, 1, size, acc, unquote_splicing(rest_args))
      end
    end
  end

  defp do_def_foldl_tail(fun_name, arg_name, acc_var, rest_args, expanded_body) do
    value_var = Macro.var(:value, nil)

    quote do
      def unquote(fun_name)(tail, i, size, unquote(acc_var), unquote_splicing(rest_args))

      def unquote(fun_name)(
            _tail,
            _i = size,
            size,
            unquote(acc_var),
            unquote_splicing(for _ <- rest_args, do: @wildcard)
          ) do
        unquote(acc_var)
      end

      def unquote(fun_name)(tail, i, size, unquote(acc_var), unquote_splicing(rest_args)) do
        i = i + 1
        unquote(value_var) = :erlang.element(i, tail)

        new_acc =
          unquote(
            inject_reducer_variables(
              expanded_body,
              arg_name,
              value_var,
              acc_var,
              acc_var
            )
          )

        unquote(fun_name)(tail, i, size, new_acc, unquote_splicing(rest_args))
      end
    end
  end

  defp do_def_foldl_trie(fun_name, arg_name, acc_var, rest_args, expanded_body) do
    quote do
      def unquote(fun_name)(trie, level, unquote(acc_var), unquote_splicing(rest_args))

      def unquote(fun_name)(
            unquote(array()),
            _level = 0,
            unquote(acc_var),
            unquote_splicing(rest_args)
          ) do
        unquote(
          arguments()
          |> Enum.reduce(acc_var, fn arg_ast, acc_ast ->
            inject_reducer_variables(expanded_body, arg_name, arg_ast, acc_var, acc_ast)
          end)
        )
      end

      def unquote(fun_name)(
            unquote(array()),
            level,
            unquote(acc_var),
            unquote_splicing(rest_args)
          ) do
        child_level = level - unquote(@bits)

        unquote(
          arguments()
          |> Enum.reduce(acc_var, fn arg, acc ->
            quote do
              acc = unquote(acc)

              case unquote(arg) do
                nil -> acc
                value -> unquote(fun_name)(value, child_level, acc, unquote_splicing(rest_args))
              end
            end
          end)
        )
      end
    end
  end

  defp do_def_foldl_trie_left(
         left_fun_name,
         rest_fun_name,
         arg_name,
         acc_var,
         rest_args,
         expanded_body
       ) do
    [first_arg | right_args] = arguments()

    left_acc =
      quote do
        unquote(left_fun_name)(unquote(first_arg), child_level, unquote_splicing(rest_args))
      end

    quote do
      def unquote(left_fun_name)(trie, level, unquote_splicing(rest_args))

      def unquote(left_fun_name)(
            unquote(array()),
            _level = 0,
            unquote_splicing(rest_args)
          ) do
        unquote(
          arguments()
          |> Enum.reduce(fn arg_ast, acc_ast ->
            inject_reducer_variables(expanded_body, arg_name, arg_ast, acc_var, acc_ast)
          end)
        )
      end

      def unquote(left_fun_name)(
            unquote(array()),
            level,
            unquote_splicing(rest_args)
          ) do
        child_level = level - unquote(@bits)

        unquote(
          Enum.reduce(right_args, left_acc, fn arg, acc ->
            quote do
              acc = unquote(acc)

              case unquote(arg) do
                nil ->
                  acc

                value ->
                  unquote(rest_fun_name)(value, child_level, acc, unquote_splicing(rest_args))
              end
            end
          end)
        )
      end
    end
  end

  defp inject_reducer_variables(expr, arg_name, arg_ast, acc_var, acc_ast) do
    quote do
      unquote(acc_var) = unquote(acc_ast)
      unquote(inject_args(expr, %{arg_name => arg_ast}))
    end
  end

  defp fun_name_with_suffix(fun_name, suffix) when is_atom(fun_name) and is_atom(suffix) do
    String.to_atom("#{fun_name}_#{suffix}")
  end
end
